//
//  Airport.swift
//  OneHundredEightyDays
//
//  Uses CityCodes_full.plist to resolve IATA "city code" → metro city names.
//  Example: BRU (Zaventem municipality) → Brussels (metro city).
//

import Foundation
import os

// MARK: - Models

/// Compact airport record decoded from `airports_compact.plist`.
/// - Note: `country` is ISO 3166-1 alpha-2 (e.g., "DE", "GB").
/// - Note: `cityCode` is the IATA "metro" code used to join with CityCodes_full.plist.
struct AirportLite: Decodable, Sendable {
    let city: String            // municipality/city near the airport (may be Zaventem for BRU)
    let country: String         // ISO alpha-2
    let cityCode: String        // IATA "city" (metro) code
    let name: String            // airport name

    /// Localized country display name for the current user locale.
    var localizedCountryName: String {
        CountryNamer.shared.name(for: country)
    }
}

/// Entry decoded from `CityCodes_full.plist` (array of dictionaries).
/// Keys: city, region (may be ""), countryCode (ISO alpha-2), cityCode (IATA).
struct CityIndexEntry: Decodable, Sendable {
    let city: String
    let region: String
    let countryCode: String
    let cityCode: String
}

// MARK: - Country name localization

/// Resolves localized country names from ISO region codes, with caching.
/// Thread-safe via an internal lock. Cache is cleared when the system locale changes.
final class CountryNamer {
    static let shared = CountryNamer()

    private let log = Logger(subsystem: "OneHundredEightyDays", category: "CountryNamer")
    private var cache: [CacheKey: String] = [:]
    private let lock = NSLock()

    private struct CacheKey: Hashable {
        let locale: String
        let region: String
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            lock.lock()
            cache.removeAll()
            lock.unlock()
            log.debug("Locale changed, cleared country name cache")
        }
    }

    /// Returns the localized country display name for a given ISO region code.
    func name(for regionCode: String, locale: Locale = .autoupdatingCurrent) -> String {
        let code = regionCode.uppercased()
        let key = CacheKey(locale: locale.identifier, region: code)

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let localized = locale
            .localizedString(forRegionCode: code)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let value = (localized?.isEmpty == false) ? localized! : code

        lock.lock()
        cache[key] = value
        lock.unlock()
        return value
    }
}

// MARK: - City index (IATA city/metro code → display info)

/// Immutable lookup built from CityCodes_full.plist.
/// Primary key: cityCode (IATA), value: CityIndexEntry
final class CityIndex {
    private let byCityCode: [String: CityIndexEntry]

    init(entries: [CityIndexEntry]) {
        var dict: [String: CityIndexEntry] = [:]
        dict.reserveCapacity(entries.count)
        for e in entries {
            dict[e.cityCode.uppercased()] = e
        }
        self.byCityCode = dict
    }

    /// Convenience initializer that loads from bundle.
    convenience init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "CityCodes_full", withExtension: "plist") else {
            assertionFailure("CityCodes_full.plist not found in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let entries = try PropertyListDecoder().decode([CityIndexEntry].self, from: data)
            self.init(entries: entries)
        } catch {
            assertionFailure("Failed to decode CityCodes_full.plist: \(error)")
            return nil
        }
    }

    /// Returns the metro city entry for an IATA city code.
    func entry(forCityCode cityCode: String) -> CityIndexEntry? {
        byCityCode[cityCode.uppercased()]
    }
}

// MARK: - Airport lookup

/// Loads and serves airport records by code, and resolves metro city using CityCodes_full.plist.
final class AirportLookup {
    private let byCode: [String: AirportLite]
    private let cityIndex: CityIndex?

    init(bundle: Bundle = .main) {
        self.byCode = AirportLookup.loadAirports(from: bundle)
        self.cityIndex = CityIndex(bundle: bundle) // nil if file missing/decoding fails
    }

    /// Human-friendly string like "BRU — Brussels, Belgium"
    /// Uses CityCodes_full.plist to map IATA cityCode → metro city name.
    func displayName(for code: String, locale: Locale = .autoupdatingCurrent) -> String {
        let u = code.uppercased()
        guard let a = byCode[u] else { return u }

        // Prefer metro city from CityIndex (e.g., BRU → Brussels)
        let metro = cityIndex?.entry(forCityCode: a.cityCode)?.city

        // Prefer country from the city entry if present (usually same as airport)
        let countryCode = cityIndex?.entry(forCityCode: a.cityCode)?.countryCode ?? a.country
        let country = CountryNamer.shared.name(for: countryCode, locale: locale)

        let place = metro?.isEmpty == false ? metro! : (a.city.isEmpty ? a.name : a.city)
        return "\(u) — \(place), \(country)"
    }

    /// Returns the metro city name (from CityCodes_full.plist) for an airport code, if available.
    func metroCity(for code: String) -> String? {
        guard let a = byCode[code.uppercased()] else { return nil }
        return cityIndex?.entry(forCityCode: a.cityCode)?.city
    }

    /// Returns the localized country name for the airport code, preferring the city index country.
    func countryName(for code: String, locale: Locale = .autoupdatingCurrent) -> String? {
        let u = code.uppercased()
        guard let a = byCode[u] else { return nil }
        let countryCode = cityIndex?.entry(forCityCode: a.cityCode)?.countryCode ?? a.country
        return CountryNamer.shared.name(for: countryCode, locale: locale)
    }

    /// Direct access to the underlying airport record.
    func airport(for code: String) -> AirportLite? {
        byCode[code.uppercased()]
    }

    // MARK: - Loading

    private static func loadAirports(from bundle: Bundle) -> [String: AirportLite] {
        guard let url = bundle.url(forResource: "airports_compact", withExtension: "plist") else {
            assertionFailure("airports_compact.plist not found in bundle")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            // The plist file is a dictionary: [code: AirportLite]
            let decoded = try PropertyListDecoder().decode([String: AirportLite].self, from: data)
            // Normalize keys to uppercased for consistent lookup
            var norm: [String: AirportLite] = [:]
            norm.reserveCapacity(decoded.count)
            for (k, v) in decoded {
                norm[k.uppercased()] = v
            }
            return norm
        } catch {
            assertionFailure("Failed to decode airports_compact.plist: \(error)")
            return [:]
        }
    }
}
