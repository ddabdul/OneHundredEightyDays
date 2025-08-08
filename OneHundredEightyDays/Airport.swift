// AirportData.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.

import Foundation

struct Airport: Decodable {
  let name:    String
  let city:    String
  let country: String
}

final class AirportData {
  static let shared = AirportData()
  private let lookup: [String: Airport]

  private init() {
    guard
      let url  = Bundle.main.url(forResource: "airports", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let map  = try? JSONDecoder().decode([String: Airport].self, from: data)
    else {
      lookup = [:]
      print("⚠️ Could not load airports.json")
      return
    }
    lookup = map
  }

  func airport(for code: String) -> Airport? {
    lookup[code.uppercased()]
  }
}
