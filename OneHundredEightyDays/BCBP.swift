//
//  BCBP.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//


import Foundation
import CoreData

// MARK: – BCBP Data Model

/// Simple container for the mandatory IATA BCBP fields.
struct BCBP {
    var name: String
    var pnr: String
    var origin: String
    var destination: String
    var operatingCarrier: String
    var flightNumber: String
    var julianDate: Int
    var seat: String
    var sequence: String
}

/// Errors thrown when the string is too short or not the expected format.
enum BCBPError: Error {
    case invalid
    case tooShort
}

// MARK: – Parser

/// Parses a raw BCBP payload into a typed struct.
/// Throws `.tooShort` if under 60 characters, or `.invalid` if it doesn’t start with “M”.
func parseBCBP(_ s: String) throws -> BCBP {
    let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard str.count >= 60 else { throw BCBPError.tooShort }
    let chars = Array(str)

    func slice(_ start: Int, _ len: Int) -> String {
        String(chars[start..<min(start+len, chars.count)])
          .trimmingCharacters(in: .whitespaces)
    }

    guard slice(0, 1) == "M" else { throw BCBPError.invalid }

    let name          = slice(2, 20).replacingOccurrences(of: "/", with: " ")
    let pnr           = slice(22, 7)
    let origin        = slice(29, 3)
    let destination   = slice(32, 3)
    let carrier       = slice(35, 3)
    let flightNumber  = slice(38, 5)
    let julian        = Int(slice(43, 3)) ?? 0
    let seat          = slice(54, 4)
    let sequence      = slice(58, 5)

    return .init(
      name: name,
      pnr: pnr,
      origin: origin,
      destination: destination,
      operatingCarrier: carrier,
      flightNumber: flightNumber,
      julianDate: julian,
      seat: seat,
      sequence: sequence
    )
}

// MARK: – Date Helper

/// Converts a Julian day-of-year into a Date in the current year.
func dateFromJulian(
  _ dayOfYear: Int,
  year: Int = Calendar.current.component(.year, from: Date())
) -> Date? {
    var comps = DateComponents()
    comps.year = year
    comps.month = 1
    comps.day = 1
    let cal = Calendar(identifier: .gregorian)
    guard let jan1 = cal.date(from: comps) else { return nil }
    return cal.date(byAdding: .day, value: dayOfYear-1, to: jan1)
}

// MARK: – Core Data Save
func saveTrip(from bc: BCBP, imageData: Data?, ctx: NSManagedObjectContext) throws {
    let trip = TripEntity(context: ctx)
    trip.id = UUID()
    trip.airline        = bc.operatingCarrier
    trip.departureCity  = bc.origin
    trip.arrivalCity    = bc.destination
    trip.flightNumber   = bc.flightNumber
    trip.travelDate     = dateFromJulian(bc.julianDate)
    trip.imageData      = imageData
    try ctx.save()
}

