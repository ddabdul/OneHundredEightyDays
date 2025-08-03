//
//  PhotoQRCodeReader.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//

import SwiftUI
import PhotosUI
import UIKit
import BoardingPassKit   // for the `BoardingPass` type

struct PhotoQRCodeReader: View {
    @Environment(\.managedObjectContext) private var viewContext

    @State private var pickerItem: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var boardingPass: BoardingPass?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            PhotosPicker(
                "Select Boarding-Pass Photo",
                selection: $pickerItem,
                matching: .images
            )
            .onChange(of: pickerItem) { _, newItem in
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
                    Text("🛫 \(pass.info.origin) → \(pass.info.destination)")
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

    private func loadImageAndProcess(from item: PhotosPickerItem?) async {
        // reset UI
        boardingPass = nil
        errorMessage = nil

        guard let item = item else { return }

        do {
            // 1) Load image & data
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

            // 2) Decode + save via your shared service
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

struct PhotoQRCodeReader_Previews: PreviewProvider {
    static var previews: some View {
        PhotoQRCodeReader()
            .environment(
              \.managedObjectContext,
              PersistenceController.preview.container.viewContext
            )
    }
}

