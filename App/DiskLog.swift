import Foundation

/// Tiny thread-safe append-only logger to a file in the app's Documents dir.
/// Survives backgrounding (the UI's `lastEvent` does not), so we can see what
/// the engine did while the app was suspended. View it in the app's Log screen
/// or pull `Documents/twlog.txt` off the device.
enum DiskLog {
    private static let queue = DispatchQueue(label: "com.knight.teslawalkup.disklog")
    private static let maxBytes = 200_000

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("twlog.txt")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Returns the most recent `~maxLines` lines (reads on the caller's thread).
    static func tail(maxLines: Int = 80) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(no log yet)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}
