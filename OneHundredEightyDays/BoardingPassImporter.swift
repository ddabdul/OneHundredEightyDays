//
//  BoardingPassImporter.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//


import SwiftUI
import PhotosUI

struct BoardingPassImporter: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var pickerItem: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            PhotosPicker(
                "Select Boarding Pass Image",
                selection: $pickerItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: pickerItem) { oldItem, newItem in
                Task {
                    await loadImage(from: newItem)
                }
            }

            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    /// Load the picked photo into a UIImage
    private func loadImage(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                uiImage = image
                try await processBoardingPass(image: image, rawData: data)
            } else {
                errorMessage = "Failed to load image data."
            }
        } catch {
            errorMessage = "Error loading image: \(error.localizedDescription)"
        }
    }

    /// Decode & save
    private func processBoardingPass(image: UIImage, rawData: Data) async throws {
        guard let payload = try await detectBarcode(in: image) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No barcode found"])
        }
        // parse the BCBP string (use the parseBCBP function from earlier)
        let bc = try parseBCBP(payload)
        // save into Core Data
        try saveTrip(from: bc, imageData: rawData, ctx: viewContext)
    }
}
