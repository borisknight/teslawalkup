//
//  InstrumentClusterView.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/16.
//

import SwiftUI
import TeslaBLE

/// Full-screen instrument cluster shown in landscape while connected.
///
/// Layout: gear row at top, large speed readout in the center, battery
/// percentage (bottom-leading) and odometer (bottom-trailing). All text
/// uses the Orbitron typeface with fixed sizing (no Dynamic Type scaling).
struct InstrumentClusterView: View {
    let drive: DriveState?
    let charge: ChargeState?

    private static let fontName = "Orbitron"

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                gearRow
                    .padding(.top, 24)

                Spacer()

                speedReadout

                Spacer()

                bottomBar
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Gear Row

    private var gearRow: some View {
        HStack(spacing: 40) {
            ForEach(Gear.allCases) { gear in
                Text(gear.rawValue)
                    .font(.custom(Self.fontName, fixedSize: 52).weight(.bold))
                    .foregroundStyle(
                        gear.shiftState == drive?.shiftState
                            ? .primary
                            : .tertiary,
                    )
            }
        }
    }

    // MARK: - Speed Readout

    private var speedReadout: some View {
        VStack(spacing: 0) {
            Text(speedValueString)
                .font(.custom(Self.fontName, fixedSize: 180).weight(.black))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.numericText(value: drive?.speedMph ?? 0))
                .animation(.linear(duration: 0.3), value: drive?.speedMph)

            Text(speedUnitString)
                .font(.custom(Self.fontName, fixedSize: 36).weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Text(batteryString)
                .font(.custom(Self.fontName, fixedSize: 36))
                .foregroundStyle(.secondary)

            Spacer()

            Text(odometerString)
                .font(.custom(Self.fontName, fixedSize: 36))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatted Strings

    private var speedValueString: String {
        guard let mph = drive?.speedMph else { return "—" }
        let localized = Measurement(value: mph, unit: UnitSpeed.milesPerHour)
            .converted(to: preferredSpeedUnit)
        return Int(localized.value.rounded()).formatted()
    }

    private var speedUnitString: String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        let sample = Measurement(value: 0, unit: preferredSpeedUnit)
        return formatter.string(from: sample)
            .trimmingCharacters(in: .decimalDigits)
            .trimmingCharacters(in: .whitespaces)
    }

    private var preferredSpeedUnit: UnitSpeed {
        let usesMetric = Locale.current.measurementSystem == .metric
        return usesMetric ? .kilometersPerHour : .milesPerHour
    }

    private var batteryString: String {
        if let level = charge?.batteryLevel {
            return "\(level)%"
        }
        if let rangeMiles = charge?.estBatteryRangeMiles ?? charge?.batteryRangeMiles {
            let m = Measurement(value: rangeMiles, unit: UnitLength.miles)
            return m.formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .road,
                    numberFormatStyle: .number.precision(.fractionLength(0)),
                ),
            )
        }
        return "—"
    }

    private var odometerString: String {
        guard let hundredths = drive?.odometerHundredthsMile else { return "—" }
        let miles = Double(hundredths) / 100
        return Measurement(value: miles, unit: UnitLength.miles)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .road,
                    numberFormatStyle: .number.precision(.fractionLength(0)),
                ),
            )
    }
}

// MARK: - Gear Model

private enum Gear: String, CaseIterable, Identifiable {
    case park = "P"
    case reverse = "R"
    case neutral = "N"
    case drive = "D"

    var id: String {
        rawValue
    }

    var shiftState: DriveState.ShiftState {
        switch self {
        case .park: .park
        case .reverse: .reverse
        case .neutral: .neutral
        case .drive: .drive
        }
    }
}
