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

    /// Async save. IMPORTANT: we lock the natural key to the **RAW** passenger input
    /// so that name de-dup confirmation never affects uniqueness / duplicate detection.
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

        // 2) Build and FIX the natural key using the **raw** passenger name.
        let fixedKey = normalizedKey(
            airline: airline,
            flightNumber: flightNumber,
            travelDate: day,
            passenger: passenger                 // <-- raw, not resolved
        )

        // 3) Fast duplicate check on the fixed key (and bail out early)
        if let existing = fetchTrip(withKey: fixedKey, in: context) {
            log.notice("Duplicate trip detected (raw passenger key): \(tripDescription(existing), privacy: .public)")
            NotificationCenter.default.post(
                name: .tripDuplicateDetected,
                object: nil,
                userInfo: ["message": tripDescription(existing)]
            )
            return existing
        }

        // 4) No trip yet → resolve/confirm passenger name (may prompt the user)
        let resolvedPassenger = await resolvePassengerNameWithUserConfirmation(
            inputPassenger: passenger,
            in: context,
            threshold: similarityThreshold
        )

        // 5) Generate display strings and country codes
        let departDisplay = airportLookup.displayName(for: originCode)
        let arriveDisplay = airportLookup.displayName(for: destCode)

        let departISO = airportLookup.airport(for: originCode)?.country.uppercased() ?? ""
        let arriveISO = airportLookup.airport(for: destCode)?.country.uppercased() ?? ""

        var saved: TripEntity!
        var captured: Error?

        // Respect the context’s queue
        context.performAndWait {
            // === DIRECT INSERT (no second duplicate check, no re-keying) ===
            let trip = TripEntity(context: context)
            trip.id                   = UUID()
            trip.naturalKey           = fixedKey            // <-- stays the *raw* passenger key
            trip.airline              = airline
            trip.flightNumber         = flightNumber
            trip.travelDate           = day
            trip.passenger            = resolvedPassenger   // <-- what the user chose/confirmed
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

        if let err = captured {
            throw TripStoreError.saveFailed(err)
        }
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

    // MARK: - Name resolution (calls your existing NameDedupService)

    /// Runs the passenger name de-dup flow in a child context, returns the final name to store.
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
            case .useExisting(let existing):
                return (existing as? TripEntity)?.passenger ?? inputPassenger
            case .createdNew(let created):
                return (created as? TripEntity)?.passenger ?? inputPassenger
            }
        } catch {
            log.error("Name resolution failed: \(error.localizedDescription, privacy: .public)")
            return inputPassenger
        }
    }

    // MARK: - Helpers

    /// FAST fetch for an existing trip by natural key.
    private static func fetchTrip(withKey key: String, in context: NSManagedObjectContext) -> TripEntity? {
        var result: TripEntity?
        context.performAndWait {
            let req: NSFetchRequest<TripEntity> = TripEntity.fetchRequest()
            req.fetchLimit = 1
            req.predicate = NSPredicate(format: "naturalKey == %@", key)
            result = try? context.fetch(req).first
        }
        return result
    }

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
