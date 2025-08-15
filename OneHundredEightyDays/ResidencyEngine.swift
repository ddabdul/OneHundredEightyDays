//
//  ResidencyEngine.swift
//  OneHundredEightyDays
//
//  iOS 16+
//
//  What this file provides
//  - RulesLoader: loads country rules from 183_days_rules.plist
//  - CoreDataTripProvider: fetches trips from Core Data, with passenger filtering
//  - ResidencyEngine: builds per-day presence & computes 183-day results
//
//  Assumptions (TripEntity):
//    travelDate: Date?
//    passenger: String?
//    departureCountry: String?   // ISO 3166-1 alpha-2
//    arrivalCountry:   String?   // ISO 3166-1 alpha-2
//

import Foundation
import CoreData

// MARK: - Rules models

public enum WindowType: String, Codable {
    case CALENDAR_YEAR
    case TAX_YEAR
    case ROLLING_12_MONTHS
}

public struct CountryRule: Codable {
    public let country_name: String
    public let day_threshold: Int
    public let window_type: WindowType
    public let tax_year_start_month: Int
    public let tax_year_start_day: Int
    public let counts_arrival_departure: Bool
    public let counts_partial_days: Bool
    public let counts_weekends_holidays: Bool
    public let treaty_employment_183_rule: Bool
    public let notes: String?
}

// MARK: - Results models

public struct CountryWindowResult: Hashable {
    public let label: String
    public let start: Date
    public let end: Date
    public let countedDays: Int
    public let threshold: Int
    public var meets183: Bool { countedDays >= threshold }
}

public struct CountryResidencyResult {
    public let countryCode: String
    public let countryName: String
    public let rule: CountryRule
    public let windows: [CountryWindowResult]
    public var anyWindowMeets183: Bool { windows.contains(where: { $0.meets183 }) }
}

public struct ResidencySummary {
    public let generatedAt: Date
    public let results: [CountryResidencyResult]
}

public struct PassengerResidencySummary {
    public let passenger: String
    public let generatedAt: Date
    public let results: [CountryResidencyResult]
}

// MARK: - Rules loader

// MARK: - Rules loader (fixed: preserve "Default")
public enum RulesLoader {
    public static func loadRules(fromPlistNamed name: String = "183_days_rules") throws -> [String: CountryRule] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "plist") else {
            throw NSError(domain: "ResidencyEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Plist \(name).plist not found in bundle"])
        }
        let data = try Data(contentsOf: url)

        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "ResidencyEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid plist structure"])
        }

        var out: [String: CountryRule] = [:]
        let decoder = PropertyListDecoder()

        for (code, value) in root {
            guard let dict = value as? [String: Any] else { continue }
            let subdata = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            let rule = try decoder.decode(CountryRule.self, from: subdata)

            // Preserve the special "Default" key; uppercase ISO codes only.
            let key = (code == "Default") ? "Default" : code.uppercased()
            out[key] = rule
        }

        // Optional: sanity check to help debug if needed
        #if DEBUG
        if out["Default"] == nil {
            let known = out.keys.sorted().joined(separator: ", ")
            print("⚠️ RulesLoader: 'Default' missing. Keys: \(known)")
        }
        #endif

        return out
    }
}


// MARK: - Trip fetching (Core Data)

public struct SimpleTrip: Hashable {
    public let date: Date
    public let departureISO: String
    public let arrivalISO: String
    public let passenger: String
}

public protocol TripProviding {
    /// Fetch trips between dates (inclusive). If `passengers` is non-nil, filter trips to those passenger names (case-insensitive).
    func fetchTrips(
        context: NSManagedObjectContext,
        since: Date?,
        until: Date?,
        passengers: [String]?
    ) throws -> [SimpleTrip]
}

/// Reads TripEntity and filters by passenger(s)
public final class CoreDataTripProvider: TripProviding {
    public init() {}

