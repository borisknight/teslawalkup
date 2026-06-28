import Foundation

/// Gear, speed, power, odometer, and active-route status reported by the vehicle.
public struct DriveState: Sendable, Equatable {
    /// Current transmission position (P/R/N/D). Nil if the vehicle did not report this field.
    public var shiftState: ShiftState?
    /// Current ground speed in miles per hour. Nil if the vehicle did not report this field.
    public var speedMph: Double?
    /// Instantaneous drivetrain power in kilowatts (negative while regenerating). Nil if the vehicle did not report this field.
    public var powerKW: Int?
    /// Odometer reading in hundredths of a mile (divide by 100 to get miles). Nil if the vehicle did not report this field.
    public var odometerHundredthsMile: Int?
    /// Active navigation destination name, if any. Nil if the vehicle did not report this field.
    public var activeRouteDestination: String?
    /// Estimated minutes remaining on the active route. Nil if the vehicle did not report this field.
    public var activeRouteMinutesToArrival: Double?
    /// Remaining distance on the active route in miles. Nil if the vehicle did not report this field.
    public var activeRouteMilesToArrival: Double?

    /// Transmission gear position.
    public enum ShiftState: Sendable, Equatable {
        /// Park.
        case park
        /// Reverse.
        case reverse
        /// Neutral.
        case neutral
        /// Drive.
        case drive
    }

    public init(
        shiftState: ShiftState? = nil,
        speedMph: Double? = nil,
        powerKW: Int? = nil,
        odometerHundredthsMile: Int? = nil,
        activeRouteDestination: String? = nil,
        activeRouteMinutesToArrival: Double? = nil,
        activeRouteMilesToArrival: Double? = nil,
    ) {
        self.shiftState = shiftState
        self.speedMph = speedMph
        self.powerKW = powerKW
        self.odometerHundredthsMile = odometerHundredthsMile
        self.activeRouteDestination = activeRouteDestination
        self.activeRouteMinutesToArrival = activeRouteMinutesToArrival
        self.activeRouteMilesToArrival = activeRouteMilesToArrival
    }
}
