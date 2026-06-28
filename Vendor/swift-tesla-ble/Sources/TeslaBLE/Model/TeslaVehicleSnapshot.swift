import Foundation

/// Aggregated snapshot of a Tesla vehicle's state sub-sections.
///
/// Returned by ``TeslaVehicleClient/fetch(_:)``. Each sub-section corresponds
/// to one area of vehicle state (charge, climate, drive, etc.) and is `nil`
/// when the vehicle did not populate that section in the response.
public struct TeslaVehicleSnapshot: Sendable, Equatable {
    /// Battery and charge-port state. Nil if the vehicle did not report this section.
    public var charge: ChargeState?
    /// Cabin climate, seat heater, and defrost state. Nil if the vehicle did not report this section.
    public var climate: ClimateState?
    /// Gear, speed, power, odometer, and active route state. Nil if the vehicle did not report this section.
    public var drive: DriveState?
    /// Doors, windows, trunks, sunroof, sentry/valet state. Nil if the vehicle did not report this section.
    public var closures: ClosuresState?
    /// Per-wheel tire pressure readings and recommended cold pressures. Nil if the vehicle did not report this section.
    public var tirePressure: TirePressureState?
    /// Basic now-playing media info and audio volume. Nil if the vehicle did not report this section.
    public var media: MediaState?
    /// Extended media info (album, source, track times). Nil if the vehicle did not report this section.
    public var mediaDetail: MediaDetailState?
    /// Firmware version and in-progress software update progress. Nil if the vehicle did not report this section.
    public var softwareUpdate: SoftwareUpdateState?
    /// Scheduled charging state. Nil if the vehicle did not report this section.
    public var chargeSchedule: ChargeScheduleState?
    /// Scheduled preconditioning state. Nil if the vehicle did not report this section.
    public var preconditionSchedule: PreconditionScheduleState?
    /// Parental controls state. Nil if the vehicle did not report this section.
    public var parentalControls: ParentalControlsState?

    public init(
        charge: ChargeState? = nil,
        climate: ClimateState? = nil,
        drive: DriveState? = nil,
        closures: ClosuresState? = nil,
        tirePressure: TirePressureState? = nil,
        media: MediaState? = nil,
        mediaDetail: MediaDetailState? = nil,
        softwareUpdate: SoftwareUpdateState? = nil,
        chargeSchedule: ChargeScheduleState? = nil,
        preconditionSchedule: PreconditionScheduleState? = nil,
        parentalControls: ParentalControlsState? = nil,
    ) {
        self.charge = charge
        self.climate = climate
        self.drive = drive
        self.closures = closures
        self.tirePressure = tirePressure
        self.media = media
        self.mediaDetail = mediaDetail
        self.softwareUpdate = softwareUpdate
        self.chargeSchedule = chargeSchedule
        self.preconditionSchedule = preconditionSchedule
        self.parentalControls = parentalControls
    }
}
