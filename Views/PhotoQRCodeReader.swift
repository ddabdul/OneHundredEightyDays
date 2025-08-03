//
//  PhotoQRCodeReader.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//


import SwiftUI
import PhotosUI
import UIKit
import Vision

struct PhotoQRCodeReader: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var qrPayload: String?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            PhotosPicker(
                "Select Photo",
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
            }
            
            if let payload = qrPayload {
                ScrollView {
                    Text("🔍 Detected payload:")
                        .font(.headline)
                    Text(payload)
                        .font(.body)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }
                .padding()
            }
            
            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func loadImageAndDetect(from item: PhotosPickerItem?) async {
        qrPayload = nil
        errorMessage = nil
        
        guard let item = item else { return }
        do {
            // 1) Load image data
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                throw NSError(domain: "", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
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

/// Async helper that returns the first barcode payload (QR/Aztec/PDF417/Code128) it finds.
func detectBarcode(in image: UIImage) async throws -> String? {
    guard let cgImage = image.cgImage else {
        throw NSError(domain: "", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not get CGImage"])
    }
    
    return try await withCheckedThrowingContinuation { cont in
        let request = VNDetectBarcodesRequest { req, err in
            if let e = err {
                cont.resume(throwing: e)
            } else {
                let payload = (req.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue }
                    .first
                cont.resume(returning: payload)
            }
        }
        request.symbologies = [.QR, .Aztec, .PDF417, .code128]
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            cont.resume(throwing: error)
        }
    }
}

struct PhotoQRCodeReader_Previews: PreviewProvider {
    static var previews: some View {
        PhotoQRCodeReader()
    }
}
