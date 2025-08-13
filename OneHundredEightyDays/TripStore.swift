//  TripStore.swift
//  OneHundredEightyDays
//
//  Single canonical save entry point.
//  - departureCity / arrivalCity: metro city names (e.g., BRU -> "Brussels").
//  - travel date: derived from julianDate if provided, otherwise you can pass nil.
//

import Foundation
import CoreData
import BoardingPassKit

enum TripStoreError: Error { case saveFailed }

struct TripStore {

    /// Immutable, thread-safe lookup that resolves IATA → metro city.
    private static let airportLookup = AirportLookup()

    /// The ONLY save function.
    /// Call this for every source (BCBP, BoardingPassKit, manual).
    ///
    /// - Parameters:
    ///   - airline: Operating carrier code (e.g., "SN").
    ///   - originCode: IATA airport code of departure (e.g., "BRU").
    ///   - destCode: IATA airport code of destination (e.g., "HAM").
    ///   - flightNumber: Numeric/alpha flight number.
    ///   - julianDate: Optional julian day. If non-nil, will be converted to Date.
    ///   - passenger: Optional passenger full name ("First Last").
    ///   - imageData: Optional raw image data of the boarding-pass photo.
    ///   - context: Core Data context to write into.
    @discardableResult
    static func saveTrip(airline: String,
                         originCode: String,
                         destCode: String,
                         flightNumber: String,
                         julianDate: Int?,
                         passenger: String?,
                         imageData: Data?,
                         in context: NSManagedObjectContext) throws -> TripEntity {

        // Compute date from julian if available
        let computedDate = julianDate.flatMap { dateFromJulian($0) }

        var capturedError: Error?
        var saved: TripEntity!

        context.performAndWait {
            let trip = TripEntity(context: context)
            trip.id = UUID()
            trip.airline = airline
            trip.flightNumber = flightNumber
            trip.travelDate = computedDate
            trip.passenger = passenger?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Store METRO CITY NAMES only (e.g., "Brussels", "Hamburg")
            trip.departureCity = metroCityName(for: originCode)
            trip.arrivalCity   = metroCityName(for: destCode)

            // Keep the photo (if any)
            trip.imageData = imageData

            do {
                try context.save()
                saved = trip
            } catch {
                capturedError = error
            }
        }

        if let err = capturedError { throw err }
        return saved
    }

    // MARK: - Helpers

    /// Returns the metro city name for an airport code.
    /// Falls back to airport's municipality (or airport name) when the city index is missing.
    private static func metroCityName(for code: String) -> String {
        let u = code.uppercased()

        if let metro = airportLookup.metroCity(for: u), !metro.isEmpty {
            return metro
        }

        if let a = airportLookup.airport(for: u) {
            // If airport's `city` is empty, fall back to airport name.
            let municipal = a.city.isEmpty ? a.name : a.city
            return municipal
        }

        // Last resort: store the raw code so the UI shows *something*
        return u
    }
}
