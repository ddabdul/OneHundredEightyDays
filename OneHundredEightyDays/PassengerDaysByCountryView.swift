//
//  PassengerDaysByCountryView.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import SwiftUI
import CoreData

struct PassengerDaysByCountryView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \TripEntity.travelDate, ascending: true)],
        animation: .default
    )
    private var allTrips: FetchedResults<TripEntity>

    @State private var rules: [String: CountryRule] = [:]
    @State private var engine: ResidencyEngine?

    // Optional selections + nil placeholder tags prevent invalid Picker selection warnings
    @State private var selectedPassenger: String? = nil        // required
    @State private var selectedCountryISO: String? = nil       // required (start/anchor country)
    @State private var sinceDate: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var untilDate: Date = Date()

    @State private var totals: [CountryCount] = []             // totals per country
    @State private var segments: [FlightStayRow] = []          // stay length after each flight
    @State private var loading = false
    @State private var error: String?
    @State private var hasCalculated = false

    var body: some View {
        List {
            // Passenger
            Section("Passenger") {
                Picker("Name", selection: $selectedPassenger) {
                    Text("Select passenger").tag(String?.none)
                    ForEach(distinctPassengers, id: \.self) { name in
                        Text(name).tag(String?(name))
                    }
                }
                .pickerStyle(.menu)
            }

            // Country selection (anchor country)
            Section("Country selection") {
                Picker("Start counting from", selection: $selectedCountryISO) {
                    Text("Select country").tag(String?.none)
                    ForEach(countryChoices, id: \.iso) { c in
                        Text("\(c.name) (\(c.iso))").tag(String?(c.iso))
                    }
                }
                .pickerStyle(.menu)
            }

            // Dates + action
            Section("Date range") {
                DatePicker("From", selection: $sinceDate, displayedComponents: .date)
                DatePicker("To", selection: $untilDate, displayedComponents: .date)

                Button {
                    Task { await recompute() }  // <-- the only place where calculation happens
                } label: {
                    Label("Recalculate", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!inputsAreValid || loading)
            }

            // Totals by country
            Section(header: headerTotals) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let err = error {
                    Text(err).foregroundStyle(.red)
                } else if !hasCalculated {
                    Text("Pick a passenger and a country, set dates, then tap Recalculate.")
                        .foregroundStyle(.secondary)
                } else if totals.isEmpty {
                    Text("No days found in the selected range.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(totals) { row in
                        HStack {
                            Text("\(row.countryName) (\(row.iso))")
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text("\(row.days)")
                                .font(.title3.monospacedDigit())
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
            }

            // Between flights timeline
            if hasCalculated {
                Section("Between flights") {
                    if segments.isEmpty {
                        Text("No flights in the selected range.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(segments) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Flight \(s.route) / \(s.dateString)")
                                    .font(.body.weight(.semibold))
                                Text("\(s.days) day\(s.days == 1 ? "" : "s") in \(s.countryName)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Days by Country")
        .task {
            // Load rules/engine only (no automatic computation)
            do {
                if rules.isEmpty { rules = try RulesLoader.loadRules() }
                if engine == nil { engine = try ResidencyEngine(rules: rules) }
            } catch let e {                     // <- rename the caught error
                self.error = "Failed to initialize rules/engine: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - UI helpers

    private var inputsAreValid: Bool {
        selectedPassenger != nil &&
        selectedCountryISO != nil &&
        startOfDay(sinceDate) <= startOfDay(untilDate)
    }

    private var headerTotals: some View {
        HStack {
            Text("Country")
            Spacer()
            Text("Days").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Derived data

    private var distinctPassengers: [String] {
        let names = allTrips
            .compactMap { $0.passenger?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    /// Countries from rules (preferred) or ISO codes observed in data (fallback).
    private var countryChoices: [(iso: String, name: String)] {
        if !rules.isEmpty {
            return rules
                .filter { $0.key != "Default" }
                .map { ($0.key, $0.value.country_name) }
                .sorted { (l, r) in (l.1, l.0) < (r.1, r.0) }
        } else {
            let isoSet = Set(allTrips.compactMap {
                let dep = ($0.value(forKey: "departureCountry") as? String)?.uppercased() ?? ""
                let arr = ($0.value(forKey: "arrivalCountry") as? String)?.uppercased() ?? ""
                return [dep, arr].filter { $0.count == 2 }
            }.flatMap { $0 })
            return isoSet.sorted().map { ($0, $0) }
        }
    }

    // MARK: - Compute

    private func recompute() async {
        guard inputsAreValid else { return }
        error = nil
        totals = []
        segments = []
        hasCalculated = true
        loading = true
        defer { loading = false }

        do {
            if engine == nil {
                if rules.isEmpty { rules = try RulesLoader.loadRules() }
                engine = try ResidencyEngine(rules: rules)
            }
            guard let engine, let pax = selectedPassenger, let startISO = selectedCountryISO else { return }

            // Fetch this passenger’s trips within the selected range (for counting + labeling)
            let request: NSFetchRequest<TripEntity> = TripEntity.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "passenger ==[c] %@", pax),
                NSPredicate(format: "travelDate >= %@", startOfDay(sinceDate) as NSDate),
                NSPredicate(format: "travelDate <= %@", startOfDay(untilDate) as NSDate)
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "travelDate", ascending: true)]
            let paxTrips = try context.fetch(request)

            // Convert to SimpleTrip for engine
            let simple: [SimpleTrip] = paxTrips.compactMap { t in
                guard let d = t.travelDate else { return nil }
                let depISO = (t.value(forKey: "departureCountry") as? String)?.uppercased() ?? ""
                let arrISO = (t.value(forKey: "arrivalCountry") as? String)?.uppercased() ?? ""
                guard depISO.count == 2 || arrISO.count == 2 else { return nil }
                return SimpleTrip(date: d, departureISO: depISO, arrivalISO: arrISO, passenger: pax)
            }.sorted(by: { $0.date < $1.date })

            // Build presence days via engine (anchored by selected country)
            let presence = engine.presenceDaysByCountry(
                trips: simple,
                initialCountry: startISO,
                since: startOfDay(sinceDate),
                until: startOfDay(untilDate)
            )

            // Totals table
            totals = presence.map { (iso, dates) in
                let name = rules[iso]?.country_name ?? iso
                return CountryCount(iso: iso, countryName: name, days: dates.count)
            }
            .sorted { a, b in
                if a.days != b.days { return a.days > b.days }
                return a.iso < b.iso
            }

            // Segments (between flights) with real IATA codes
            segments = buildFlightStays(from: paxTrips, presence: presence)

        } catch {
            self.error = "Failed to compute: \(error.localizedDescription)"
        }
    }

    /// Create rows like “Flight HAM-MRS / 2025-02-10 — 53 days in France”
    private func buildFlightStays(from trips: [TripEntity],
                                  presence: [String: Set<Date>]) -> [FlightStayRow] {
        guard !trips.isEmpty else { return [] }

        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"

        let sorted = trips.sorted { ($0.travelDate ?? .distantFuture) < ($1.travelDate ?? .distantFuture) }
        var out: [FlightStayRow] = []

        for (idx, t) in sorted.enumerated() {
            guard let flightDate = t.travelDate else { continue }

            // Window: arrival date ... day before next flight (or untilDate)
            let windowStart = startOfDay(flightDate)
            let windowEnd: Date = {
                if idx + 1 < sorted.count, let nextD = sorted[idx + 1].travelDate {
                    return Calendar.utc.date(byAdding: .day, value: -1, to: startOfDay(nextD))!
                } else {
                    return startOfDay(untilDate)
                }
            }()
            if windowEnd < windowStart { continue }

            // Arrival country for this segment
            let arrISO = (t.arrivalCountry ?? (t.value(forKey: "arrivalCountry") as? String) ?? "").uppercased()
            let countryName = rules[arrISO]?.country_name ?? arrISO

            // Count presence in that country within the window
            let daysHere = presence[arrISO]?.lazy.filter { $0 >= windowStart && $0 <= windowEnd }.count ?? 0

            // Route label from stored IATA codes (fallback to ISO if missing)
            let depCode = (t.departureAirportCode ?? t.departureCountry ?? "").uppercased()
            let arrCode = (t.arrivalAirportCode ?? t.arrivalCountry ?? "").uppercased()

            out.append(
                FlightStayRow(
                    route: "\(depCode)-\(arrCode)",
                    dateString: df.string(from: flightDate),
                    countryISO: arrISO,
                    countryName: countryName,
                    days: daysHere
                )
            )
        }

        return out
    }
}

// MARK: - View models

private struct CountryCount: Identifiable, Hashable {
    var id: String { iso }
    let iso: String
    let countryName: String
    let days: Int
}

private struct FlightStayRow: Identifiable, Hashable {
    let id = UUID()
    let route: String
    let dateString: String
    let countryISO: String
    let countryName: String
    let days: Int
}

// MARK: - Date helpers

private func startOfDay(_ date: Date) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal.startOfDay(for: date)
}

private extension Calendar {
    static var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
}
