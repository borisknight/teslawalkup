//
//  PairingView.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import SwiftUI

struct PairingView: View {
    @Environment(VehicleController.self)
    private var controller

    @State
    private var vin: String = ""

    @State
    private var showWipeConfirmation: Bool = false

    var body: some View {
        Form {
            Section("Vehicle") {
                TextField("VIN (17 characters)", text: $vin)
                    .autocorrectionDisabled()
                    .monospaced()
                    .textInputAutocapitalization(.characters)
            }

            Section {
                Button {
                    Task {
                        await controller.startPairing(vin: vin)
                    }
                } label: {
                    HStack {
                        Text("Start pairing")
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if controller.isPairing {
                            ProgressView()
                        }
                    }
                }
                .disabled(vin.count != 17)

                Button(role: .destructive) {
                    showWipeConfirmation = true
                } label: {
                    Text("Clear all data")
                }
            }
            .disabled(controller.isPairing)
        }
        .navigationTitle("Pair vehicle")
        .alert(
            "Clear all data?",
            isPresented: $showWipeConfirmation,
        ) {
            Button("Cancel", role: .cancel) {}

            Button("Clear everything", role: .destructive) {
                controller.wipeAllPersistedData()
            }
        } message: {
            Text("This deletes the stored VIN and any pairing keys from the Keychain. You will have to re-pair the vehicle on the center console afterward.")
        }
    }
}

#if DEBUG

#Preview {
    PairingView()
        .environment(VehicleController())
}

#endif