    public func fetchTrips(
        context: NSManagedObjectContext,
        since: Date?,
        until: Date?,
        passengers: [String]? = nil
    ) throws -> [SimpleTrip] {

        let request: NSFetchRequest<TripEntity> = TripEntity.fetchRequest()
        var preds: [NSPredicate] = []

        if let s = since {
            preds.append(NSPredicate(format: "travelDate >= %@", s as NSDate))
        }
        if let u = until {
            preds.append(NSPredicate(format: "travelDate <= %@", u as NSDate))
        }

        // Passenger list: trim, drop empties, case-insensitive exact match
        if let raw = passengers, !raw.isEmpty {
            let paxList: [String] = raw.compactMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !paxList.isEmpty {
                preds.append(NSPredicate(format: "passenger IN[c] %@", paxList))
                // For fuzzy: OR of CONTAINS[cd]
                // let subs = paxList.map { NSPredicate(format: "passenger CONTAINS[cd] %@", $0) }
                // preds.append(NSCompoundPredicate(orPredicateWithSubpredicates: subs))
            }
        }

        if !preds.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "travelDate", ascending: true)]

        let items = try context.fetch(request)

        return items.compactMap { t in
            // ---- FIX: don't use `guard let` on non-optional trim result
            guard let d = t.travelDate else { return nil }
            let paxRaw = (t.passenger ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paxRaw.isEmpty else { return nil }
            let pax = paxRaw
            // ---- /FIX

            // If your generated NSManagedObject has these props, use t.departureCountry / t.arrivalCountry directly.
            let depISO = ((t.value(forKey: "departureCountry") as? String) ?? "").uppercased()
            let arrISO = ((t.value(forKey: "arrivalCountry") as? String) ?? "").uppercased()
            guard depISO.count == 2 || arrISO.count == 2 else { return nil }

            return SimpleTrip(date: d, departureISO: depISO, arrivalISO: arrISO, passenger: pax)
        }
    }
}

// MARK: - Residency Engine

public final class ResidencyEngine {
    private let rules: [String: CountryRule]
    private let defaultRule: CountryRule
    private var calendar: Calendar

