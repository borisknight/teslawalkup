import Foundation

/// Doors, windows, trunks, sunroof, and security/occupancy status.
public struct ClosuresState: Sendable, Equatable {
    /// `true` if the front-left door is open. Nil if the vehicle did not report this field.
    public var frontDriverDoor: Bool?
    /// `true` if the front-right door is open. Nil if the vehicle did not report this field.
    public var frontPassengerDoor: Bool?
    /// `true` if the rear-left door is open. Nil if the vehicle did not report this field.
    public var rearDriverDoor: Bool?
    /// `true` if the rear-right door is open. Nil if the vehicle did not report this field.
    public var rearPassengerDoor: Bool?
    /// `true` if the front trunk (frunk) is open. Nil if the vehicle did not report this field.
    public var frontTrunk: Bool?
    /// `true` if the rear trunk is open. Nil if the vehicle did not report this field.
    public var rearTrunk: Bool?
    /// `true` if the vehicle is currently locked. Nil if the vehicle did not report this field.
    public var locked: Bool?
    /// `true` if the front-left window is not fully closed. Nil if the vehicle did not report this field.
    public var windowDriverFront: Bool?
    /// `true` if the front-right window is not fully closed. Nil if the vehicle did not report this field.
    public var windowPassengerFront: Bool?
    /// `true` if the rear-left window is not fully closed. Nil if the vehicle did not report this field.
    public var windowDriverRear: Bool?
    /// `true` if the rear-right window is not fully closed. Nil if the vehicle did not report this field.
    public var windowPassengerRear: Bool?
    /// Current sunroof position state. Nil if the vehicle did not report this field or has no sunroof.
    public var sunroofState: SunroofState?
    /// Sunroof aperture as a percentage (0 = closed, 100 = fully open). Nil if the vehicle did not report this field.
    public var sunroofPercentOpen: Int?
    /// Whether Sentry Mode is currently armed/active. Nil if the vehicle did not report this field.
    public var sentryModeActive: Bool?
    /// Whether Valet Mode is enabled. Nil if the vehicle did not report this field.
    public var valetMode: Bool?
    /// Whether the vehicle detects an occupant present. Nil if the vehicle did not report this field.
    public var isUserPresent: Bool?

    /// Sunroof position state.
    public enum SunroofState: Sendable, Equatable {
        /// Fully closed.
        case closed
        /// Fully open (slid back).
        case open
        /// In vent / tilt position.
        case vent
        /// Actively moving between positions.
        case moving
        /// Performing a calibration cycle.
        case calibrating
        /// State not reported or unrecognized by the vehicle.
        case unknown
    }

    public init(
        frontDriverDoor: Bool? = nil,
        frontPassengerDoor: Bool? = nil,
        rearDriverDoor: Bool? = nil,
        rearPassengerDoor: Bool? = nil,
        frontTrunk: Bool? = nil,
        rearTrunk: Bool? = nil,
        locked: Bool? = nil,
        windowDriverFront: Bool? = nil,
        windowPassengerFront: Bool? = nil,
        windowDriverRear: Bool? = nil,
        windowPassengerRear: Bool? = nil,
        sunroofState: SunroofState? = nil,
        sunroofPercentOpen: Int? = nil,
        sentryModeActive: Bool? = nil,
        valetMode: Bool? = nil,
        isUserPresent: Bool? = nil,
    ) {
        self.frontDriverDoor = frontDriverDoor
        self.frontPassengerDoor = frontPassengerDoor
        self.rearDriverDoor = rearDriverDoor
        self.rearPassengerDoor = rearPassengerDoor
        self.frontTrunk = frontTrunk
        self.rearTrunk = rearTrunk
        self.locked = locked
        self.windowDriverFront = windowDriverFront
        self.windowPassengerFront = windowPassengerFront
        self.windowDriverRear = windowDriverRear
        self.windowPassengerRear = windowPassengerRear
        self.sunroofState = sunroofState
        self.sunroofPercentOpen = sunroofPercentOpen
        self.sentryModeActive = sentryModeActive
        self.valetMode = valetMode
        self.isUserPresent = isUserPresent
    }
}
