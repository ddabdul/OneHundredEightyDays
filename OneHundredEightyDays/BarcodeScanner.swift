//
//  BarcodeScanner.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//
import Vision
import UIKit

/// Returns the first payloadStringValue for a supported symbology
func detectBarcode(in image: UIImage) async throws -> String? {
    guard let cgImage = image.cgImage else {
        throw NSError(
          domain: "",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Could not get CGImage"]
        )
    }

    return try await withCheckedThrowingContinuation { cont in
        let request = VNDetectBarcodesRequest { req, err in
            if let e = err {
                cont.resume(throwing: e)
            } else {
                let payload = (req.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue }
                    .first
                cont.resume(returning: payload)
            }
        }
        request.symbologies = [.qr, .aztec, .pdf417, .code128]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            cont.resume(throwing: error)
        }
    }
}

