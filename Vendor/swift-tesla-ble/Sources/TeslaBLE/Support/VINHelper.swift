import CryptoKit
import Foundation

/// Derives the BLE advertisement local name a Tesla vehicle broadcasts for
/// a given VIN.
///
/// Tesla vehicles advertise a deterministic local name computed from the
/// VIN, and TeslaBLE's scanner filters discovered peripherals by exact
/// match. This helper centralizes that derivation.
enum VINHelper {
    /// Returns the BLE advertisement local name for `vin`.
    ///
    /// The format is `"S"` followed by the first 8 bytes of `SHA-1(VIN)`
    /// encoded as lowercase hex, followed by `"C"`.
    ///
    /// - Parameter vin: The 17-character Tesla VIN to hash.
    /// - Returns: The 18-character local-name string the vehicle advertises.
    static func bleLocalName(for vin: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(vin.utf8))
        let first8 = digest.prefix(8)
        let hex = first8.map { String(format: "%02x", $0) }.joined()
        return "S\(hex)C"
    }
}
