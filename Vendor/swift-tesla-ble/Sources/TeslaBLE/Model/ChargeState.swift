import Foundation

/// Current battery and charge-port status reported by the vehicle.
public struct ChargeState: Sendable, Equatable {
    /// State of charge in percent (0–100). Nil if the vehicle did not report this field.
    public var batteryLevel: Int?
    /// Rated remaining range in miles. Nil if the vehicle did not report this field.
    public var batteryRangeMiles: Double?
    /// Estimated remaining range in miles based on recent driving. Nil if the vehicle did not report this field.
    public var estBatteryRangeMiles: Double?
    /// Current charging session status. Nil if the vehicle did not report this field.
    public var chargingStatus: ChargingStatus?
    /// Charger voltage in volts. Nil if the vehicle did not report this field.
    public var chargerVoltage: Int?
    /// Charger actual current in amps. Nil if the vehicle did not report this field.
    public var chargerCurrent: Int?
    /// Charger power in kilowatts. Nil if the vehicle did not report this field.
    public var chargerPower: Int?
    /// User-configured charge limit in percent (0–100). Nil if the vehicle did not report this field.
    public var chargeLimitPercent: Int?
    /// Estimated minutes remaining until charging completes. Nil if the vehicle did not report this field.
    public var minutesToFullCharge: Int?
    /// Range added per hour of charging, in miles per hour. Nil if the vehicle did not report this field.
    public var chargeRateMph: Double?
    /// Whether the charge port door is physically open. Nil if the vehicle did not report this field.
    public var chargePortOpen: Bool?
    /// Whether the charge port latch is engaged on the connector. Nil if the vehicle did not report this field.
    public var chargePortLatched: Bool?

    /// High-level charging session state.
    public enum ChargingStatus: Sendable, Equatable {
        /// No charge cable connected.
        case disconnected
        /// Actively drawing power from the charger.
        case charging
        /// Charging session finished (battery reached target SoC).
        case complete
        /// Charging paused or stopped by the user or vehicle.
        case stopped
        /// Handshake in progress, not yet drawing power.
        case starting
    }

    public init(
        batteryLevel: Int? = nil,
        batteryRangeMiles: Double? = nil,
        estBatteryRangeMiles: Double? = nil,
        chargingStatus: ChargingStatus? = nil,
        chargerVoltage: Int? = nil,
        chargerCurrent: Int? = nil,
        chargerPower: Int? = nil,
        chargeLimitPercent: Int? = nil,
        minutesToFullCharge: Int? = nil,
        chargeRateMph: Double? = nil,
        chargePortOpen: Bool? = nil,
        chargePortLatched: Bool? = nil,
    ) {
        self.batteryLevel = batteryLevel
        self.batteryRangeMiles = batteryRangeMiles
        self.estBatteryRangeMiles = estBatteryRangeMiles
        self.chargingStatus = chargingStatus
        self.chargerVoltage = chargerVoltage
        self.chargerCurrent = chargerCurrent
        self.chargerPower = chargerPower
        self.chargeLimitPercent = chargeLimitPercent
        self.minutesToFullCharge = minutesToFullCharge
        self.chargeRateMph = chargeRateMph
        self.chargePortOpen = chargePortOpen
        self.chargePortLatched = chargePortLatched
    }
}
