//
//  PhotoQRCodeReader.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import SwiftUI
import PhotosUI
import Vision
import UIKit

/// A simple view that lets the user pick an image,
/// runs Vision barcode detection, and displays the raw payload.
struct PhotoQRCodeReader: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var qrPayload: String?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            PhotosPicker(
                "Select Boarding-Pass Photo",
                selection: $pickerItem,
                matching: .images
            )
            .onChange(of: pickerItem) { _, newItem in
                Task {
                    await loadImageAndDetect(from: newItem)
                }
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
            
            if let payload = qrPayload {
                VStack(alignment: .leading, spacing: 8) {
                    Text("🔍 Detected payload:")
                        .font(.headline)
                    ScrollView {
                        Text(payload)
                            .font(.body)
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(6)
                    }
                }
                .padding(.horizontal)
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
    
    /// Loads the picked image, displays it, and calls your shared `detectBarcode(in:)`.
    private func loadImageAndDetect(from item: PhotosPickerItem?) async {
        qrPayload = nil
        errorMessage = nil
        
        guard let item = item else { return }
        do {
            // 1) Load image data
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                throw NSError(
                  domain: "",
                  code: -1,
                  userInfo: [NSLocalizedDescriptionKey: "Failed to load image"]
                )
            }
            uiImage = image
            
            // 2) Run barcode detection
            if let payload = try await detectBarcode(in: image) {
                qrPayload = payload
            } else {
                errorMessage = "No barcode/QR code found in that image."
            }
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PhotoQRCodeReader_Previews: PreviewProvider {
    static var previews: some View {
        PhotoQRCodeReader()
    }
}
