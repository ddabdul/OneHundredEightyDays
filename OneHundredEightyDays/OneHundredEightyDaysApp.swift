//
//  OneHundredEightyDaysApp.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import SwiftUI
import UIKit

@main
struct OneHundredEightyDaysApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(\.managedObjectContext,
                             persistenceController.container.viewContext)
        }
    }
}

struct HomeView: View {
    @State private var showTrips = false
    @State private var showDaysByCountry = false
    @State private var showAddManualTrip = false

    var body: some View {
        NavigationStack {
            // Wrap the root reader in both overlays:
            PassengerDuplicatePromptOverlay {
                GlobalToastOverlay {
                    PhotoQRCodeReader()
                }
            }
            .navigationTitle("Import Boarding Pass")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIApplication.shared.endEditing()
                        showTrips = true
                    } label: {
                        Label("Trips", systemImage: "airplane")
                    }
                    Button {
                        UIApplication.shared.endEditing()
                        showDaysByCountry = true
                    } label: {
                        Label("Days by Country", systemImage: "calendar.badge.clock")
                    }
                    Button {
                        UIApplication.shared.endEditing()
                        showAddManualTrip = true
                    } label: {
                        Label("Add Trip", systemImage: "plus")
                    }
                    .accessibilityLabel("Add Trip Manually")
                }
            }
            // Trips sheet
            .sheet(isPresented: $showTrips) {
                NavigationStack {
                    // Wrap the sheet screen too (so alerts appear over it)
                    PassengerDuplicatePromptOverlay {
                        GlobalToastOverlay {
                            TripBrowserView()
                                .navigationTitle("Saved Trips")
                        }
                    }
                }
            }
            // Days-by-country sheet
            .sheet(isPresented: $showDaysByCountry) {
                NavigationStack {
                    // This screen doesn't save trips, so overlay not strictly needed,
                    // but harmless to leave out.
                    PassengerDuplicatePromptOverlay {
                        PassengerDaysByCountryView()
                            .navigationTitle("Days by Country")
                    }
                }
            }
            // Manual add sheet
            .sheet(isPresented: $showAddManualTrip) {
                NavigationStack {
                    PassengerDuplicatePromptOverlay {
                        GlobalToastOverlay {
                            AddManualTripView()
                                .navigationTitle("Add Trip")
                        }
                    }
                }
            }
        }
        // Helps in edge cases where UIKit wants extra room while animating the keyboard
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}


// MARK: - Global Toast Overlay

/// A lightweight wrapper that listens for `.tripDuplicateDetected` and overlays a banner.
/// Use it around any screen (including sheets) to show the warning anywhere.
private struct GlobalToastOverlay<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var duplicateMessage: String?
    @State private var isShowingToast = false

    var body: some View {
        content
            .overlay(alignment: .top) {
                if isShowingToast, let msg = duplicateMessage {
                    ToastBanner(text: "Trip already exists.\n\(msg)")
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                        .zIndex(1)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tripDuplicateDetected)) { note in
                let msg = (note.userInfo?["message"] as? String)
                    ?? "This trip is already in your library."
                duplicateMessage = msg
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isShowingToast = true
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred() // optional haptic
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeInOut(duration: 0.25)) { isShowingToast = false }
                }
            }
    }
}


// MARK: - Passenger Duplicate Prompt Overlay

/// Listens for `.passengerDuplicatePrompt` and presents an Alert with two actions:
/// - "Use Existing": posts `.passengerDuplicateAnswered` with `choice = "useExisting"`
/// - "Create New":   posts `.passengerDuplicateAnswered` with `choice = "createNew"`
///
/// This mirrors the notification-driven pattern used by GlobalToastOverlay, but requires
/// an interactive choice, so it uses a SwiftUI alert instead of a passive banner.
private struct PassengerDuplicatePromptOverlay<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var activePrompt: Prompt?

    struct Prompt: Identifiable {
        let id: UUID
        let message: String
    }

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .passengerDuplicatePrompt)) { note in
                let id = note.userInfo?["promptID"] as? UUID
                let msg = note.userInfo?["message"] as? String
                if let id, let msg {
                    activePrompt = Prompt(id: id, message: msg)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .alert("Passenger Already Exists",
                   isPresented: Binding(get: { activePrompt != nil },
                                       set: { if !$0 { activePrompt = nil } })) {
                Button("Use Existing") {
                    if let id = activePrompt?.id {
                        NotificationCenter.default.post(
                            name: .passengerDuplicateAnswered,
                            object: nil,
                            userInfo: ["promptID": id, "choice": "useExisting"]
                        )
                    }
                    activePrompt = nil
                }
                Button("Create New", role: .destructive) {
                    if let id = activePrompt?.id {
                        NotificationCenter.default.post(
                            name: .passengerDuplicateAnswered,
                            object: nil,
                            userInfo: ["promptID": id, "choice": "createNew"]
                        )
                    }
                    activePrompt = nil
                }
                Button("Cancel", role: .cancel) {
                    // Treat cancel as "Create New" to keep flow moving; adjust if you prefer silent-cancel.
                    if let id = activePrompt?.id {
                        NotificationCenter.default.post(
                            name: .passengerDuplicateAnswered,
                            object: nil,
                            userInfo: ["promptID": id, "choice": "createNew"]
                        )
                    }
                    activePrompt = nil
                }
            } message: {
                Text(activePrompt?.message ?? "")
            }
    }
}


// MARK: - Toast UI

/// Simple reusable banner with a warning icon.
private struct ToastBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.large)
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 8, y: 4)
        .padding(.horizontal, 12)
    }
}
