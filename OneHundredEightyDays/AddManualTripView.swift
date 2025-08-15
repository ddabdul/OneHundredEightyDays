//
//  AddManualTripView.swift
//  OneHundredEightyDays
//

import SwiftUI
import CoreData

struct AddManualTripView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize

    private static let lookup = AirportLookup()

    @State private var passenger = ""
    @State private var airline = ""
    @State private var flightNumber = ""
    @State private var originCode = ""
    @State private var destCode = ""
    @State private var travelDate: Date = .now
    @State private var errorMessage: String?

    @State private var showDateSheet = false

    enum Field { case passenger, airline, flight, origin, dest }
    @FocusState private var focus: Field?

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
                    HidingAssistantTextField(
                        text: $passenger,
                        placeholder: "Passenger name",
                        contentType: .name,
                        capitalization: .words,
                        keyboard: .default,
                        returnKey: .next,
                        onReturn: { focus = .airline }
                    )
                    .frame(maxWidth: .infinity)
                    .focused($focus, equals: .passenger)
                }

                Section("Flight") {
                    HidingAssistantTextField(
                        text: $airline,
                        placeholder: "Airline code (e.g. SN)",
                        contentType: .flightNumber,
                        capitalization: .allCharacters,
                        keyboard: .asciiCapable,
                        returnKey: .next,
                        onReturn: { focus = .flight }
                    )
                    .frame(maxWidth: .infinity)
                    .focused($focus, equals: .airline)

                    HidingAssistantTextField(
                        text: $flightNumber,
                        placeholder: "Flight number (e.g. 1234)",
                        contentType: .flightNumber,
                        capitalization: .allCharacters,
                        keyboard: .asciiCapableNumberPad,
                        returnKey: .next,
                        onReturn: { focus = .origin }
                    )
                    .frame(maxWidth: .infinity)
                    .focused($focus, equals: .flight)
                }

                Section("Route") {
                    HidingAssistantTextField(
                        text: $originCode,
                        placeholder: "Origin IATA (e.g. BRU)",
                        contentType: .location,
                        capitalization: .allCharacters,
                        keyboard: .asciiCapable,
                        returnKey: .next,
                        onReturn: { focus = .dest }
                    )
                    .frame(maxWidth: .infinity)
                    .focused($focus, equals: .origin)

                    hint(for: originCode)

                    HidingAssistantTextField(
                        text: $destCode,
                        placeholder: "Destination IATA (e.g. LHR)",
                        contentType: .location,
                        capitalization: .allCharacters,
                        keyboard: .asciiCapable,
                        returnKey: .done,
                        onReturn: { focus = nil }
                    )
                    .frame(maxWidth: .infinity)
                    .focused($focus, equals: .dest)

                    hint(for: destCode)

                    // Date trigger row – no inline folding
                    Button {
                        focus = nil
                        DispatchQueue.main.async { showDateSheet = true }
                    } label: {
                        HStack {
                            Text("Travel date")
                            Spacer()
                            Text(travelDate.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Travel date")
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        focus = nil
                        DispatchQueue.main.async { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showDateSheet) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        DatePicker("Select date", selection: $travelDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()

                        Spacer()

                        HStack {
                            Button("Cancel") { showDateSheet = false }
                            Spacer()
                            Button("Done") { showDateSheet = false }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .navigationTitle("Travel date")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents(hSize == .regular ? [.medium] : [.fraction(0.6), .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func hint(for code: String) -> some View {
        let u = code.trimmed.uppercased()
        if u.count >= 3 {
            Text(Self.lookup.displayName(for: u)) // “BRU — Brussels, Country”
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        errorMessage = nil
        focus = nil
        DispatchQueue.main.async {
            do {
                _ = try TripStore.saveTrip(
                    airline: airline.trimmed.uppercased(),
                    originCode: originCode.trimmed.uppercased(),
                    destCode: destCode.trimmed.uppercased(),
                    flightNumber: flightNumber.trimmed.uppercased(),
                    julianDate: julianDay(of: travelDate),
                    passenger: passenger.trimmed,
                    imageData: DefaultAssets.manualTripIconData,
                    in: viewContext
                ) // builds naturalKey, resolves airport/country, handles duplicates:contentReference[oaicite:2]{index=2}:contentReference[oaicite:3]{index=3}
                dismiss()
            } catch {
                errorMessage = "Failed to save trip: \(error.localizedDescription)"
            }
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
