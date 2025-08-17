//
//  PKPassImporterError.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 17/08/2025.
//


//  PKPassImporter.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 17/08/2025.
//

import Foundation
import ZIPFoundation
import CoreData
import BoardingPassKit
import OSLog

/// Errors specific to .pkpass import
enum PKPassImporterError: Error {
    case notAZip
    case noPassJSON
    case invalidJSON
    case noBarcodeMessage
}

/// Handles `.pkpass` files shared from Wallet / Files
struct PKPassImporter {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OneHundredEightyDays",
        category: "PKPassImporter"
    )

    /// Main entry: import and persist
    static func importPKPassData(
        _ data: Data,
        in context: NSManagedObjectContext
    ) async throws -> BoardingPass {
        // 1) Unzip into memory
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PKPassImporterError.notAZip
        }

        var jsonData: Data?
        for entry in archive {
            if entry.path == "pass.json" {
                var tmp = Data()
                _ = try archive.extract(entry, consumer: { tmp.append($0) })
                jsonData = tmp
                break
            }
        }
        guard let jsonData else { throw PKPassImporterError.noPassJSON }

        // 2) Decode pass.json
        guard
            let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { throw PKPassImporterError.invalidJSON }

        // 3) Find barcode message
        var payload: String?
        if let barcodes = dict["barcodes"] as? [[String: Any]] {
            payload = barcodes.first?["message"] as? String
        } else if let barcode = dict["barcode"] as? [String: Any] {
            payload = barcode["message"] as? String
        }
        guard let payload, !payload.isEmpty else {
            throw PKPassImporterError.noBarcodeMessage
        }

        // 4) Reuse your existing sanitizer
        let safeCode = try BoardingPassService.sanitizeForDependencyDecoder(payload)

        // 5) Decode with BoardingPassKit
        let pass = try BoardingPassDecoder().decode(code: safeCode)

        // 6) Persist Trip (reuse TripStore)
        _ = try await TripStore.saveTripAsync(
            airline: pass.info.operatingCarrier,
            originCode: pass.info.origin,
            destCode: pass.info.destination,
            flightNumber: pass.info.flightno,
            julianDate: pass.info.julianDate,
            passenger: pass.info.name,
            imageData: data,   // store the raw pkpass blob instead of screenshot
            in: context
        )

        logger.notice("Imported .pkpass successfully for \(pass.info.operatingCarrier) \(pass.info.flightno)")
        return pass
    }
}
