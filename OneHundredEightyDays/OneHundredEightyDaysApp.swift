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
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
