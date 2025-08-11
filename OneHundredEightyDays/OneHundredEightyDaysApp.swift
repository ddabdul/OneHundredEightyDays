//
//  OneHundredEightyDaysApp.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import SwiftUI

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
    var body: some View {
        NavigationStack {
            PhotoQRCodeReader()
                .navigationTitle("Import Boarding Pass")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showTrips = true
                        } label: {
                            Label("Trips", systemImage: "airplane")
                        }
                    }
                }
                .sheet(isPresented: $showTrips) {
                    NavigationStack {
                        TripBrowserView()
                            .navigationTitle("Saved Trips")
                    }
                }
        }
    }
}

