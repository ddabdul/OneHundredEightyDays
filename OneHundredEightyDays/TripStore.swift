//
//  TripStore.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 11/08/2025.
//

import Foundation
import CoreData
import BoardingPassKit

/// Central place to persist trips to Core Data (TripEntity).
/// Uses AirportData to show "City, Country" from IATA/city codes.
enum TripStoreError: Error { case saveFailed }

struct TripStore {

    /// Save from your manual BCBP parser.
    @discardableResult
    static func saveFromBCBP(_ bc: BCBP,
                             imageData: Data?,
                             in context: NSManagedObjectContext) throws -> TripEntity {
        try saveCommon(
            airline: bc.operatingCarrier,
            originCode: bc.origin,
            destCode: bc.destination,
            flightNumber: bc.flightNumber,
            travelDate: dateFromJulian(bc.julianDate),
            imageData: imageData,
            in: context
        )
    }

    /// Save from BoardingPassKit’s `BoardingPass`.
    @discardableResult
    static func saveFromBoardingPass(_ pass: BoardingPass,
                                     imageData: Data?,
                                     in context: NSManagedObjectContext) throws -> TripEntity {
        try saveCommon(
            airline: pass.info.operatingCarrier,
            originCode: pass.info.origin,
            destCode: pass.info.destination,
            flightNumber: pass.info.flightno,
            travelDate: dateFromJulian(pass.info.julianDate),
            imageData: imageData,
            in: context
        )
    }

    // MARK: - Shared write path

    @discardableResult
    private static func saveCommon(airline: String,
                                   originCode: String,
                                   destCode: String,
                                   flightNumber: String,
                                   travelDate: Date?,
                                   imageData: Data?,
                                   in context: NSManagedObjectContext) throws -> TripEntity {

        var capturedError: Error?
        var saved: TripEntity!

        // Ensure we respect the context’s queue.
        context.performAndWait {
            let trip = TripEntity(context: context)
            trip.id = UUID()
            trip.airline = airline
            trip.departureCity = AirportData.shared.displayName(forCode: originCode)
            trip.arrivalCity   = AirportData.shared.displayName(forCode: destCode)
            trip.flightNumber  = flightNumber
            trip.travelDate    = travelDate
            trip.imageData     = imageData

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
}
