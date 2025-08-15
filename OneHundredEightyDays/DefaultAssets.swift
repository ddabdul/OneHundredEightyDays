//
//  DefaultAssets.swift
//  OneHundredEightyDays
//

import UIKit

enum DefaultAssets {
    /// PNG data for the default manual-trip icon, loaded once from Assets.xcassets.
    static let manualTripIconData: Data? = {
        // Try the bundled asset first
        if let img = UIImage(named: "DefaultTrip"),
           let data = img.pngData() {
            return data
        }
        
        return nil
    }()
}

