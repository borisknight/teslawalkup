import Foundation

/// Placeholder for the vehicle's scheduled-preconditioning configuration.
///
/// Currently empty: the snapshot only signals whether the vehicle reported a
/// preconditioning schedule section. Individual schedule entries are not yet
/// surfaced.
public struct PreconditionScheduleState: Sendable, Equatable {
    public init() {}
}
