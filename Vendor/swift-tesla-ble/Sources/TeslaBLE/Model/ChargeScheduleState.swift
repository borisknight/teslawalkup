import Foundation

/// Placeholder for the vehicle's scheduled-charging configuration.
///
/// Currently empty: the snapshot only signals whether the vehicle reported a
/// charge schedule section. Individual schedule entries are not yet surfaced.
public struct ChargeScheduleState: Sendable, Equatable {
    public init() {}
}
