//  BoardingPassService.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import UIKit
import Vision
import CoreData
import BoardingPassKit

/// Errors thrown by the boarding-pass processing pipeline.
enum BoardingPassServiceError: Error {
    case noCGImage
    case noBarcodeFound
}

/// A simple service for decoding an image of a boarding pass
/// and saving the parsed result into Core Data via TripStore.
struct BoardingPassService {

    /// Decode + save in one shot.
    /// - Parameters:
    ///   - image: the UIImage to scan
    ///   - rawData: the original Data blob (PNG/JPEG) to store in Core Data
    ///   - context: your NSManagedObjectContext
    /// - Returns: the parsed BoardingPass from BoardingPassKit
    static func process(
        image: UIImage,
        rawData: Data,
        in context: NSManagedObjectContext
    ) async throws -> BoardingPass {
        // 1) Extract the string payload from the barcode
        guard let cg = image.cgImage else {
            throw BoardingPassServiceError.noCGImage
        }
        let payload = try await extractBarcodePayload(from: cg)

        // 2) Decode into structured model
        let decoder = BoardingPassDecoder()
        let pass = try decoder.decode(code: payload)

        // 3) Persist via the single canonical TripStore.saveTrip(...)
        //    This stores metro-city names, passenger, photo, etc.
        _ = try TripStore.saveTrip(
            airline: pass.info.operatingCarrier,
            originCode: pass.info.origin,
            destCode: pass.info.destination,
            flightNumber: pass.info.flightno,
            julianDate: pass.info.julianDate,
            passenger: pass.info.name,
            imageData: rawData,
            in: context
        )

        return pass
    }

    // MARK: – Private helpers

    /// Runs Vision’s barcode detector on a CGImage and returns the first payload.
    private static func extractBarcodePayload(from cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNDetectBarcodesRequest { request, error in
                if let err = error {
                    cont.resume(throwing: err)
                    return
                }
                let payload = (request.results as? [VNBarcodeObservation])?
                    .compactMap(\.payloadStringValue)
                    .first
                if let payload {
                    cont.resume(returning: payload)
                } else {
                    cont.resume(throwing: BoardingPassServiceError.noBarcodeFound)
                }
            }
            request.symbologies = [.qr, .pdf417, .code128, .aztec]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
