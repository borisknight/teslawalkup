import Foundation

/// Typed command surface for the vehicle.
///
/// `Command` is a pure value type grouped into one inner enum per
/// functional area. Each case corresponds to one Tesla BLE action;
/// `CommandEncoder` turns it into a `(domain, body)` pair ready for
/// dispatch. Use ``TeslaVehicleClient/send(_:timeout:)`` to execute one.
public enum Command: Sendable, Equatable {
    /// Locks, unlocks, closures, sentry/valet, and whitelist management.
    case security(Security)
    /// Charging start/stop, charge limit, amperage, and scheduling.
    case charge(Charge)
    /// HVAC, seat heaters/coolers, and cabin overheat protection.
    case climate(Climate)
    /// Miscellaneous physical actions: horn, lights, windows, Homelink, sunroof.
    case actions(Actions)
    /// Media playback transport and volume control.
    case media(Media)
    /// Software-update scheduling and vehicle naming.
    case infotainment(Infotainment)

    // MARK: - Security

    /// Security-related commands: physical access (VCSEC domain) together
    /// with policy-level security settings that live on the Infotainment
    /// domain, such as sentry mode, valet mode, and PIN-to-drive.
    ///
    /// The encoder picks the correct domain per case, so callers do not
    /// need to care which transport path each command takes.
    public enum Security: Sendable, Equatable {
        /// Locks the doors via the VCSEC domain.
        case lock
        /// Unlocks the doors via the VCSEC domain.
        case unlock
        /// Wakes the vehicle from sleep.
        case wakeVehicle
        /// Authorizes a short remote-drive window (for valet parking and similar).
        case remoteDrive
        /// Arms the vehicle's automatic secure-on-walk-away behavior.
        case autoSecure

        /// Opens the rear trunk.
        case openTrunk
        /// Closes the rear trunk on vehicles with a powered liftgate.
        case closeTrunk
        /// Opens the front trunk (frunk).
        case openFrunk

        /// Unlatches and cracks open the front driver door (VCSEC closure move).
        ///
        /// Mirrors the Tesla app's "Unlatch Door" control: the latch releases,
        /// the frameless window dips to clear the seal, and the door pops ajar a
        /// few inches so it can be pulled the rest of the way. It cannot be
        /// re-closed remotely. Driver door only — the other doors are present in
        /// the protocol but are not reliably actuable on Model 3/Y.
        case openDriverDoor

        /// Enables or disables Sentry Mode. Dispatched on the Infotainment domain.
        case setSentryMode(Bool)
        /// Enables or disables Valet Mode. Dispatched on the Infotainment domain.
        ///
        /// - Parameters:
        ///   - enabled: `true` to enter valet mode, `false` to leave it.
        ///   - password: Numeric PIN required by the vehicle to toggle valet mode.
        case setValetMode(enabled: Bool, password: String)

        /// Smart-actuates the rear trunk (opens if closed, closes if open).
        case actuateTrunk
        /// Opens the tonneau cover on vehicles equipped with one.
        case openTonneau
        /// Closes the tonneau cover.
        case closeTonneau
        /// Halts tonneau motion in place.
        case stopTonneau

        /// Removes a public key from the VCSEC whitelist.
        ///
        /// - Parameter publicKey: 65-byte uncompressed SEC1 encoding of the
        ///   P-256 public key to remove.
        case removeKey(publicKey: Data)

        /// Erases guest profile data on the Infotainment domain.
        ///
        /// - Parameter reason: Free-form reason string persisted in the
        ///   vehicle's audit log.
        case eraseGuestData(reason: String)

        /// Resets the driver PIN. Infotainment domain.
        case resetPin
        /// Resets the valet PIN. Infotainment domain.
        case resetValetPin
        /// Enables or disables Guest Mode.
        case setGuestMode(Bool)
        /// Enables PIN-to-Drive and sets the PIN.
        ///
        /// - Parameters:
        ///   - enabled: Whether PIN-to-Drive is active.
        ///   - password: New numeric PIN.
        case setPinToDrive(enabled: Bool, password: String)
        /// Clears PIN-to-Drive so the vehicle no longer requires a PIN to drive.
        case clearPinToDrive
        /// Activates Speed Limit Mode using the enrolled PIN.
        case activateSpeedLimit(pin: String)
        /// Deactivates Speed Limit Mode using the enrolled PIN.
        case deactivateSpeedLimit(pin: String)
        /// Sets the Speed Limit Mode ceiling in miles per hour.
        case setSpeedLimit(mph: Double)
        /// Clears the Speed Limit Mode PIN given the current PIN.
        case clearSpeedLimitPin(pin: String)
        /// Clears the Speed Limit Mode PIN via an administrative path that
        /// does not require knowing the current PIN.
        case clearSpeedLimitPinAdmin

