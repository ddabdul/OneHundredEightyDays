//
//  BoardingPassService.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import UIKit
import Vision
import CoreData
import BoardingPassKit

/// Provides ISO country-code → localized country name conversion.
private extension String {
    /// Returns the localized name for a 2-letter ISO country code (e.g. “DE” → “Germany”).
    var countryName: String? {
        Locale.current.localizedString(forRegionCode: self.uppercased())
    }
}

/// Errors thrown by the boarding-pass processing pipeline.
enum BoardingPassServiceError: Error {
    case noCGImage
    case noBarcodeFound
}

/// A simple service for decoding an image of a boarding pass
/// and saving the parsed result into your existing TripEntity.
/// Now will look up full city & country names via `AirportData.shared`.
struct BoardingPassService {
  
    /// Decode + save in one shot.
    /// - Parameters:
    ///   - image: the UIImage to scan
    ///   - rawData: the original Data blob (PNG/JPEG) to store in Core Data
    ///   - context: your NSManagedObjectContext
    /// - Returns: the parsed `BoardingPass` from BoardingPassKit
    static func process(
        image: UIImage,
        rawData: Data,
        in context: NSManagedObjectContext
    ) async throws -> BoardingPass {
        // 1) extract the string payload
        guard let cg = image.cgImage else {
            throw BoardingPassServiceError.noCGImage
        }
        let payload = try await extractBarcodePayload(from: cg)
        
        // 2) decode into structured model
        let decoder = BoardingPassDecoder()
        let pass = try decoder.decode(code: payload)
        
        // 3) persist into Core Data (with full city + country names)
        save(pass: pass, imageData: rawData, in: context)
        
        return pass
    }
    
    // MARK: – Private helpers
    
    /// Runs Vision’s barcode detector on a CGImage and returns the first payload.
    private static func extractBarcodePayload(
        from cgImage: CGImage
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNDetectBarcodesRequest { request, error in
                if let err = error {
                    cont.resume(throwing: err)
                } else if
                    let obs = request.results?
                        .compactMap({ $0 as? VNBarcodeObservation })
                        .compactMap(\.payloadStringValue)
                        .first
                {
                    cont.resume(returning: obs)
                } else {
                    cont.resume(throwing: BoardingPassServiceError.noBarcodeFound)
                }
            }
            // supported symbologies
            request.symbologies = [.qr, .pdf417, .code128, .aztec]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
    
    /// Maps the decoded `BoardingPass` to your `TripEntity` and saves,
    /// converting IATA codes into “City, Country” strings when possible.
    private static func save(
        pass: BoardingPass,
        imageData: Data,
        in context: NSManagedObjectContext
    ) {
        let trip = TripEntity(context: context)
        trip.id            = UUID()
        
        // Lookup origin airport
        let originCode = pass.info.origin
        if let airport = AirportData.shared.airport(for: originCode) {
            let countryName = airport.country.countryName ?? airport.country
            trip.departureCity = "\(airport.city), \(countryName)"
        } else {
            trip.departureCity = originCode
        }
        
        // Lookup destination airport
        let destCode = pass.info.destination
        if let airport = AirportData.shared.airport(for: destCode) {
            let countryName = airport.country.countryName ?? airport.country
            trip.arrivalCity = "\(airport.city), \(countryName)"
        } else {
            trip.arrivalCity = destCode
        }
        
        trip.airline       = pass.info.operatingCarrier
        trip.flightNumber  = pass.info.flightno
        trip.travelDate    = dateFromJulian(pass.info.julianDate)
        trip.imageData     = imageData
        
        do {
            try context.save()
        } catch {
            // handle Core Data error appropriately in production
            print("⚠️ Failed to save TripEntity:", error)
        }
    }
    
    /// Julian-to-Date helper (same as before).
    private static func dateFromJulian(
        _ day: Int,
        year: Int = Calendar.current.component(.year, from: Date())
    ) -> Date? {
        var comps = DateComponents(year: year, month: 1, day: 1)
        let cal = Calendar(identifier: .gregorian)
        guard let jan1 = cal.date(from: comps) else { return nil }
        return cal.date(byAdding: .day, value: day - 1, to: jan1)
    }
}
