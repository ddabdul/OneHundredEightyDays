//
//  PhotoQRCodeReader.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import SwiftUI
import PhotosUI
import UIKit
import BoardingPassKit

struct PhotoQRCodeReader: View {
    @Environment(\.managedObjectContext) private var viewContext

    @State private var pickerItem: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var boardingPass: BoardingPass?
    @State private var errorMessage: String?

    // Use the unified lookup that also reads CityCodes_full.plist
    private static let airportLookup = AirportLookup()

    var body: some View {
        VStack(spacing: 20) {
            PhotosPicker(
                "Select Boarding-Pass Photo",
                selection: $pickerItem,
                matching: .images
            )
            // iOS 17-friendly onChange signature
            .onChange(of: pickerItem) { oldItem, newItem in
                Task { await loadImageAndProcess(from: newItem) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)

            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(8)
            }

            if let pass = boardingPass {
                VStack(alignment: .leading, spacing: 8) {
                    Text("✈️ Passenger: \(pass.info.name)")
                    Text("📋 PNR: \(pass.info.pnrCode)")
                    Text("🧭 \(cityCountry(pass.info.origin)) → \(cityCountry(pass.info.destination))")
                    Text("🛬 Carrier: \(pass.info.operatingCarrier) \(pass.info.flightno)")
                    if let date = dateFromJulian(pass.info.julianDate) {
                        Text("📅 Date: \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                    Text("💺 Seat: \(pass.info.seatno)")
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }

            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    /// Returns "Metro City, Country" using AirportLookup (which consults CityCodes_full.plist)
    private func cityCountry(_ code: String) -> String {
        let u = code.uppercased()

        // Metro city from CityCodes_full.plist
        let metro = Self.airportLookup.metroCity(for: u)

        // Country (localized)
        let country = Self.airportLookup.countryName(for: u) ?? ""

        // Fallback to airport city/name if metro missing
        if let a = Self.airportLookup.airport(for: u) {
            let city = metro ?? (a.city.isEmpty ? a.name : a.city)
            return country.isEmpty ? city : "\(city), \(country)"
        }

        // Last-resort fallbacks
        if let metro { return country.isEmpty ? metro : "\(metro), \(country)" }
        return u
    }

    private func loadImageAndProcess(from item: PhotosPickerItem?) async {
        boardingPass = nil
        errorMessage = nil
        guard let item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw NSError(domain: "", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
            }
            uiImage = image

            let pass = try await BoardingPassService.process(
                image: image,
                rawData: data,
                in: viewContext
            )
            boardingPass = pass
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