        /// Adds a client public key to the vehicle's VCSEC whitelist.
        ///
        /// This is the bootstrap command that allows a fresh client to be
        /// trusted by a vehicle it has never seen before. It is the only
        /// command that travels the unsigned VCSEC pairing path: the
        /// vehicle accepts the request without a prior session and then
        /// waits for the user to tap a previously-enrolled owner key
        /// (typically the Tesla NFC card) on the center console to
        /// authorize. Once authorization succeeds the key is installed
        /// and subsequent sessions can handshake normally.
        ///
        /// To issue this command, connect the client with
        /// ``TeslaVehicleClient/ConnectMode/pairing``, send the command,
        /// then disconnect and reconnect with
        /// ``TeslaVehicleClient/ConnectMode/normal``.
        ///
        /// - Parameters:
        ///   - publicKey: 65-byte uncompressed SEC1 encoding
        ///     (`0x04 || X || Y`) of the P-256 public key to add.
        ///   - role: Role the vehicle should assign to the new key.
        ///   - formFactor: Form factor metadata the vehicle displays in its
        ///     key-management UI.
        case addKey(publicKey: Data, role: KeyRole, formFactor: KeyFormFactor)
    }

    /// Role assigned to a newly-added key.
    ///
    /// Only the two roles relevant to personal BLE pairing are exposed.
    /// Fleet-API roles such as fleet manager or vehicle monitor are
    /// intentionally omitted; this package targets personal BLE use.
    public enum KeyRole: Sendable, Equatable {
        /// Full control, including the ability to add and remove other keys.
        case owner
        /// Can drive the vehicle but cannot manage other keys.
        case driver
    }

    /// Form-factor metadata attached to a key, shown by the vehicle in its
    /// key-management UI.
    public enum KeyFormFactor: Sendable, Equatable {
        /// Form factor not reported.
        case unknown
        /// Tesla NFC key card.
        case nfcCard
        /// iOS device running the Tesla or a third-party app.
        case iosDevice
        /// Android device running the Tesla or a third-party app.
        case androidDevice
        /// Cloud-managed key.
        case cloudKey
    }

    // MARK: - Charge

    /// Charging commands. All cases dispatch on the Infotainment domain.
    public enum Charge: Sendable, Equatable {
        /// Starts charging if plugged in.
        case start
        /// Stops charging.
        case stop
        /// Starts charging to the max-range SOC target.
        case startMaxRange
        /// Starts charging to the standard-range SOC target.
        case startStandardRange
        /// Sets the target charge limit as a percentage of full.
        case setLimit(percent: Int32)
        /// Sets the AC charging current in amps.
        case setAmps(Int32)
        /// Opens the charge port door.
        case openPort
        /// Closes the charge port door on vehicles with a powered port.
        case closePort

        /// Enables or disables Low Power Mode.
        case setLowPowerMode(Bool)
        /// Enables or disables Keep Accessory Power Mode.
        case setKeepAccessoryPowerMode(Bool)

        /// Adds or updates a charge schedule entry.
        case addSchedule(ChargeScheduleInput)
        /// Removes a single charge schedule entry by id.
        case removeSchedule(id: UInt64)
        /// Bulk-removes charge schedules by location category.
        case batchRemoveSchedules(home: Bool, work: Bool, other: Bool)
        /// Adds or updates a preconditioning schedule entry.
        case addPreconditionSchedule(PreconditionScheduleInput)
        /// Removes a single preconditioning schedule entry by id.
        case removePreconditionSchedule(id: UInt64)
        /// Bulk-removes preconditioning schedules by location category.
        case batchRemovePreconditionSchedules(home: Bool, work: Bool, other: Bool)
        /// Configures a one-shot scheduled departure (preconditioning and off-peak).
        case scheduleDeparture(ScheduleDepartureInput)
        /// Enables or disables scheduled charging at a daily time.
        case scheduleCharging(enabled: Bool, timeAfterMidnightMinutes: Int32)
        /// Clears any active scheduled departure.
        case clearScheduledDeparture

        /// Parameters for ``Command/Charge/addSchedule(_:)``.
        public struct ChargeScheduleInput: Sendable, Equatable {
            public var id: UInt64
            public var name: String
            public var daysOfWeek: Int32
            public var startEnabled: Bool
            public var startTimeMinutes: Int32
            public var endEnabled: Bool
            public var endTimeMinutes: Int32
            public var oneTime: Bool
            public var enabled: Bool
            public var latitude: Float
            public var longitude: Float

