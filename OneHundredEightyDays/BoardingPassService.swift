//  BoardingPassService.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import UIKit
import Vision
import CoreData
import BoardingPassKit
import OSLog

/// Errors thrown by the boarding-pass processing pipeline.
enum BoardingPassServiceError: Error {
    case noCGImage
    case noBarcodeFound
    case nonASCII
    case payloadTooShort
}

/// A simple service for decoding an image of a boarding pass
/// and saving the parsed result into Core Data via TripStore.
struct BoardingPassService {

    // Logger for diagnostics
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OneHundredEightyDays",
        category: "BoardingPassService"
    )

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
        guard let cg = image.cgImage else { throw BoardingPassServiceError.noCGImage }
        let rawPayload = try await extractBarcodePayload(from: cg)

        // 2) Sanitize for dependency decoder (pad conditional bytes & set size)
        let safeCode = try sanitizeForDependencyDecoder(rawPayload)

        #if DEBUG
        print("Sanitized BCBP length = \(safeCode.count)")
        #endif
        logger.debug("Sanitized BCBP length = \(safeCode.count, privacy: .public)")

        // 3) Decode the boarding pass
                let pass = try BoardingPassDecoder().decode(code: safeCode)

                // 4) Persist the trip (use async API; do NOT call the deprecated sync wrapper)
                _ = try await TripStore.saveTripAsync(
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

    // MARK: – Dependency-safe sanitization

    /// Make the code safe for the dependency's decoder by:
    ///  - stripping CR/LF
    ///  - removing the security block ('>' and after)
    ///  - ensuring there are enough conditional bytes after the first 60 bytes
    ///    to satisfy the decoder's unconditional reads in `breakdown()`/`mainSegment()`
    ///  - setting the 2 ASCII-hex "parent conditional size" to match the bytes available
    ///
    /// The current decoder reads, after the 60-byte parent:
    ///   conditional(1), conditional(1), readhex(2, false)  -> 4 bytes
    ///   then in mainSegment():
    ///     readhex(2, false)                                 -> +2
    ///     desc(1), sourceCheck(1), sourcePass(1),
    ///     dateIssued(4), docType(1), airDesig(3), bagtag(13)-> +24
    ///     readhex(2, false)                                 -> +2
    ///     airlineCode(3), docnumber(10), selectee(1),
    ///     docVerify(1), opCarrier(3), ffAirline(3), ffNumber(16) -> +37
    ///  -> MIN_CONDITIONAL = 4 + 2 + 24 + 2 + 37 = 67 bytes
    private static func sanitizeForDependencyDecoder(_ code: String) throws -> String {
        guard code.canBeConverted(to: .ascii) else { throw BoardingPassServiceError.nonASCII }
        var bytes = Array(code.utf8)

        // Remove CR/LF
        bytes.removeAll { $0 == 0x0D || $0 == 0x0A }

        // Drop security block at first '>'
        if let gt = bytes.firstIndex(of: 0x3E) { // '>'
            bytes = Array(bytes.prefix(gt))
        }

        // Require parent mandatory block
        guard bytes.count >= 60 else { throw BoardingPassServiceError.payloadTooShort }

        // How many bytes are currently after the first 60?
        var after60 = bytes.count - 60

        // Ensure we have enough conditional bytes to satisfy the decoder's
        // unconditional reads (see table above).
        let MIN_CONDITIONAL = 67
        if after60 < MIN_CONDITIONAL {
            let pad = MIN_CONDITIONAL - after60
            // pad with ASCII '0' (any visible ASCII works for this decoder)
            bytes.append(contentsOf: Array(repeating: UInt8(ascii: "0"), count: pad))
            after60 = MIN_CONDITIONAL
        }

        // Set the "parent conditional size" (2 ASCII hex chars) to match `after60`.
        // This decoder reads those two hex chars at the END of the parent block,
        // so they're the last two bytes of the 60-byte parent (indices 58 & 59).
        let condSize = min(after60, 0xFF) // 2 hex digits (00..FF)
        let hex = String(format: "%02X", condSize).utf8.map { $0 } // two ASCII bytes
        bytes[58] = hex[0]
        bytes[59] = hex[1]

        // Done
        guard let out = String(bytes: bytes, encoding: .ascii) else {
            throw BoardingPassServiceError.nonASCII
        }

        #if DEBUG
        print("sanitizeForDecoder: bytes after 60 (declared) = \(after60) (hex \(String(format: "%02X", condSize)))")
        #endif
        return out
    }

    // MARK: – Vision

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
