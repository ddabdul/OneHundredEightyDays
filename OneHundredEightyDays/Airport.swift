// AirportData.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.

import Foundation

// What your app needs at runtime
struct Airport: Decodable {
    let name: String
    let city: String
    let countryCode: String          // e.g. "DE"
    var country: String {            // "Germany" (localized)
        Locale.current.localizedString(forRegionCode: countryCode.uppercased()) ?? countryCode
    }
}

// Shape used when the JSON is an array of rows
private struct AirportRow: Decodable {
    let code: String
    let name: String?
    let city: String?
    let country: String?
    enum CodingKeys: String, CodingKey { case code, name, city, country }
}

final class AirportData {
    static let shared = AirportData()
    private(set) var lookup: [String: Airport] = [:]

    private init() {
        let bundle = Bundle.main
        // Find the file (top-level or under a folder named "airports")
        let url = bundle.url(forResource: "airports", withExtension: "json")
              ?? bundle.url(forResource: "Airports", withExtension: "json")
              ?? bundle.url(forResource: "airports", withExtension: "json", subdirectory: "airports")
        guard let url else {
            let all = bundle.paths(forResourcesOfType: "json", inDirectory: nil)
            print("⚠️ Could not load airports.json. JSONs in bundle:", all)
            return
        }

        do {
            let data = try Data(contentsOf: url)

            // 1) Try dictionary shape: { "FRA": {name, city, countryCode}, ... }
            if let dict = try? JSONDecoder().decode([String: Airport].self, from: data) {
                self.lookup = dict.reduce(into: [:]) { $0[$1.key.uppercased()] = $1.value }
                return
            }

            // 2) Fallback: array shape: [ { "code": "FRA", "name": "...", "city": "...", "country": "DE", ... }, ... ]
            let rows = try JSONDecoder().decode([AirportRow].self, from: data)
            self.lookup = rows.reduce(into: [:]) { acc, r in
                guard let n = r.name, let c = r.city, let cc = r.country else { return }
                acc[r.code.uppercased()] = Airport(name: n, city: c, countryCode: cc)
            }
        } catch {
            print("⚠️ Failed to decode airports.json:", error)
        }
    }

    func airport(for code: String) -> Airport? {
        lookup[code.uppercased()]
    }
}
