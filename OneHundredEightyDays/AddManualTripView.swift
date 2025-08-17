//
//  AddManualTripView.swift
//  OneHundredEightyDays
//

import SwiftUI
import CoreData

struct AddManualTripView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    private static let lookup = AirportLookup()

    @State private var passenger = ""
    @State private var airline = ""
    @State private var flightNumber = ""
    @State private var originCode = ""
    @State private var destCode = ""
    @State private var travelDate: Date = .now
    @State private var errorMessage: String?
    @State private var isSaving = false

    enum Field { case passenger, airline, flight, origin, dest }
    @FocusState private var focus: Field?

    private var canSave: Bool {
        !isSaving &&
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
                        .textInputAutocapitalization(.words)
                        .submitLabel(.next)
                        .focused($focus, equals: .passenger)
                        .onSubmit { focus = .airline }
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
                    hint(for: destCode)

                    DatePicker("Travel date", selection: $travelDate, displayedComponents: .date)
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
                    Button {
                        Task { await saveAsync() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onDisappear {
            // Avoid forcing endEditing from here; the delayed dismiss handles teardown cleanly.
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

    // MARK: - Save (async)

    @MainActor
    private func saveAsync() async {
        errorMessage = nil
        focus = nil
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await TripStore.saveTripAsync(
                airline: airline.trimmed.uppercased(),
                originCode: originCode.trimmed.uppercased(),
                destCode: destCode.trimmed.uppercased(),
                flightNumber: flightNumber.trimmed.uppercased(),
                julianDate: julianDay(of: travelDate),
                passenger: passenger.trimmed,
                imageData: DefaultAssets.manualTripIconData,
                in: viewContext
            )
            dismiss()
        } catch {
            errorMessage = "Failed to save trip: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func julianDay(of date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        return cal.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
