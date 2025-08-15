//
//  PassengerDaysByCountryView.swift
//  OneHundredEightyDays
//
//  Shows how many days a passenger spent by country in a selected range,
//  powered by ResidencyEngine.
//

import SwiftUI
import CoreData

struct PassengerDaysByCountryView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \TripEntity.travelDate, ascending: true)],
        animation: .default
    ) private var allTrips: FetchedResults<TripEntity>

    @State private var rules: [String: CountryRule] = [:]
    @State private var engine: ResidencyEngine?

    // NOTE: Optional selections + nil placeholder tags stop the “invalid selection” warnings
    @State private var selectedPassenger: String? = nil      // required
    @State private var selectedCountryISO: String? = nil     // required (this is the starting country for counting)
    @State private var sinceDate: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var untilDate: Date = Date()

    @State private var rows: [CountryCount] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hasCalculated = false

    var body: some View {
        List {
            Section("Passenger") {
                Picker("Name", selection: $selectedPassenger) {
                    Text("Select passenger").tag(String?.none) // placeholder (nil)
                    ForEach(distinctPassengers, id: \.self) { name in
                        Text(name).tag(String?(name))
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Country selection") {
                Picker("Start counting from", selection: $selectedCountryISO) {
                    Text("Select country").tag(String?.none) // placeholder (nil)
                    ForEach(countryChoices, id: \.iso) { c in
                        Text("\(c.name) (\(c.iso))").tag(String?(c.iso))
                    }
                }
                .pickerStyle(.menu)
                // Don’t disable: we can always show choices, even if rules aren’t loaded (we fall back to ISO codes from trips)
            }

            Section("Date range") {
                DatePicker("From", selection: $sinceDate, displayedComponents: .date)
                DatePicker("To", selection: $untilDate, displayedComponents: .date)

                Button {
                    Task { await recompute() }   // <- only time we calculate
                } label: {
                    Label("Recalculate", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!inputsAreValid || loading)
            }

            Section(header: headerView) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let err = error {
                    Text(err).foregroundStyle(.red)
                } else if !hasCalculated {
                    Text("Pick a passenger and a country, set dates, then tap Recalculate.")
                        .foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    Text("No days found in the selected range.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
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
        }
        .navigationTitle("Days by Country")
        .task {
            // Load rules/engine only; DO NOT compute here
            do {
                if rules.isEmpty { rules = try RulesLoader.loadRules() }
                if engine == nil { engine = try ResidencyEngine(rules: rules) }
            } catch {
                self.error = "Failed to initialize rules/engine: \(error.localizedDescription)"
            }
        }
    }

    // Only allow calculation when all inputs are present and dates are sane
    private var inputsAreValid: Bool {
        selectedPassenger != nil &&
        selectedCountryISO != nil &&
        startOfDay(sinceDate) <= startOfDay(untilDate)
    }

    private var headerView: some View {
        HStack {
            Text("Country")
            Spacer()
            Text("Days").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Derived

    private var distinctPassengers: [String] {
        let names = allTrips.compactMap { $0.passenger?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    /// Build choices from rules if available, otherwise fall back to ISO codes present in your trips.
    private var countryChoices: [(iso: String, name: String)] {
        if !rules.isEmpty {
            return rules
                .filter { $0.key != "Default" }
                .map { ($0.key, $0.value.country_name) }
                .sorted { l, r in
                    if l.1 != r.1 { return l.1 < r.1 }
                    return l.0 < r.0
                }
        } else {
            // Fallback so the picker is still useful even before rules load
            let isoSet = Set(allTrips.compactMap {
                let dep = ( ($0.value(forKey: "departureCountry") as? String) ?? "" ).uppercased()
                let arr = ( ($0.value(forKey: "arrivalCountry") as? String) ?? "" ).uppercased()
                return [dep, arr].filter { $0.count == 2 }
            }.flatMap { $0 })
            return isoSet.sorted().map { ($0, $0) } // name = ISO until rules arrive
        }
    }

    // MARK: - Actions

    private func recompute() async {
        guard inputsAreValid else { return }
        error = nil
        rows = []
        hasCalculated = true
        loading = true
        defer { loading = false }

        do {
            // Ensure engine exists even if rules failed earlier
            if engine == nil {
                if rules.isEmpty { rules = try RulesLoader.loadRules() }
                engine = try ResidencyEngine(rules: rules)
            }
            guard let engine, let pax = selectedPassenger, let startISO = selectedCountryISO else { return }

            let provider = CoreDataTripProvider()
            let trips = try provider.fetchTrips(
                context: context,
                since: startOfDay(sinceDate),
                until: startOfDay(untilDate),
                passengers: [pax]
            )

            // Use the *selected* country as the starting country for counting
            let presence = engine.presenceDaysByCountry(
                trips: trips,
                initialCountry: startISO,
                since: startOfDay(sinceDate),
                until: startOfDay(untilDate)
            )

            rows = presence.map { (iso, dates) in
                let name = rules[iso]?.country_name ?? iso
                return CountryCount(iso: iso, countryName: name, days: dates.count)
            }
            .sorted { a, b in
                if a.days != b.days { return a.days > b.days }
                return a.iso < b.iso
            }
        } catch {
            self.error = "Failed to compute: \(error.localizedDescription)"
        }
    }
}

// MARK: - Row model

private struct CountryCount: Identifiable, Hashable {
    var id: String { iso }
    let iso: String
    let countryName: String
    let days: Int
}

// Normalize to UTC day buckets (matches engine)
private func startOfDay(_ date: Date) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal.startOfDay(for: date)
}