            public init(
                id: UInt64 = 0,
                name: String = "",
                daysOfWeek: Int32 = 0,
                startEnabled: Bool = false,
                startTimeMinutes: Int32 = 0,
                endEnabled: Bool = false,
                endTimeMinutes: Int32 = 0,
                oneTime: Bool = false,
                enabled: Bool = true,
                latitude: Float = 0,
                longitude: Float = 0,
            ) {
                self.id = id
                self.name = name
                self.daysOfWeek = daysOfWeek
                self.startEnabled = startEnabled
                self.startTimeMinutes = startTimeMinutes
                self.endEnabled = endEnabled
                self.endTimeMinutes = endTimeMinutes
                self.oneTime = oneTime
                self.enabled = enabled
                self.latitude = latitude
                self.longitude = longitude
            }
        }

        /// Parameters for ``Command/Charge/addPreconditionSchedule(_:)``.
        public struct PreconditionScheduleInput: Sendable, Equatable {
            public var id: UInt64
            public var name: String
            public var daysOfWeek: Int32
            public var preconditionTimeMinutes: Int32
            public var oneTime: Bool
            public var enabled: Bool
            public var latitude: Float
            public var longitude: Float

            public init(
                id: UInt64 = 0,
                name: String = "",
                daysOfWeek: Int32 = 0,
                preconditionTimeMinutes: Int32 = 0,
                oneTime: Bool = false,
                enabled: Bool = true,
                latitude: Float = 0,
                longitude: Float = 0,
            ) {
                self.id = id
                self.name = name
                self.daysOfWeek = daysOfWeek
                self.preconditionTimeMinutes = preconditionTimeMinutes
                self.oneTime = oneTime
                self.enabled = enabled
                self.latitude = latitude
                self.longitude = longitude
            }
        }

        /// Parameters for ``Command/Charge/scheduleDeparture(_:)``.
        public struct ScheduleDepartureInput: Sendable, Equatable {
            /// Day pattern on which a departure-related behavior applies.
            public enum ChargingPolicy: Sendable, Equatable {
                /// Feature disabled.
                case off
                /// Apply every day of the week.
                case allDays
                /// Apply on weekdays only.
                case weekdays
            }

            public var departureTimeMinutes: Int32
            public var offPeakHoursEndTimeMinutes: Int32
            public var preconditioning: ChargingPolicy
            public var offpeak: ChargingPolicy

            public init(
                departureTimeMinutes: Int32,
                offPeakHoursEndTimeMinutes: Int32 = 0,
                preconditioning: ChargingPolicy = .off,
                offpeak: ChargingPolicy = .off,
            ) {
                self.departureTimeMinutes = departureTimeMinutes
                self.offPeakHoursEndTimeMinutes = offPeakHoursEndTimeMinutes
                self.preconditioning = preconditioning
                self.offpeak = offpeak
            }
        }
    }

    // MARK: - Climate

    /// Climate, seat, and cabin-protection commands. Infotainment domain.
    public enum Climate: Sendable, Equatable {
        /// Turns HVAC on.
        case on
        /// Turns HVAC off.
        case off
        /// Sets driver and passenger setpoints in Celsius.
        case setTemperature(driver: Float, passenger: Float)
        /// Toggles the steering-wheel heater.
        case setSteeringWheelHeater(Bool)
        /// Selects a Climate Keeper mode (off / keep / dog / camp).
        case setKeeperMode(ClimateKeeperMode)

        /// Enables or disables Preconditioning Max.
        ///
        /// - Parameters:
        ///   - enabled: Whether preconditioning-max is active.
        ///   - manualOverride: `true` if the toggle is a manual user action,
        ///     which overrides automatic scheduling.
        case setPreconditioningMax(enabled: Bool, manualOverride: Bool)
        /// Enables or disables Bioweapon Defense Mode.
        case setBioweaponDefenseMode(enabled: Bool, manualOverride: Bool)
        /// Enables or disables Cabin Overheat Protection.
        ///
        /// - Parameters:
        ///   - enabled: Whether the protection feature is active.
        ///   - fanOnly: `true` to run fan-only instead of full HVAC.
        case setCabinOverheatProtection(enabled: Bool, fanOnly: Bool)

        /// Sets the Cabin Overheat Protection temperature threshold.
        case setCabinOverheatProtectionTemperature(level: CabinOverheatTemperatureLevel)

