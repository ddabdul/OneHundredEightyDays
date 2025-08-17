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

        // 2) Sanitize for dependency decoder (pad & set all required conditional sizes)
        let safeCode = try sanitizeForDependencyDecoder(rawPayload)

        #if DEBUG
        print("Sanitized BCBP length = \(safeCode.count)")
        #endif
        logger.debug("Sanitized BCBP length = \(safeCode.count, privacy: .public)")

        // 3) Decode the boarding pass
        let pass = try BoardingPassDecoder().decode(code: safeCode)

        // 4) Persist the trip (async save)
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
    ///  - trimming whitespace/CR/LF
    ///  - removing the security block ('>' and after)
    ///  - enforcing ASCII
    ///  - ensuring the first two bytes look like a BCBP header ("M" + legs>=1)
    ///  - ensuring there are enough conditional bytes after the first 60 bytes
    ///    to satisfy the decoder's unconditional reads
    ///  - setting **three** ASCII-hex length fields the decoder expects:
    ///      * parent conditional size -> bytes 58..59
    ///      * mainSegment block A size (desc..bagtag 24 bytes) -> bytes 60+2..60+3
    ///      * mainSegment block B size (airlineCode..ffNumber 37 bytes) -> bytes 60+4+24 .. +1
    ///
    /// MIN layout consumed by the decoder in the conditional area:
    ///   parent:       condFlag(1) + condFlag(1) + hexLenA(2)       = 4
    ///   mainSegmentA: payload (desc..bagtag)                       = 24
    ///   mainSegmentB: hexLenB(2) + payload (airline..ffNumber)     = 2 + 37
    ///   -------------------------------------------------------------- total = 67
    static func sanitizeForDependencyDecoder(_ raw: String) throws -> String {
        // Normalize whitespace and drop CR/LF
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll(where: { $0 == "\r" || $0 == "\n" })

        // Remove security block at first '>'
        if let gt = s.firstIndex(of: ">") { s = String(s[..<gt]) }

        // Enforce ASCII
        guard s.canBeConverted(to: .ascii) else { throw BoardingPassServiceError.nonASCII }

        // Turn into an ASCII byte array for easy patching
        var bytes = Array(s.utf8)
        guard bytes.count >= 60 else { throw BoardingPassServiceError.payloadTooShort }

        // Ensure header looks sane: 'M'/'N' and legs >= 1
        if bytes[0] != UInt8(ascii: "M") && bytes[0] != UInt8(ascii: "N") {
            bytes[0] = UInt8(ascii: "M")
        }
        // If legs char not 1..4, force '1'
        if bytes.count >= 2 {
            let c = bytes[1]
            if c < UInt8(ascii: "1") || c > UInt8(ascii: "4") {
                bytes[1] = UInt8(ascii: "1")
            }
        }

        // Bytes available after the mandatory 60
        var after60 = bytes.count - 60

        // The decoder unconditionally reads at least this much from the conditional area:
        // 2 flags + 2 + 24 + 2 + 37 = 67
        let MIN_CONDITIONAL = 67
        if after60 < MIN_CONDITIONAL {
            bytes.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: (MIN_CONDITIONAL - after60)))
            after60 = MIN_CONDITIONAL
        }

        // Helper: set a 2-byte ASCII-hex at position
        @inline(__always) func writeHex2(_ value: Int, at index: Int) {
            let v = max(0, min(0xFF, value))
            let hex = String(format: "%02X", v).utf8.map { $0 }
            bytes[index] = hex[0]
            bytes[index + 1] = hex[1]
        }

        // 1) Parent conditional size lives at the END of the 60-byte parent block (positions 58 & 59).
        writeHex2(after60, at: 58)

        // Layout inside the conditional area starting at offset 60:
        // [60]   flag1 (1)
        // [61]   flag2 (1)
        // [62..63] hexLenA (2)  -> should describe next 24 bytes
        // [64..(63+2+24)] payloadA (24)
        // [88..89] hexLenB (2)  -> should describe next 37 bytes
        // [90..]    payloadB (37)
        // We’ll set LenA=24 and LenB=37 so decoder’s reads match what we padded.
        let offset = 60
        writeHex2(24, at: offset + 2)            // hexLenA
        writeHex2(37, at: offset + 4 + 24)       // hexLenB (right after payloadA)

        // Reconstitute ASCII string
        guard let out = String(bytes: bytes, encoding: .ascii) else {
            throw BoardingPassServiceError.nonASCII
        }

        #if DEBUG
        print("sanitizeForDecoder: after60=\(after60) (parent hex \(String(format: "%02X", min(after60, 0xFF))))")
        #endif
        return out
    }

    // MARK: – Vision

    /// Runs Vision’s barcode detector on a CGImage and returns the *best* payload.
    private static func extractBarcodePayload(from cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNDetectBarcodesRequest { request, error in
                if let err = error {
                    cont.resume(throwing: err)
                    return
                }
                guard let results = request.results as? [VNBarcodeObservation], !results.isEmpty else {
                    cont.resume(throwing: BoardingPassServiceError.noBarcodeFound)
                    return
                }
                // Prefer observations with a payload and highest confidence
                let payload = results
                    .sorted { $0.confidence > $1.confidence }
                    .compactMap { $0.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })

                if let payload {
                    cont.resume(returning: payload)
                } else {
                    cont.resume(throwing: BoardingPassServiceError.noBarcodeFound)
                }
            }
            request.symbologies = [.aztec, .qr, .pdf417, .code128] // airlines use all three, Aztec first

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
