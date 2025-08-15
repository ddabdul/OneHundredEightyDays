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

    // MARK: - Public API

    /// Single save entry-point used by the whole app.
    /// - Important: Requires a `naturalKey: String` attribute on TripEntity (unique constraint recommended).
    /// - Parameters:
    ///   - airline: Operating carrier (e.g., "SN")
    ///   - originCode: IATA airport code
    ///   - destCode: IATA airport code
    ///   - flightNumber: "1234" (do not include airline code)
    ///   - julianDate: IATA BCBP julian day-of-year
    ///   - passenger: Full passenger name (first + family) as printed
    ///   - imageData: Original PNG/JPEG of the boarding pass (optional)
    ///   - context: NSManagedObjectContext to write into
    /// - Returns: The `TripEntity` (existing if duplicate, or newly inserted/updated)
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

        // Resolve travel date (day precision)
        let date = dateFromJulian(julianDate) ?? Date()
        let day   = Calendar.current.startOfDay(for: date)

        // Build normalized natural key (AIRLINE|FLIGHT|YYYY-MM-DD|PASSENGER)
        let key = normalizedKey(
            airline: airline,
            flightNumber: flightNumber,
            travelDate: day,
            passenger: passenger
        )

        // Generate user-facing display values (metro city aware)
        let departDisplay = airportLookup.displayName(for: originCode)
        let arriveDisplay = airportLookup.displayName(for: destCode)

        // ISO 3166-1 alpha-2 country codes from AirportLite (uppercased for consistency)
        let departISO = airportLookup.airport(for: originCode)?.country.uppercased() ?? ""
        let arriveISO = airportLookup.airport(for: destCode)?.country.uppercased() ?? ""

        var saved: TripEntity!
        var captured: Error?

        // Respect the context’s queue
        context.performAndWait {
            // 1) Check for an existing trip with the same natural key
            let req: NSFetchRequest<TripEntity> = TripEntity.fetchRequest()
            req.fetchLimit = 1
            req.predicate = NSPredicate(format: "naturalKey == %@", key)

            _ = (try? context.fetch(req))?.first

            if let trip = (try? context.fetch(req))?.first {
                          // === DUPLICATE PATH ===
                          // Per requirement: do not modify or save anything, just return the existing row.
                          saved = trip

                          // Optional: still emit a signal so the UI can show a toast/badge, etc. (no DB writes)
                          log.notice("Duplicate trip detected: \(tripDescription(trip), privacy: .public)")
                          NotificationCenter.default.post(
                              name: .tripDuplicateDetected,
                              object: nil,
                              userInfo: ["message": tripDescription(trip)]
                          )
                          return
                      }

            // 3) Otherwise, insert a brand new TripEntity
            let trip = TripEntity(context: context)
            trip.id               = UUID()
            trip.naturalKey       = key
            trip.airline          = airline
            trip.flightNumber     = flightNumber
            trip.travelDate       = day
            trip.passenger        = passenger
            trip.departureCity    = departDisplay
            trip.arrivalCity      = arriveDisplay
            trip.departureCountry = departISO        // NEW
            trip.arrivalCountry   = arriveISO        // NEW
            trip.imageData        = imageData

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
