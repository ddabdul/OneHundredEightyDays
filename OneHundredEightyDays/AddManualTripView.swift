//
//  AddManualTripView.swift
//  OneHundredEightyDays
//

import SwiftUI
import CoreData

struct AddManualTripView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    private static let lookup = AirportLookup() // for hints

    @State private var passenger: String = ""
    @State private var airline: String = ""
    @State private var flightNumber: String = ""
    @State private var originCode: String = ""
    @State private var destCode: String = ""
    @State private var travelDate: Date = .now

    @State private var errorMessage: String?

    private var canSave: Bool {
        !airline.trimmed.isEmpty &&
        !flightNumber.trimmed.isEmpty &&
        originCode.trimmed.count >= 3 &&
        destCode.trimmed.count >= 3 &&
        !passenger.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Traveler") {
                    TextField("Passenger name", text: $passenger)
                        .textContentType(.name)
                        .autocapitalization(.words)
                }

                Section("Flight") {
                    TextField("Airline code (e.g. SN)", text: $airline)
                        .textInputAutocapitalization(.characters)
                    TextField("Flight number (e.g. 1234)", text: $flightNumber)
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.asciiCapableNumberPad)
                }

                Section("Route") {
                    TextField("Origin IATA (e.g. BRU)", text: $originCode)
                        .textInputAutocapitalization(.characters)
                    hint(for: originCode)

                    TextField("Destination IATA (e.g. LHR)", text: $destCode)
                        .textInputAutocapitalization(.characters)
                    hint(for: destCode)

                    DatePicker("Travel date", selection: $travelDate, displayedComponents: .date)
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Add Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private func hint(for code: String) -> some View {
        let u = code.trimmed.uppercased()
        if u.count >= 3 {
            Text(Self.lookup.displayName(for: u))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        errorMessage = nil

        // Use the **bundled** icon for manual trips
        let iconData = DefaultAssets.manualTripIconData

        do {
            _ = try TripStore.saveTrip(
                airline: airline.trimmed.uppercased(),
                originCode: originCode.trimmed.uppercased(),
                destCode: destCode.trimmed.uppercased(),
                flightNumber: flightNumber.trimmed.uppercased(),
                julianDate: julianDay(of: travelDate),
                passenger: passenger.trimmed,
                imageData: iconData,
                in: viewContext
            )
            dismiss()
        } catch {
            errorMessage = "Failed to save trip: \(error.localizedDescription)"
        }
    }

    private func julianDay(of date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        return cal.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
