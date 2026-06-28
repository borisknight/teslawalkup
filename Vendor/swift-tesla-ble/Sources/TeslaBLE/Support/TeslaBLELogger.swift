import os

/// Severity level for a log message, ordered from most verbose to most severe.
public enum TeslaBLELogLevel: Int, Comparable, Sendable {
    /// Fine-grained tracing useful during development.
    case debug = 0
    /// Normal operational events.
    case info = 1
    /// Recoverable anomalies that the caller may want to surface.
    case warning = 2
    /// Failures that typically end the current operation.
    case error = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Sink for internal TeslaBLE diagnostic messages.
///
/// Conform a type to this protocol to route TeslaBLE logs into `OSLog`,
/// a third-party logging framework, or a test double. Pass the conforming
/// value to ``TeslaVehicleClient/init(vin:keyStore:logger:)``.
///
/// The `message` parameter is `@autoclosure` so call sites can build
/// expensive strings inline. Implementations should decide whether to log
/// before evaluating the closure; evaluating it unconditionally defeats
/// the purpose of deferred construction.
///
/// `category` corresponds to an OSLog category such as `"transport"`,
/// `"session"`, or `"addkey"`. TeslaBLE uses a small fixed set so that
/// Console.app filters remain usable.
public protocol TeslaBLELogger: Sendable {
    /// Logs a single message at the given severity and category.
    ///
    /// - Parameters:
    ///   - level: Severity at which the message was emitted.
    ///   - category: Subsystem category, mirroring OSLog conventions.
    ///   - message: Deferred message builder; only evaluate if the logger
    ///     actually intends to record it.
    func log(
        _ level: TeslaBLELogLevel,
        category: String,
        _ message: @autoclosure () -> String,
    )
}

/// Default `TeslaBLELogger` implementation backed by `os.Logger`.
///
/// Messages below `minimumLevel` are dropped without evaluating the
/// message closure. By default every interpolated value is logged with
/// `privacy: .private`, because BLE session traffic routinely contains
/// key material, VIN fragments, and session tokens that should not appear
/// in Console.app on non-developer devices. Set `publicMessages` to
/// `true` only in development builds where call sites have been audited.
public struct OSLogTeslaBLELogger: TeslaBLELogger {
    private let subsystem: String
    private let minimumLevel: TeslaBLELogLevel
    private let publicMessages: Bool

    /// Creates an OSLog-backed logger.
    ///
    /// - Parameters:
    ///   - subsystem: OSLog subsystem string. Defaults to `"TeslaBLE"`.
    ///   - minimumLevel: Messages below this level are discarded cheaply.
    ///   - publicMessages: When `true`, interpolated values are logged
    ///     with `privacy: .public`. Use only in trusted development builds.
    public init(
        subsystem: String = "TeslaBLE",
        minimumLevel: TeslaBLELogLevel = .debug,
        publicMessages: Bool = false,
    ) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
        self.publicMessages = publicMessages
    }

    /// Routes a message to `os.Logger`, honoring `minimumLevel` and the
    /// configured privacy mode.
    public func log(
        _ level: TeslaBLELogLevel,
        category: String,
        _ message: @autoclosure () -> String,
    ) {
        guard level >= minimumLevel else { return }
        let logger = Logger(subsystem: subsystem, category: category)
        let text = message()
        if publicMessages {
            logPublic(logger, level: level, text: text)
        } else {
            logPrivate(logger, level: level, text: text)
        }
    }

    private func logPrivate(_ logger: Logger, level: TeslaBLELogLevel, text: String) {
        switch level {
        case .debug: logger.debug("\(text, privacy: .private)")
        case .info: logger.info("\(text, privacy: .private)")
        case .warning: logger.notice("\(text, privacy: .private)")
        case .error: logger.error("\(text, privacy: .private)")
        }
    }

    private func logPublic(_ logger: Logger, level: TeslaBLELogLevel, text: String) {
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warning: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
}
