// TripBrowserView.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

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
    @State private var fullScreenPhotoData: Data?        // << for the sheet

    var body: some View {
        VStack {
            if trips.isEmpty {
                ContentUnavailableView("No trips yet",
                                       systemImage: "airplane",
                                       description: Text("Import or scan a boarding pass to get started."))
            } else {
                TabView(selection: $selection) {
                    ForEach(Array(trips.enumerated()), id: \.element.objectID) { index, trip in
                        TripCard(trip: trip) { data in
                            fullScreenPhotoData = data
                        }
                        .padding(.horizontal)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))

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
        .fullScreenCover(item: Binding(
            get: {
                // Wrap in an Identifiable helper so we can use fullScreenCover(item:)
                fullScreenPhotoData.map { IdentData(id: UUID(), data: $0) }
            },
            set: { ident in
                fullScreenPhotoData = ident?.data
            })
        ) { ident in
            FullscreenImageView(data: ident.data)
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
        if selection >= max(trips.count - 1, 0) {
            selection = max(trips.count - 1, 0)
        }
    }
}

// MARK: - Card

private struct TripCard: View {
    let trip: TripEntity
    var onPhotoTap: (Data) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Photo (tappable → fullscreen)
            if let data = trip.imageData,
               let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 200)
                    .clipped()
                    .cornerRadius(12)
                    .contentShape(Rectangle())
                    .onTapGesture { onPhotoTap(data) }
            }

            // Top row: airline + flight number
            HStack {
                Label(trip.airline ?? "—", systemImage: "airplane")
                    .font(.headline)
                Spacer()
                Text(trip.flightNumber ?? "—")
                    .font(.headline)
            }

            // Passenger
            if let p = trip.passenger, !p.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person")
                    Text(p)
                }
                .accessibilityLabel("Passenger \(trip.passenger ?? "")")
            }

            // Route (stored as “CODE — City, Country” already)
            if let from = trip.departureCity {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.departure")
                    Text(from)
                        .font(.title3.weight(.semibold))
                }
            }
            if let to = trip.arrivalCity {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.arrival")
                    Text(to)
                        .font(.title3.weight(.semibold))
                }
            }

            // Date
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(formattedDate(trip.travelDate))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
        }
        .font(.body)
    }
}

// MARK: - Fullscreen photo

private struct FullscreenImageView: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(MagnificationGesture()
                        .onChanged { value in
                            scale = max(1, lastScale * value)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                    )
                    .gesture(DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                    )
                    .background(Color.black.ignoresSafeArea())
                    .overlay(alignment: .topTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding()
                        }
                    }
            } else {
                // If the data somehow can't form an image, show a friendly fallback
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                    Text("Unable to display image")
                    Button("Close") { dismiss() }
                }
                .padding()
                .background(Color(.systemBackground))
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// Helper for fullScreenCover(item:)
private struct IdentData: Identifiable {
    let id: UUID
    let data: Data
}

// MARK: - Helpers

fileprivate func formattedDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .abbreviated, time: .omitted)
}
