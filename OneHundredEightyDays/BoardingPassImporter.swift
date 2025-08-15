//  BoardingPassImporter.swift
//  OneHundredEightyDays
//

import SwiftUI
import PhotosUI
import CoreData
import UIKit

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
            .onChange(of: pickerItem) { _, newItem in
                Task { await loadImage(from: newItem) }
            }
            
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .cornerRadius(8)
            }
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }
    
    /// Load the picked photo into a UIImage and process via BoardingPassService
    private func loadImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                uiImage = image
                _ = try await BoardingPassService.process(
                    image: image,
                    rawData: data,
                    in: viewContext
                )
            } else {
                errorMessage = "Failed to load image data."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
