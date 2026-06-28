import Foundation

/// Cabin climate, seat heater, and defrost status reported by the vehicle.
public struct ClimateState: Sendable, Equatable {
    /// Interior cabin temperature in degrees Celsius. Nil if the vehicle did not report this field.
    public var insideTempCelsius: Double?
    /// Exterior ambient temperature in degrees Celsius. Nil if the vehicle did not report this field.
    public var outsideTempCelsius: Double?
    /// Driver-side climate setpoint in degrees Celsius. Nil if the vehicle did not report this field.
    public var driverTempSettingCelsius: Double?
    /// Passenger-side climate setpoint in degrees Celsius. Nil if the vehicle did not report this field.
    public var passengerTempSettingCelsius: Double?
    /// HVAC fan level (raw vehicle scale, typically 0–7). Nil if the vehicle did not report this field.
    public var fanStatus: Int?
    /// Whether the HVAC system is currently running. Nil if the vehicle did not report this field.
    public var isClimateOn: Bool?
    /// Front-left seat heater level. Nil if the vehicle did not report this field.
    public var seatHeaterFrontLeft: SeatHeaterLevel?
    /// Front-right seat heater level. Nil if the vehicle did not report this field.
    public var seatHeaterFrontRight: SeatHeaterLevel?
    /// Rear-left seat heater level. Nil if the vehicle did not report this field.
    public var seatHeaterRearLeft: SeatHeaterLevel?
    /// Rear-center seat heater level. Nil if the vehicle did not report this field.
    public var seatHeaterRearCenter: SeatHeaterLevel?
    /// Rear-right seat heater level. Nil if the vehicle did not report this field.
    public var seatHeaterRearRight: SeatHeaterLevel?
    /// Whether the steering wheel heater is on. Nil if the vehicle did not report this field.
    public var steeringWheelHeater: Bool?
    /// Whether the high-voltage battery heater is active. Nil if the vehicle did not report this field.
    public var isBatteryHeaterOn: Bool?
    /// Whether defrost mode is active (normal or max). Nil if the vehicle did not report this field.
    public var defrostOn: Bool?
    /// Whether Bioweapon Defense Mode is on. Nil if the vehicle did not report this field.
    public var bioweaponMode: Bool?

    /// Seat heater intensity level.
    public enum SeatHeaterLevel: Int, Sendable, Equatable {
        /// Heater off.
        case off = 0
        /// Low heat.
        case low = 1
        /// Medium heat.
        case medium = 2
        /// High heat.
        case high = 3
    }

    public init(
        insideTempCelsius: Double? = nil,
        outsideTempCelsius: Double? = nil,
        driverTempSettingCelsius: Double? = nil,
        passengerTempSettingCelsius: Double? = nil,
        fanStatus: Int? = nil,
        isClimateOn: Bool? = nil,
        seatHeaterFrontLeft: SeatHeaterLevel? = nil,
        seatHeaterFrontRight: SeatHeaterLevel? = nil,
        seatHeaterRearLeft: SeatHeaterLevel? = nil,
        seatHeaterRearCenter: SeatHeaterLevel? = nil,
        seatHeaterRearRight: SeatHeaterLevel? = nil,
        steeringWheelHeater: Bool? = nil,
        isBatteryHeaterOn: Bool? = nil,
        defrostOn: Bool? = nil,
        bioweaponMode: Bool? = nil,
    ) {
        self.insideTempCelsius = insideTempCelsius
        self.outsideTempCelsius = outsideTempCelsius
        self.driverTempSettingCelsius = driverTempSettingCelsius
        self.passengerTempSettingCelsius = passengerTempSettingCelsius
        self.fanStatus = fanStatus
        self.isClimateOn = isClimateOn
        self.seatHeaterFrontLeft = seatHeaterFrontLeft
        self.seatHeaterFrontRight = seatHeaterFrontRight
        self.seatHeaterRearLeft = seatHeaterRearLeft
        self.seatHeaterRearCenter = seatHeaterRearCenter
        self.seatHeaterRearRight = seatHeaterRearRight
        self.steeringWheelHeater = steeringWheelHeater
        self.isBatteryHeaterOn = isBatteryHeaterOn
        self.defrostOn = defrostOn
        self.bioweaponMode = bioweaponMode
    }
}
