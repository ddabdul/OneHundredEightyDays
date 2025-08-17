//
//  TripStore.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 11/08/2025.
//

import Foundation
import CoreData
import os

// MARK: - Notification Name

/// Post this when a duplicate trip is detected. Listen at the app root to show a global warning.
extension Notification.Name {
    static let tripDuplicateDetected = Notification.Name("TripStoreDuplicateDetected")
}

/// Central place to persist trips to Core Data (TripEntity).
/// Uses AirportLookup to show "CODE — City, Country" from IATA/city codes,
/// resolving the *metro city* (e.g., BRU → Brussels, not Zaventem).
enum TripStoreError: Error { case saveFailed(Error) }

struct TripStore {

    // MARK: - Setup

    /// Airport/City lookup (immutable, thread-safe)
    private static let airportLookup = AirportLookup()
    private static let log = Logger(subsystem: "OneHundredEightyDays", category: "TripStore")

    // MARK: - Public API (ASYNC, preferred)

    /// Async save flow:
    /// 1) Compute travel day.
    /// 2) **Duplicate-trip precheck** without user interaction:
    ///    - Fetch existing trips for same airline+flight+day.
    ///    - Compare passenger via deterministic normalization (no prompt).
    ///    - If found, return existing and emit toast notification on the main queue.
    /// 3) Otherwise, run **NameDedupService** to confirm passenger name (auto-accept at 100%).
    /// 4) Insert using a naturalKey built from the INPUT’s machine-normalized passenger (stable).
    @discardableResult
    static func saveTripAsync(
        airline: String,
        originCode: String,
        destCode: String,
        flightNumber: String,
        julianDate: Int,
        passenger: String,          // raw passenger as read from BCBP / manual input
        imageData: Data?,
        in context: NSManagedObjectContext,
        similarityThreshold: Double = 0.82
    ) async throws -> TripEntity {

        // 1) Resolve travel date (day precision)
        let date = dateFromJulian(julianDate) ?? Date()
        let day = Calendar.current.startOfDay(for: date)

        // 2) Duplicate-trip precheck (no UI): compare on airline+flight+day+normalized-passenger
        let normalizedPassengerForKey = machineNormalizedPassenger(passenger)
        if let existing = findExistingTrip(
            airline: airline,
            flightNumber: flightNumber,
            travelDay: day,
            passengerNormalized: normalizedPassengerForKey,
            in: context
        ) {
            log.notice("Duplicate trip detected (precheck): \(tripDescription(existing), privacy: .public)")
            // ⛔️ Don't capture `existing` (non-Sendable) inside the @Sendable closure.
            let message = tripDescription(existing)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .tripDuplicateDetected,
                    object: nil,
                    userInfo: ["message": message]
                )
            }
            return existing
        }

        // 3) No duplicate found → resolve/confirm passenger (may prompt; auto-accept at 100%)
        let resolvedPassenger = await resolvePassengerNameWithUserConfirmation(
            inputPassenger: passenger,
            in: context,
            threshold: similarityThreshold
        )

        // 4) Generate display strings and country codes
        let departDisplay = airportLookup.displayName(for: originCode)
        let arriveDisplay = airportLookup.displayName(for: destCode)
        let departISO = airportLookup.airport(for: originCode)?.country.uppercased() ?? ""
        let arriveISO = airportLookup.airport(for: destCode)?.country.uppercased() ?? ""

        // 5) Insert (naturalKey derived from INPUT’s machine-normalized passenger only)
        let fixedKey = normalizedKey(
            airline: airline,
            flightNumber: flightNumber,
            travelDate: day,
            passenger: normalizedPassengerForKey
        )

        var saved: TripEntity!
        var captured: Error?

        context.performAndWait {
            // === DIRECT INSERT ===
            let trip = TripEntity(context: context)
            trip.id                   = UUID()
            trip.naturalKey           = fixedKey
            trip.airline              = airline
            trip.flightNumber         = flightNumber
            trip.travelDate           = day
            trip.passenger            = resolvedPassenger
            trip.departureCity        = departDisplay
            trip.arrivalCity          = arriveDisplay
            trip.departureCountry     = departISO
            trip.arrivalCountry       = arriveISO
            trip.imageData            = imageData
            trip.arrivalAirportCode   = destCode
            trip.departureAirportCode = originCode

            do {
                try context.save()
                saved = trip
            } catch {
                captured = error
            }
        }

        if let err = captured { throw TripStoreError.saveFailed(err) }
        return saved
    }

    // MARK: - Public API (sync wrapper) — avoid on main thread

    /// Legacy synchronous wrapper. **Do not call this on the main thread** because it will block UI.
    /// Prefer calling `saveTripAsync` from a `Task {}` and `await` it.
    @available(*, deprecated, message: "Use saveTripAsync from the main thread. This sync wrapper must not be called on the main thread.")
    @discardableResult
    static func saveTrip(
        airline: String,
        originCode: String,
        destCode: String,
        flightNumber: String,
        julianDate: Int,
        passenger: String,
        imageData: Data?,
        in context: NSManagedObjectContext
    ) throws -> TripEntity {
        precondition(!Thread.isMainThread, "Do not call TripStore.saveTrip (sync) on the main thread; use saveTripAsync.")
        var output: Result<TripEntity, Error>!
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let trip = try await saveTripAsync(
                    airline: airline,
                    originCode: originCode,
                    destCode: destCode,
                    flightNumber: flightNumber,
                    julianDate: julianDate,
                    passenger: passenger,
                    imageData: imageData,
                    in: context
                )
                output = .success(trip)
            } catch {
                output = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch output! {
        case .success(let trip): return trip
        case .failure(let err): throw err
        }
    }

    // MARK: - Name resolution (calls your NameDedupService)

    /// Runs the passenger name de-dup flow in a child context, returns the final name to store.
    /// Logs whether it was auto-accepted (100%) or user-decided (<100%), with the similarity score.
    @MainActor
    private static func resolvePassengerNameWithUserConfirmation(
        inputPassenger: String,
        in parentContext: NSManagedObjectContext,
        threshold: Double = 0.82
    ) async -> String {
        let child = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        child.parent = parentContext
        child.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        defer { child.reset() }

        do {
            let service = NameDedupService(context: child)
            let decision = try await service.deduplicateOrCreate(
                entityName: "TripEntity",
                nameKeyPath: "passenger",
                inputFullName: inputPassenger,
                threshold: threshold
            ) { ctx, cleanName in
                let tmp = TripEntity(context: ctx)
                tmp.passenger = cleanName
                return tmp
            }

            switch decision {
            case .useExisting(let existing, let score):
                let name = (existing as? TripEntity)?.passenger ?? inputPassenger
                log.notice("Passenger name auto-resolved to existing: \(name, privacy: .public) [similarity: \(score, format: .fixed(precision: 3))]")
                return name

            case .createdNew(let created, let score):
                let name = (created as? TripEntity)?.passenger ?? inputPassenger
                log.notice("Passenger name created new: \(name, privacy: .public) [similarity: \(score, format: .fixed(precision: 3))]")
                return name
            }
        } catch {
            log.error("Name resolution failed: \(error.localizedDescription, privacy: .public)")
            return inputPassenger
        }
    }

    // MARK: - Duplicate-trip precheck helpers

    /// Deterministic, *non-interactive* normalization for passenger names to build keys/compare duplicates.
    /// Uses your String normalization and uppercases for stability.
    private static func machineNormalizedPassenger(_ s: String) -> String {
        s.normalizedName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Looks up existing trips for the same airline+flight+day and compares passenger via machine normalization.
    /// This avoids relying on historical `naturalKey` formats.
    private static func findExistingTrip(
        airline: String,
        flightNumber: String,
        travelDay: Date,
        passengerNormalized: String,
        in context: NSManagedObjectContext
    ) -> TripEntity? {
        var hit: TripEntity?
        context.performAndWait {
            let req: NSFetchRequest<TripEntity> = TripEntity.fetchRequest()
            req.fetchLimit = 20
            req.predicate = NSPredicate(
                format: "airline ==[c] %@ AND flightNumber ==[c] %@ AND travelDate == %@",
                airline, flightNumber, travelDay as NSDate
            )
            if let candidates = try? context.fetch(req), !candidates.isEmpty {
                for t in candidates {
                    let existingNorm = machineNormalizedPassenger(t.passenger ?? "")
                    if existingNorm == passengerNormalized {
                        hit = t
                        break
                    }
                }
            }
        }
        return hit
    }

    // MARK: - Helpers

    private static func tripDescription(_ trip: TripEntity) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return """
        \(trip.airline ?? "—") \(trip.flightNumber ?? "—") on \(trip.travelDate.map(df.string(from:)) ?? "—")
        Passenger: \(trip.passenger ?? "—")
        """
    }

    /// Build a normalized natural key using **Airline + Flight Number + Travel Day + Passenger**.
    /// - Travel day is normalized to UTC "yyyy-MM-dd" to avoid TZ issues.
    private static func normalizedKey(
        airline: String,
        flightNumber: String,
        travelDate: Date,
        passenger: String
    ) -> String {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: travelDate)

        return [
            norm(airline),
            norm(flightNumber),
            day,
            norm(passenger)
        ].joined(separator: "|")
    }

    /// Convert IATA julian day to Date in the current year (day precision).
    private static func dateFromJulian(
        _ dayOfYear: Int,
        year: Int = Calendar.current.component(.year, from: Date())
    ) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        let cal = Calendar(identifier: .gregorian)
        guard let jan1 = cal.date(from: comps) else { return nil }
        return cal.date(byAdding: .day, value: dayOfYear - 1, to: jan1).map {
            cal.startOfDay(for: $0)
        }
    }
}
