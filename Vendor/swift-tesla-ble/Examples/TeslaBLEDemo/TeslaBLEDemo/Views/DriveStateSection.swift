//
//  DriveStateSection.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import SwiftUI
import TeslaBLE

/// GroupBox presenting gear/speed/power/odometer from `DriveState`, with
/// manual refresh and a live-poll toggle.
struct DriveStateSection: View {
    let drive: DriveState?

    var body: some View {
        Section("Drive State") {
            VStack(alignment: .leading, spacing: 12) {
                row("Gear", value: gearString)

                row("Speed", value: speedString)
                    .contentTransition(.numericText(value: drive?.speedMph ?? 0))

                row("Power", value: powerString)
                    .contentTransition(.numericText(value: Double(drive?.powerKW ?? 0)))

                row("Odometer", value: odometerString)
            }
            .animation(.linear(duration: 0.3), value: drive?.speedMph)
            .animation(.linear(duration: 0.3), value: drive?.powerKW)
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .monospacedDigit()
        }
    }

    private var gearString: String {
        switch drive?.shiftState {
        case .park: "P"
        case .reverse: "R"
        case .neutral: "N"
        case .drive: "D"
        case .none: "—"
        }
    }

    private var speedString: String {
        guard let mph = drive?.speedMph else { return "—" }
        return Measurement(value: mph, unit: UnitSpeed.milesPerHour)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .general,
                    numberFormatStyle: .number.precision(.fractionLength(0)),
                ),
            )
    }

    private var powerString: String {
        guard let kw = drive?.powerKW else { return "—" }
        return "\(kw) kW"
    }

    private var odometerString: String {
        guard let hundredths = drive?.odometerHundredthsMile else { return "—" }
        let miles = Double(hundredths) / 100
        return Measurement(value: miles, unit: UnitLength.miles)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .road,
                    numberFormatStyle: .number.precision(.fractionLength(2)),
                ),
            )
    }
}