    public init(rules: [String: CountryRule], timeZone: TimeZone? = TimeZone(secondsFromGMT: 0)) throws {
        self.rules = rules
        guard let def = rules["Default"] else {
            throw NSError(domain: "ResidencyEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Default rule missing in rules plist"])
        }
        self.defaultRule = def

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone ?? .current
        self.calendar = cal
    }

    // MARK: Public APIs

    /// Compute across a mixed set of trips (all passengers) grouped per passenger.
    /// - initialCountries: optional map Passenger -> initial ISO (where they are at start of analysis)
    public func computeByPassenger(
        trips: [SimpleTrip],
        initialCountries: [String: String]? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) -> [PassengerResidencySummary] {
        let grouped = Dictionary(grouping: trips, by: { $0.passenger })
        return grouped.keys.sorted().map { pax in
            let paxTrips = grouped[pax] ?? []
            let home = initialCountries?[pax]
            let summary = computeInternal(trips: paxTrips, initialCountry: home, since: since, until: until)
            return PassengerResidencySummary(passenger: pax, generatedAt: summary.generatedAt, results: summary.results)
        }
    }

    /// Compute for a single passenger (pass trips already filtered to that passenger).
    public func computeForPassenger(
        trips: [SimpleTrip],
        initialCountry: String?,
        since: Date? = nil,
        until: Date? = nil
    ) -> PassengerResidencySummary {
        let summary = computeInternal(trips: trips, initialCountry: initialCountry, since: since, until: until)
        let pax = trips.first?.passenger ?? "Unknown"
        return PassengerResidencySummary(passenger: pax, generatedAt: summary.generatedAt, results: summary.results)
    }

    /// Original compute (not grouped).
    public func compute(
        trips: [SimpleTrip],
        initialCountry: String?,
        since: Date? = nil,
        until: Date? = nil
    ) -> ResidencySummary {
        computeInternal(trips: trips, initialCountry: initialCountry, since: since, until: until)
    }

    // MARK: Core logic

    private func computeInternal(
        trips rawTrips: [SimpleTrip],
        initialCountry: String?,
        since: Date?,
        until: Date?
    ) -> ResidencySummary {

        guard !rawTrips.isEmpty else {
            return ResidencySummary(generatedAt: Date(), results: [])
        }

        let trips = rawTrips.sorted { $0.date < $1.date }

        // Determine analysis range; extend to stabilize rolling windows
        let firstDate = trips.first!.date
        let lastDate  = trips.last!.date
        let start = startOfDay(since ?? calendar.date(byAdding: .day, value: -400, to: firstDate)!)
        let end   = startOfDay(until ?? calendar.date(byAdding: .day, value:  400, to: lastDate)!)

        // Build presence sets: ISO -> Set<Date>
        let presence = buildPresenceSets(
            trips: trips,
            initialCountry: initialCountry?.uppercased(),
            startIncl: start,
            endIncl: end
        )

        // Compute per-country windows
        var results: [CountryResidencyResult] = []
        for (iso, days) in presence {
            let rule = rules[iso] ?? defaultRule
            let windows: [CountryWindowResult]
            switch rule.window_type {
            case .CALENDAR_YEAR:
                windows = calendarYearWindows(for: iso, days: days, rule: rule)
            case .TAX_YEAR:
                windows = taxYearWindows(for: iso, days: days, rule: rule)
            case .ROLLING_12_MONTHS:
                windows = rollingWindows(for: iso, days: days, rule: rule)
            }

            let name = rules[iso]?.country_name ?? iso
            results.append(CountryResidencyResult(countryCode: iso, countryName: name, rule: rule, windows: windows))
        }

        // Sort: those meeting threshold first, then alphabetically
        results.sort {
            if $0.anyWindowMeets183 != $1.anyWindowMeets183 {
                return $0.anyWindowMeets183 && !$1.anyWindowMeets183
            }
            return $0.countryCode < $1.countryCode
        }

        return ResidencySummary(generatedAt: Date(), results: results)
    }

    // MARK: Presence building

    /// ISO -> Set<Date> (midnight in engine's calendar) of presence days.
    /// Policy:
    /// - No travel day: credit the country at start of the day (carried from previous last arrival).
    /// - Travel day: if a country's rule counts arrival/departure AND partials, credit it when it appears on that date;
    ///               otherwise credit end-of-day country at minimum.
    private func buildPresenceSets(
        trips: [SimpleTrip],
        initialCountry: String?,
        startIncl: Date,
        endIncl: Date
    ) -> [String: Set<Date>] {

        var tripsByDate: [Date: [SimpleTrip]] = [:]
        for t in trips {
            tripsByDate[startOfDay(t.date), default: []].append(t)
        }
        for d in tripsByDate.keys {
            tripsByDate[d]?.sort { $0.date < $1.date }
        }

        var presence: [String: Set<Date>] = [:]
        var currentCountry = initialCountry

        if currentCountry == nil, let firstTrips = tripsByDate[startOfDay(trips.first!.date)]?.first {
            currentCountry = firstTrips.departureISO
        }

        var day = startIncl
        while day <= endIncl {
            let legs = tripsByDate[day] ?? []

            if legs.isEmpty {
                if let iso = currentCountry {
                    add(day: day, to: iso, in: &presence)
                }
            } else {
                var endOfDayISO = currentCountry
                for leg in legs {
                    let depRule = rule(for: leg.departureISO)
                    if depRule.counts_arrival_departure && depRule.counts_partial_days {
                        add(day: day, to: leg.departureISO, in: &presence)
                    }
                    let arrRule = rule(for: leg.arrivalISO)
                    if arrRule.counts_arrival_departure && arrRule.counts_partial_days {
                        add(day: day, to: leg.arrivalISO, in: &presence)
                    }
                    endOfDayISO = leg.arrivalISO
                }
                if let eiso = endOfDayISO {
                    let r = rule(for: eiso)
                    if !(r.counts_arrival_departure && r.counts_partial_days) {
                        add(day: day, to: eiso, in: &presence)
                    }
                }
                currentCountry = endOfDayISO
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return presence
    }

    private func add(day: Date, to iso: String, in dict: inout [String: Set<Date>]) {
        var set = dict[iso] ?? Set<Date>()
        set.insert(day)
        dict[iso] = set
    }

    private func rule(for iso: String) -> CountryRule {
        rules[iso] ?? defaultRule
    }

    private func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    // MARK: Windows

    private func calendarYearWindows(for iso: String, days: Set<Date>, rule: CountryRule) -> [CountryWindowResult] {
        guard !days.isEmpty else { return [] }
        let grouped = Dictionary(grouping: days) { (d: Date) -> Int in
            calendar.component(.year, from: d)
        }
        return grouped.keys.sorted().map { year in
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)!
            let count = grouped[year]?.count ?? 0
            return CountryWindowResult(label: "\(year)", start: start, end: end, countedDays: count, threshold: rule.day_threshold)
        }
    }

    private func taxYearWindows(for iso: String, days: Set<Date>, rule: CountryRule) -> [CountryWindowResult] {
        guard !days.isEmpty else { return [] }
        let minDate = days.min()!
        let maxDate = days.max()!
        let minYear = calendar.component(.year, from: minDate) - 1
        let maxYear = calendar.component(.year, from: maxDate) + 1

        var windows: [CountryWindowResult] = []
        for y in minYear...maxYear {
            guard
                let start = calendar.date(from: DateComponents(year: y,
                                                              month: rule.tax_year_start_month,
                                                              day: rule.tax_year_start_day)),
                let end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)
            else { continue }

            let startYear = calendar.component(.year, from: start)
            let endYear = calendar.component(.year, from: end)
            let label = startYear == endYear ? "\(startYear)" : "\(startYear)/\(endYear)"

            let count = days.lazy.filter { $0 >= start && $0 <= end }.count
            if count > 0 {
                windows.append(CountryWindowResult(label: label, start: start, end: end,
                                                   countedDays: count, threshold: rule.day_threshold))
            }
        }
        windows.sort { $0.start < $1.start }
        return windows
    }

    private func rollingWindows(for iso: String, days: Set<Date>, rule: CountryRule) -> [CountryWindowResult] {
        guard !days.isEmpty else { return [] }
        let sorted = days.sorted()

        var bestCount = 0
        var bestStart = sorted.first!
        var bestEnd = sorted.first!

        var i = 0
        var j = 0
        while i < sorted.count {
            while j < sorted.count {
                let span = calendar.dateComponents([.day], from: sorted[i], to: sorted[j]).day ?? 0
                if span <= 364 { j += 1 } else { break }
            }
            let count = j - i
            if count > bestCount {
                bestCount = count
                bestStart = sorted[i]
                bestEnd = calendar.date(byAdding: .day, value: 364, to: bestStart)!
                if bestEnd > (sorted.last ?? bestEnd) { bestEnd = sorted.last! }
            }
            i += 1
        }

        let result = CountryWindowResult(label: "Best rolling 12 months",
                                         start: bestStart, end: bestEnd,
                                         countedDays: bestCount,
                                         threshold: rule.day_threshold)
        return [result]
    }
    

    public func presenceDaysByCountry(
        trips: [SimpleTrip],
        initialCountry: String?,
        since: Date,
        until: Date
    ) -> [String: Set<Date>] {
        // Normalize to this engine's calendar
        let start = startOfDay(since)
        let end   = startOfDay(until)
        // Reuse the engine’s conservative counting logic
        return buildPresenceSets(
            trips: trips.sorted { $0.date < $1.date },
            initialCountry: initialCountry?.uppercased(),
            startIncl: start,
            endIncl: end
        )
    }

}

// MARK: - Example usage
/*
 // 1) Load rules
 let rules = try RulesLoader.loadRules()

 // 2) Create engine
 let engine = try ResidencyEngine(rules: rules)

 // 3) Fetch trips for selected passengers
 let provider = CoreDataTripProvider()
 let trips = try provider.fetchTrips(context: context,
                                     since: nil,
                                     until: nil,
                                     passengers: ["John Smith", "Jane Doe"])

 // 4a) Per passenger
 let grouped = engine.computeByPassenger(trips: trips,
                                         initialCountries: ["John Smith": "FR", "Jane Doe": "DE"])

 // 4b) Single passenger
 let johnOnly = try provider.fetchTrips(context: context, since: nil, until: nil, passengers: ["John Smith"])
 let johnSummary = engine.computeForPassenger(trips: johnOnly, initialCountry: "FR")

 // 5) Inspect
 for s in grouped {
     print("Passenger:", s.passenger)
     for r in s.results {
         print("  \(r.countryCode) \(r.anyWindowMeets183 ? "✅" : "—")")
         for w in r.windows {
             print("    \(w.label): \(w.countedDays)/\(w.threshold)")
         }
     }
 }
*/
