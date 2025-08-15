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

    var body: some View {
        NavigationStack {
            // Wrap root content so the toast can appear above it
            GlobalToastOverlay {
                PhotoQRCodeReader()
            }
            .navigationTitle("Import Boarding Pass")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showTrips = true
                    } label: {
                        Label("Trips", systemImage: "airplane")
                    }
                    Button {
                        showDaysByCountry = true
                    } label: {
                        Label("Days by Country", systemImage: "calendar.badge.clock")
                    }
                }
            }
            // Trips sheet
            .sheet(isPresented: $showTrips) {
                NavigationStack {
                    GlobalToastOverlay {
                        TripBrowserView()
                            .navigationTitle("Saved Trips")
                    }
                }
            }
            // Days-by-country sheet
            .sheet(isPresented: $showDaysByCountry) {
                NavigationStack {
                    PassengerDaysByCountryView()
                        .navigationTitle("Days by Country")
                }
            }
        }
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
