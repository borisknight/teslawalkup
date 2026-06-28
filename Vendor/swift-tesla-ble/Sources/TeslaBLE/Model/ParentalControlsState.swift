import Foundation

/// Parental-controls (Speed Limit Mode) status reported by the vehicle.
public struct ParentalControlsState: Sendable, Equatable {
    /// Whether parental controls are currently engaged. Nil if the vehicle did not report this field.
    public var active: Bool?
    /// Whether a parental-controls PIN has been configured on the vehicle. Nil if the vehicle did not report this field.
    public var pinSet: Bool?

    public init(active: Bool? = nil, pinSet: Bool? = nil) {
        self.active = active
        self.pinSet = pinSet
    }
}
