//
//  TripBrowserView.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 11/08/2025.
//


// TripBrowserView.swift

import SwiftUI
import CoreData
import UIKit

struct TripBrowserView: View {
    @Environment(\.managedObjectContext) private var ctx

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \TripEntity.travelDate, ascending: false),
            NSSortDescriptor(keyPath: \TripEntity.flightNumber, ascending: true)
        ],
        animation: .default
    )
    private var trips: FetchedResults<TripEntity>

    @State private var selection: Int = 0
    @State private var confirmDelete = false

    var body: some View {
        VStack {
            if trips.isEmpty {
                ContentUnavailableView("No trips yet",
                                       systemImage: "airplane",
                                       description: Text("Import or scan a boarding pass to get started."))
            } else {
                TabView(selection: $selection) {
                    ForEach(Array(trips.enumerated()), id: \.element.objectID) { index, trip in
                        TripCard(trip: trip)
                            .padding(.horizontal)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))

                // simple page indicator text (optional)
                Text("\(selection + 1) / \(trips.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .toolbar {
            if !trips.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Trip", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Delete this trip?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrentTrip() }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let t = currentTrip {
                Text("\(t.airline ?? "") \(t.flightNumber ?? "") on \(formattedDate(t.travelDate))")
            }
        }
    }

    private var currentTrip: TripEntity? {
        guard !trips.isEmpty, trips.indices.contains(selection) else { return nil }
        return trips[selection]
    }

    private func deleteCurrentTrip() {
        guard let t = currentTrip else { return }
        ctx.delete(t)
        do { try ctx.save() } catch { print("Delete failed:", error) }
        // Adjust selection if we deleted the last page
        if selection >= max(trips.count - 1, 0) {
            selection = max(trips.count - 1, 0)
        }
    }
}

private struct TripCard: View {
    let trip: TripEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Photo (if you saved imageData)
            if let data = trip.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .clipped()
                    .cornerRadius(10)
            }

            HStack {
                Text(trip.airline ?? "—")
                    .font(.headline)
                Spacer()
                Text(trip.flightNumber ?? "—")
                    .font(.headline)
            }

            Text("\(trip.departureCity ?? "—")  →  \(trip.arrivalCity ?? "—")")
                .font(.title3.weight(.semibold))

            Text(formattedDate(trip.travelDate))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Helpers

fileprivate func formattedDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .abbreviated, time: .omitted)
}
