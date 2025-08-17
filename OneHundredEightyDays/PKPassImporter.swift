//  PKPassImporter.swift
//  OneHundredEightyDays
//
//  iOS 16+
//

import Foundation
import ZIPFoundation
import CoreData
import BoardingPassKit
import OSLog

enum PKPassImporterError: Error {
    case notAZip
    case noPassJSON
    case invalidJSON
    case noBarcodeMessage
}

struct PKPassImporter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OneHundredEightyDays",
        category: "PKPassImporter"
    )

    /// Main entry: import `.pkpass`, decode BCBP, persist trip
    static func importPKPassData(
        _ data: Data,
        in context: NSManagedObjectContext
    ) async throws -> BoardingPass {

        // 1) Unzip into memory (use the throwing initializer to avoid deprecation)
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw PKPassImporterError.notAZip
        }

        // 2) Extract pass.json
        var jsonData: Data?
        for entry in archive where entry.path == "pass.json" {
            var tmp = Data()
            _ = try archive.extract(entry, consumer: { tmp.append($0) })
            jsonData = tmp
            break
        }
        guard let jsonData else { throw PKPassImporterError.noPassJSON }

        // 3) Decode pass.json
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { throw PKPassImporterError.invalidJSON }

        // 4) Extract BCBP payload
        var payload: String?
        if let barcodes = dict["barcodes"] as? [[String: Any]] {
            payload = barcodes.first?["message"] as? String
        } else if let barcode = dict["barcode"] as? [String: Any] {
            payload = barcode["message"] as? String
        }
        guard let payload, !payload.isEmpty else { throw PKPassImporterError.noBarcodeMessage }

        // 5) Sanitize + decode with BoardingPassKit
        let safeCode = try BoardingPassService.sanitizeForDependencyDecoder(payload)
        let pass = try BoardingPassDecoder().decode(code: safeCode)

        // 6) Persist Trip (same pipeline used elsewhere)
        _ = try await TripStore.saveTripAsync(
            airline: pass.info.operatingCarrier,
            originCode: pass.info.origin,
            destCode: pass.info.destination,
            flightNumber: pass.info.flightno,
            julianDate: pass.info.julianDate,
            passenger: pass.info.name,
            imageData: data,     // store the raw .pkpass blob
            in: context
        ) // TripStore handles duplicate precheck + natural key:contentReference[oaicite:1]{index=1}

        logger.notice("Imported .pkpass for \(pass.info.operatingCarrier) \(pass.info.flightno)")
        return pass
    }
}
