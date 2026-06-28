import Foundation

/// Installed firmware version and in-progress software update status.
public struct SoftwareUpdateState: Sendable, Equatable {
    /// Current installed firmware version string. Nil if the vehicle did not report this field.
    public var version: String?
    /// Download progress of a pending update in percent (0–100). Nil if the vehicle did not report this field.
    public var downloadPercent: Int?
    /// Install progress of a pending update in percent (0–100). Nil if the vehicle did not report this field.
    public var installPercent: Int?
    /// Expected total install duration in seconds. Nil if the vehicle did not report this field.
    public var expectedDurationSeconds: Int?

    public init(
        version: String? = nil,
        downloadPercent: Int? = nil,
        installPercent: Int? = nil,
        expectedDurationSeconds: Int? = nil,
    ) {
        self.version = version
        self.downloadPercent = downloadPercent
        self.installPercent = installPercent
        self.expectedDurationSeconds = expectedDurationSeconds
    }
}
