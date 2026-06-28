import Foundation

/// Sliding replay-protection window over a 32-bit vehicle message counter.
///
/// Inbound responses carry a monotonically-increasing counter that the
/// verifier must allow in-order but also tolerate small re-orderings without
/// accepting the same counter twice. This is the standard sliding-window
/// replay filter used by IPsec/SRTP and ported directly from
/// `internal/authentication/window.go` in `tesla-vehicle-command`.
///
/// Semantics:
/// - `counter` tracks the highest counter value observed so far.
/// - `history` is a 64-bit bitmap of the 32 counters strictly below `counter`
///   (LSB = `counter - 1`, bit 1 = `counter - 2`, ...). A set bit means
///   "already seen".
/// - "Too old" = more than `windowSize` behind `counter`; the window cannot
///   prove the value hasn't been seen, so it is rejected.
/// - "Already seen" = equal to `counter` or its bit is already set in
///   `history`; also rejected.
/// - `initialized` exists because the first observed counter is not
///   necessarily 1 — the vehicle may start at an arbitrary value after a
///   handshake, so we cannot distinguish "never seen" from "seen value 0"
///   without this flag.
///
/// Fixture: `Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json`.
struct CounterWindow: Sendable {
    var counter: UInt32
    var history: UInt64
    var initialized: Bool

    /// Window size in bits. Must be ≤ 64. Matches `crypto.go` `windowSize = 32`.
    static let windowSize: UInt32 = 32

    init(counter: UInt32 = 0, history: UInt64 = 0, initialized: Bool = false) {
        self.counter = counter
        self.history = history
        self.initialized = initialized
    }

    /// Accepts a new counter value if it has not been seen before. On acceptance
    /// the internal state is updated and `true` is returned. On rejection state
    /// is left unchanged and `false` is returned.
    mutating func accept(_ newCounter: UInt32) -> Bool {
        if !initialized {
            initialized = true
            counter = newCounter
            // history stays 0 — we haven't observed any earlier value.
            return true
        }

        if counter == newCounter {
            return false
        }

        if newCounter < counter {
            let age = counter - newCounter
            if age > Self.windowSize {
                return false
            }
            let bit: UInt64 = 1 << (age - 1)
            if (history & bit) != 0 {
                return false
            }
            history |= bit
            return true
        }

        // newCounter > counter
        let shiftCount = newCounter - counter
        if shiftCount >= 64 {
            history = 0
        } else {
            history <<= shiftCount
        }
        history |= UInt64(1) << (shiftCount - 1)
        counter = newCounter
        return true
    }
}
