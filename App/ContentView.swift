import SwiftUI
import TeslaBLE

struct ContentView: View {
    @Environment(VehicleGateway.self) private var gateway
    @Environment(\.scenePhase) private var scenePhase
    @State private var vinField = ""
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("State", value: phaseText)
                    if let vin = gateway.pairedVIN {
                        LabeledContent("Paired VIN", value: vin)
                    }
                    if !gateway.lastEvent.isEmpty {
                        Text(gateway.lastEvent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if gateway.pairedVIN == nil {
                    Section("Pair your Tesla") {
                        TextField("17-character VIN", text: $vinField)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Pair") {
                            Task { await gateway.startPairing(vin: vinField) }
                        }
                        .disabled(gateway.phase == .pairing)
                        Text("VIN length: \(vinField.trimmingCharacters(in: .whitespaces).count)/17. Sit in the car (awake), tap Pair, then tap your Tesla key card on the console when the car asks.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Live signal (walk-up debug)") {
                        if let r = gateway.liveRSSI {
                            LabeledContent("Signal", value: "\(r) dBm")
                        }
                        Text(gateway.engineNote.isEmpty ? "Waiting for car connection…" : gateway.engineNote)
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Section("Test") {
                        Button("Open driver door NOW") {
                            Task { await gateway.openDoor() }
                        }
                        .disabled(gateway.phase == .opening)
                        Stepper(
                            value: Binding(get: { gateway.holdMs }, set: { gateway.holdMs = $0 }),
                            in: 2000 ... 20000,
                            step: 1000,
                        ) {
                            Text("Unlatch window: \(gateway.holdMs / 1000) s")
                        }
                        Text("Unlatches once every ~2s for this long — pull the door open by its edge during a pulse as you walk up.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Section("Walk-up") {
                        Stepper(
                            value: Binding(get: { gateway.triggerRSSI }, set: { gateway.triggerRSSI = $0 }),
                            in: -90 ... -45,
                            step: 2,
                        ) {
                            Text("Open at: \(gateway.triggerRSSI) dBm")
                        }
                        Text("Lower = opens from farther away / earlier. Watch the live signal above while you approach, then set this to the dBm you see a step or two BEFORE you reach the door.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Re-discover car") { gateway.reDiscover() }
                        Button("Forget vehicle", role: .destructive) { gateway.forget() }
                    }
                }

                Section("Log (screenshot this after a background test)") {
                    HStack {
                        Button("Refresh") { logText = DiskLog.tail() }
                        Spacer()
                        Button("Clear", role: .destructive) { DiskLog.clear(); logText = "" }
                    }
                    ScrollView {
                        Text(logText.isEmpty ? "(tap Refresh)" : logText)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 240)
                }
            }
            .navigationTitle("TeslaWalkUp")
            .onAppear { logText = DiskLog.tail() }
            .onChange(of: scenePhase) { _, phase in
                DiskLog.log(">>> APP scenePhase = \(phase) <<<")
            }
        }
    }

    private var phaseText: String {
        switch gateway.phase {
        case .unpaired: "Not paired"
        case .pairing: "Pairing…"
        case .armed: "Armed (watching)"
        case .opening: "Opening…"
        case let .idleMessage(m): m
        }
    }
}
