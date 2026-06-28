//
//  DashboardView.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import SwiftUI
import TeslaBLE

struct DashboardView: View {
    @Bindable var controller: VehicleController

    @Environment(\.scenePhase)
    private var scenePhase

    @Environment(\.verticalSizeClass)
    private var verticalSizeClass

    @State
    private var isUnlocking = false

    @State
    private var isHonking = false

    @State
    private var showForgetConfirm = false

    var body: some View {
        // Wrap in a stable container so rotation-driven branch swaps don't
        // re-fire .task / .onDisappear and tear down the BLE session.
        ZStack {
            if verticalSizeClass == .compact {
                InstrumentClusterView(drive: controller.drive, charge: controller.charge)
            } else {
                portraitList
            }
        }
        .task { await controller.connect() }
        .onDisappear { Task { await controller.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await controller.disconnect() }
            case .active: Task { await controller.connect() }
            default: break
            }
        }
    }

    // MARK: - Portrait List

    private var portraitList: some View {
        List {
            Section("Status") {
                ConnectionStatusRow(state: controller.connectionState)

                LabeledContent {
                    Text(controller.pairedVIN ?? "—")
                        .font(.footnote)
                        .monospaced()
                } label: {
                    Label("VIN", systemImage: "car.fill")
                }

                LabeledContent {
                    Toggle("", isOn: $controller.isLive)
                        .labelsHidden()
                } label: {
                    Label("Live", systemImage: "play.fill")
                }
                .disabled(controller.connectionState != .connected)

                Stepper(
                    "Drive poll: \(controller.drivePollMs) ms",
                    value: $controller.drivePollMs,
                    in: 100 ... 5000,
                    step: 100,
                )
                .disabled(controller.connectionState != .connected)

                Stepper(
                    "Charge poll: \(controller.chargePollSec) s",
                    value: $controller.chargePollSec,
                    in: 1 ... 60,
                    step: 1,
                )
                .disabled(controller.connectionState != .connected)
            }

            DriveStateSection(drive: controller.drive)

            Section("Commands") {
                Button {
                    Task {
                        isUnlocking = true
                        await controller.unlock()
                        isUnlocking = false
                    }
                } label: {
                    LabeledContent {
                        if isUnlocking {
                            ProgressView()
                        }
                    } label: {
                        Label("Unlock", systemImage: "lock.open.fill")
                    }
                }
                .disabled(controller.connectionState != .connected || isUnlocking)

                Button {
                    Task {
                        isHonking = true
                        await controller.honk()
                        isHonking = false
                    }
                } label: {
                    LabeledContent {
                        if isHonking {
                            ProgressView()
                        }
                    } label: {
                        Label("Honk", systemImage: "speaker.wave.2.fill")
                    }
                }
                .disabled(controller.connectionState != .connected || isHonking)
            }

            Section {
                Button("Forget this vehicle", role: .destructive) {
                    showForgetConfirm = true
                }
            } footer: {
                Text("Removes the stored key and VIN. You will need to pair again.")
            }
        }
        .refreshable {
            await controller.refreshDrive()
            await controller.refreshCharge()
        }
        .navigationTitle("Dashboard")
        .alert(
            "Forget this vehicle?",
            isPresented: $showForgetConfirm,
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                Task {
                    await controller.disconnect()
                    controller.clearPairing()
                }
            }
        } message: {
            Text("This will remove the stored key and VIN from this device. You will need to pair again to control this vehicle.")
        }
    }
}

#if DEBUG

#Preview {
    DashboardView(controller: VehicleController())
}

#endif
