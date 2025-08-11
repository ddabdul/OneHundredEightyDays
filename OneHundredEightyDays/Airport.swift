// AirportData.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.

import Foundation

// What we need at runtime
struct Airport: Decodable {
    let code: String                 // IATA airport code, e.g. "LHR"
    let name: String
    let city: String
    let countryCode: String          // ISO like "GB"
    let cityCode: String?            // metro code, e.g. "LON"

    var country: String {
        Locale.current.localizedString(forRegionCode: countryCode.uppercased()) ?? countryCode
    }
}

// JSON row shape (your file is an array of these)
private struct AirportRow: Decodable {
    let code: String
    let name: String?
    let city: String?
    let country: String?
    let city_code: String?
}

final class AirportData {
    static let shared = AirportData()

    // Index by airport code ("LHR" → Airport)
    private var byAirport: [String: Airport] = [:]
    // Index by city/metro code ("LON" → ("London","GB"))
    private var byCityCode: [String: (city: String, countryCode: String)] = [:]

    private init() {
        let b = Bundle.main
        let url = b.url(forResource: "airports", withExtension: "json")
              ?? b.url(forResource: "Airports", withExtension: "json")
              ?? b.url(forResource: "airports", withExtension: "json", subdirectory: "airports")
        guard let url else {
            let all = b.paths(forResourcesOfType: "json", inDirectory: nil)
            print("⚠️ Could not load airports.json. JSONs in bundle: \(all)")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let rows = try JSONDecoder().decode([AirportRow].self, from: data)

            for r in rows {
                guard let n = r.name, let cc = r.country else { continue }

                let airport = Airport(
                    code: r.code.uppercased(),
                    name: n,
                    city: (r.city ?? "").trimmingCharacters(in: .whitespaces),
                    countryCode: cc,
                    cityCode: r.city_code?.uppercased()
                )

                byAirport[airport.code] = airport

                if let metro = airport.cityCode, !metro.isEmpty {
                    // prefer an entry that has a city name
                    let current = byCityCode[metro]
                    let cityName = airport.city.isEmpty ? (current?.city ?? "") : airport.city
                    byCityCode[metro] = (cityName, airport.countryCode)
                }
            }
        } catch {
            print("⚠️ Failed to decode airports.json:", error)
        }
    }

    /// For compatibility if you already call this somewhere.
    func airport(for code: String) -> Airport? { byAirport[code.uppercased()] }

    /// NEW: returns "City, Country" for either an airport IATA code *or* a city/metro code.
    func displayName(forCode code: String) -> String {
        let key = code.uppercased()

        if let a = byAirport[key] {
            let city = a.city.isEmpty ? a.name : a.city
            return "\(city), \(a.country)"
        }
        if let metro = byCityCode[key] {
            let country = Locale.current.localizedString(forRegionCode: metro.countryCode.uppercased()) ?? metro.countryCode
            return "\(metro.city), \(country)"
        }
        return code // fallback if unknown
    }
}