        /// Sets the heater level for a specific seat.
        case setSeatHeater(level: SeatHeaterLevel, seat: SeatPosition)
        /// Sets the cooler (ventilation) level for a front seat.
        case setSeatCooler(level: SeatCoolerLevel, seat: FrontSeatPosition)
        /// Enables or disables Auto Seat and Climate for the listed front seats.
        case autoSeatAndClimate(enabled: Bool, positions: Set<FrontSeatPosition>)

        /// Climate Keeper modes for leaving occupants in the vehicle.
        public enum ClimateKeeperMode: Sendable, Equatable {
            /// Climate Keeper disabled.
            case off
            /// Generic "keep climate on" mode.
            case on
            /// Dog Mode (keeps cabin temperate for a pet).
            case dog
            /// Camp Mode (leaves climate and outlets available overnight).
            case camp
        }

        /// Cabin Overheat Protection temperature ceiling selection.
        public enum CabinOverheatTemperatureLevel: Sendable, Equatable {
            /// Low threshold (approx. 30 C).
            case low
            /// Medium threshold (approx. 35 C).
            case medium
            /// High threshold (approx. 40 C).
            case high
        }

        /// Seat heater levels.
        public enum SeatHeaterLevel: Sendable, Equatable {
            /// Heater off.
            case off
            /// Level 1.
            case low
            /// Level 2.
            case medium
            /// Level 3.
            case high
        }

        /// Seat cooler (ventilation) levels.
        public enum SeatCoolerLevel: Sendable, Equatable {
            /// Cooler off.
            case off
            /// Level 1.
            case low
            /// Level 2.
            case medium
            /// Level 3.
            case high
        }

        /// Seat positions addressable by ``Command/Climate/setSeatHeater(level:seat:)``.
        public enum SeatPosition: Sendable, Equatable, Hashable {
            /// Front-left (driver in LHD markets).
            case frontLeft
            /// Front-right (front passenger in LHD markets).
            case frontRight
            /// Rear-left seat cushion.
            case rearLeft
            /// Rear-left seat back.
            case rearLeftBack
            /// Rear-center seat.
            case rearCenter
            /// Rear-right seat cushion.
            case rearRight
            /// Rear-right seat back.
            case rearRightBack
            /// Third-row left seat.
            case thirdRowLeft
            /// Third-row right seat.
            case thirdRowRight
        }

        /// Subset of seat positions that have ventilation (coolers).
        public enum FrontSeatPosition: Sendable, Equatable, Hashable {
            /// Front-left seat.
            case frontLeft
            /// Front-right seat.
            case frontRight
        }
    }

    // MARK: - Actions

    /// Miscellaneous physical actions. Infotainment domain.
    public enum Actions: Sendable, Equatable {
        /// Honks the horn once.
        case honk
        /// Flashes the headlights.
        case flashLights
        /// Closes all windows.
        case closeWindows
        /// Vents all windows to the cracked-open position.
        case ventWindows
        /// Triggers the nearest Homelink device at the given location.
        ///
        /// - Parameters:
        ///   - latitude: Latitude of the Homelink device.
        ///   - longitude: Longitude of the Homelink device.
        case triggerHomelink(latitude: Float, longitude: Float)

        /// Moves the panoramic sunroof to an absolute open percentage.
        ///
        /// - Parameter level: 0 for fully closed through 100 for fully vented.
        case changeSunroof(level: Int32)
    }

    // MARK: - Media

    /// Media playback transport and volume. Infotainment domain.
    public enum Media: Sendable, Equatable {
        /// Toggles play/pause on the current source.
        case togglePlayback
        /// Skips to the next track.
        case nextTrack
        /// Skips to the previous track.
        case previousTrack
        /// Sets the absolute output volume.
        case setVolume(Float)

        /// Increments the volume by one step.
        case volumeUp
        /// Decrements the volume by one step.
        case volumeDown
        /// Switches to the next preset favorite.
        case nextFavorite
        /// Switches to the previous preset favorite.
        case previousFavorite
    }

    // MARK: - Infotainment

    /// Software-update and vehicle-naming commands. Infotainment domain.
    public enum Infotainment: Sendable, Equatable {
        /// Schedules an available software update to install after a delay.
        ///
        /// - Parameter offsetSeconds: Seconds from now at which the install
        ///   should begin.
        case scheduleSoftwareUpdate(offsetSeconds: Int32)
        /// Cancels a previously-scheduled software update.
        case cancelSoftwareUpdate
        /// Sets the user-visible vehicle name.
        case setVehicleName(String)
    }
}
