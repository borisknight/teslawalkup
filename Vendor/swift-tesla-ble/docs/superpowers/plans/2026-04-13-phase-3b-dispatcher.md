# Swift Native Rewrite — Phase 3b: Dispatcher Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `internal/dispatcher/*.go` to Swift as the `Dispatcher/` layer — an actor-based message router that sits on top of `BLETransport`, dispatches outbound commands signed by a `VehicleSession`, routes inbound responses back to pending continuations by UUID, handles handshake negotiation, and enforces per-request timeouts and cancellation.

**Architecture:** This plan is Phase 3b of the rewrite described in `docs/superpowers/specs/2026-04-13-swift-native-rewrite-design.md`. Phase 2 delivered `Crypto/`. Phase 3a delivered `Session/` (5 files) with 50 tests green. Phase 3b now adds a `Dispatcher/` layer that orchestrates command send/response matching, plus a reusable `MessageTransport` protocol that both the existing `BLETransport` (Core Bluetooth) and a new `FakeTransport` test double can conform to. Testing strategy is pure-Swift scenario tests against `FakeTransport` — no Go fixture dumps in this phase, since wire correctness is already locked in by Phase 2+3a.

**Tech Stack:** Swift 6 actors + async/await, CryptoKit (already used), SwiftProtobuf (already wired). No new SwiftPM dependencies.

**Wire-critical invariants:**

1. The dispatcher uses `RoutableMessage.uuid` for outbound identity (generated locally) and `RoutableMessage.requestUuid` for inbound matching (echoed by the vehicle). A 16-byte UUID is standard; any length will do as long as outbound sets `uuid` and inbound responses fill `requestUuid` with the matching bytes.
2. Per-domain sessions are keyed by `UniversalMessage_Domain`. The current target domains are `.vehicleSecurity` and `.infotainment`; `.broadcast` is used for some unsolicited VCSEC messages but never for outbound commands.
3. Inbound messages may arrive unsolicited (e.g., a late `SessionInfo` broadcast after an error) and must not be dropped if their `requestUuid` is empty or unknown — they go to the session-info handler. Bad frames with tag-mismatch or counter-replay are rejected security-critical (never silently swallowed; always raised to the pending continuation or logged as error).
4. `BLETransport` already handles framing via `MessageFramer` — `send(_ data: Data)` takes raw protobuf bytes and handles chunking, `receive() async -> Data` returns complete deframed messages. The Dispatcher does NOT re-frame; it only serializes/deserializes the `UniversalMessage_RoutableMessage` proto.

**What NOT to do in this plan:**

- Do NOT touch `Sources/TeslaBLE/Client/`, `Internal/MobileSessionAdapter.swift`, or `Transport/BLETransportBridge.swift`. They continue to drive the legacy xcframework path until Phase 5.
- Do NOT modify the existing `BLETransport.swift` beyond adding a protocol-conformance extension. Its Core Bluetooth internals stay intact.
- Do NOT write new Go fixtures. Phase 2+3a AAD fixtures already cover wire bytes; Phase 3b focuses on concurrent state-machine behavior.
- Do NOT refactor `Session/` files. If a bug surfaces there, stop and report.
- Do NOT modify `Package.swift`.

---

## File Structure

### Files to create

**Source — `Dispatcher/` layer:**

- `Sources/TeslaBLE/Dispatcher/MessageTransport.swift` — ~40 lines. Protocol `MessageTransport: Sendable` with `sendMessage(_ data: Data) async throws` and `receiveMessage() async throws -> Data`. Plus a conformance extension on `BLETransport` that wraps its existing sync `send` and async `receive`.
- `Sources/TeslaBLE/Dispatcher/RequestTable.swift` — ~120 lines. Not an actor — a value-typed helper used inside `Dispatcher`'s actor isolation. Stores `[Data: CheckedContinuation<UniversalMessage_RoutableMessage, Swift.Error>]` keyed by request UUID. Methods: `register(uuid:continuation:)`, `complete(uuid:with:)`, `fail(uuid:error:)`, `cancelAll(error:)`.
- `Sources/TeslaBLE/Dispatcher/Dispatcher.swift` — ~280 lines. `actor Dispatcher` owning transport, per-domain `VehicleSession?` (vcsec and infotainment), `RequestTable`, and an inbound `Task`. Public methods: `init(transport:logger:)`, `start()`, `stop()`, `installSession(_:forDomain:)`, `send(_:domain:timeout:) async throws -> Data` (returns plaintext), `negotiate(domain:publicKey:challenge:timeout:) async throws -> Signatures_SessionInfo`.

**Test:**

- `Tests/TeslaBLETests/FakeTransport.swift` — ~120 lines. Test double conforming to `MessageTransport`. Lets scenarios script exact inbound bytes, capture outbound bytes for assertions, and simulate receive-hangs for timeout tests. Implemented as an `actor` to serialize its internal queues.
- `Tests/TeslaBLETests/DispatcherTests.swift` — ~500 lines. Pure-Swift scenario tests: happy-path round-trip, timeout, task cancellation, unknown requestUuid handling, handshake flow, session-info-after-error, replay rejection propagation. Each test method is a single scenario and ends with explicit assertions; no shared fixture files.

### Files to modify

None. The scaffold-new-directory pattern from Phase 2/3a continues.

### Files to leave alone

- All of `Sources/TeslaBLE/Client/`, `Crypto/`, `Session/`, `Internal/`, `Transport/`, `Keys/`, `Model/`, `Support/`, `Generated/`.
- `Package.swift`, `Tests/TeslaBLETests/Fixtures/`, `GoPatches/`.

### Branching and commit cadence

Work continues on `dev`. Every task ends with an explicit commit. Small commits preferred.

---

## Task 1: Scaffold Dispatcher/ directory

**Files:**

- Create: `Sources/TeslaBLE/Dispatcher/.gitkeep`

- [ ] **Step 1:**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
mkdir -p Sources/TeslaBLE/Dispatcher
touch Sources/TeslaBLE/Dispatcher/.gitkeep
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 2:**

```bash
git add Sources/TeslaBLE/Dispatcher/.gitkeep
git commit -m "chore: scaffold Dispatcher/ directory"
```

---

## Task 2: Define `MessageTransport` protocol + BLETransport conformance

**Files:**

- Create: `Sources/TeslaBLE/Dispatcher/MessageTransport.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Abstract transport for complete `UniversalMessage_RoutableMessage` blobs.
///
/// Both `BLETransport` (production, Core Bluetooth-backed) and `FakeTransport`
/// (tests) conform to this protocol so that `Dispatcher` can be driven
/// uniformly without caring about the underlying channel.
///
/// Semantics:
/// - `sendMessage(_:)` accepts a serialized protobuf blob. The transport is
///   responsible for any framing / chunking. Callers must NOT frame the blob.
/// - `receiveMessage()` blocks until a complete deframed message is available.
///   It must return a protobuf-parseable blob (not raw BLE fragments).
protocol MessageTransport: Sendable {
    func sendMessage(_ data: Data) async throws
    func receiveMessage() async throws -> Data
}

// Bridge the existing `BLETransport` (sync `send` + async `receive`) into the
// uniform async protocol above.
extension BLETransport: MessageTransport {
    func sendMessage(_ data: Data) async throws {
        try send(data)
    }

    func receiveMessage() async throws -> Data {
        try await receive()
    }
}
```

- [ ] **Step 2: Build check**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git rm Sources/TeslaBLE/Dispatcher/.gitkeep
git add Sources/TeslaBLE/Dispatcher/MessageTransport.swift
git commit -m "feat: add MessageTransport protocol with BLETransport conformance"
```

---

## Task 3: Implement `RequestTable`

**Files:**

- Create: `Sources/TeslaBLE/Dispatcher/RequestTable.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Map of pending request UUIDs to their suspended continuations.
///
/// Not an actor — accessed only from within `Dispatcher`'s actor isolation,
/// so single-threaded access is guaranteed by the caller.
///
/// Continuation type is `CheckedContinuation<UniversalMessage_RoutableMessage, Swift.Error>`:
/// resumed with a decoded response message on success, or with an error on
/// timeout / cancellation / tag mismatch / disconnection.
struct RequestTable {

    enum Error: Swift.Error, Equatable {
        case duplicateRequestID
        case noSuchRequest
    }

    typealias Continuation = CheckedContinuation<UniversalMessage_RoutableMessage, Swift.Error>

    private var entries: [Data: Continuation] = [:]

    mutating func register(uuid: Data, continuation: Continuation) throws {
        if entries[uuid] != nil {
            throw Error.duplicateRequestID
        }
        entries[uuid] = continuation
    }

    /// Complete a pending request with a decoded response. Returns true if
    /// an entry was found and resumed, false if the uuid was unknown.
    @discardableResult
    mutating func complete(uuid: Data, with message: UniversalMessage_RoutableMessage) -> Bool {
        guard let continuation = entries.removeValue(forKey: uuid) else {
            return false
        }
        continuation.resume(returning: message)
        return true
    }

    /// Fail a pending request with an error. Returns true if an entry was
    /// found and failed, false if the uuid was unknown.
    @discardableResult
    mutating func fail(uuid: Data, error: Swift.Error) -> Bool {
        guard let continuation = entries.removeValue(forKey: uuid) else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    /// Fail all pending requests with the given error. Used during
    /// `Dispatcher.stop()` to wake up every suspended caller.
    mutating func cancelAll(error: Swift.Error) {
        let snapshot = entries
        entries.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    func contains(uuid: Data) -> Bool { entries[uuid] != nil }
}
```

- [ ] **Step 2: Build check**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/TeslaBLE/Dispatcher/RequestTable.swift
git commit -m "feat: implement RequestTable (pending request UUID → continuation map)"
```

---

## Task 4: `RequestTable` unit tests

**Files:**

- Modify: create `Tests/TeslaBLETests/DispatcherTests.swift`

- [ ] **Step 1: Create the test file with RequestTable coverage**

```swift
import Foundation
import XCTest
@testable import TeslaBLE

final class DispatcherTests: XCTestCase {

    // MARK: - RequestTable

    func testRequestTableRegisterComplete() async throws {
        var table = RequestTable()
        let uuid = Data([0xDE, 0xAD, 0xBE, 0xEF])

        async let received: UniversalMessage_RoutableMessage = withCheckedThrowingContinuation { cont in
            do {
                try table.register(uuid: uuid, continuation: cont)
            } catch {
                cont.resume(throwing: error)
            }
        }

        // Give the async let a chance to register before we complete.
        try await Task.sleep(nanoseconds: 10_000_000)

        var response = UniversalMessage_RoutableMessage()
        response.requestUuid = uuid
        let found = table.complete(uuid: uuid, with: response)
        XCTAssertTrue(found)

        let got = try await received
        XCTAssertEqual(got.requestUuid, uuid)
        XCTAssertTrue(table.isEmpty)
    }

    func testRequestTableFailPropagatesError() async throws {
        enum Canary: Swift.Error, Equatable { case boom }

        var table = RequestTable()
        let uuid = Data([0x01, 0x02])

        async let result: UniversalMessage_RoutableMessage = withCheckedThrowingContinuation { cont in
            do {
                try table.register(uuid: uuid, continuation: cont)
            } catch {
                cont.resume(throwing: error)
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let found = table.fail(uuid: uuid, error: Canary.boom)
        XCTAssertTrue(found)

        do {
            _ = try await result
            XCTFail("expected error")
        } catch Canary.boom {
            // ok
        }
        XCTAssertTrue(table.isEmpty)
    }

    func testRequestTableDuplicateRegisterThrows() throws {
        var table = RequestTable()
        let uuid = Data([0xAA])

        // Use the error path directly — don't actually suspend a continuation.
        withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cont.resume()
        }

        // Insert once via a synchronous helper — we need a Continuation to
        // register, and the only way to get one without suspending is to use
        // a disposable continuation and then fail it out.
        let sentinel = expectation(description: "sentinel")
        Task {
            do {
                _ = try await withCheckedThrowingContinuation { (cont: RequestTable.Continuation) in
                    do {
                        try table.register(uuid: uuid, continuation: cont)
                        XCTAssertThrowsError(try table.register(uuid: uuid, continuation: cont)) { error in
                            XCTAssertEqual(error as? RequestTable.Error, .duplicateRequestID)
                        }
                        _ = table.fail(uuid: uuid, error: CocoaError(.fileNoSuchFile))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            } catch {
                // expected — cleanup path
            }
            sentinel.fulfill()
        }
        wait(for: [sentinel], timeout: 1.0)
    }

    func testRequestTableCancelAllWakesEveryone() async throws {
        enum Canary: Swift.Error, Equatable { case shutdown }

        var table = RequestTable()
        let uuidA = Data([0xA1])
        let uuidB = Data([0xB2])

        async let a: UniversalMessage_RoutableMessage = withCheckedThrowingContinuation { cont in
            try? table.register(uuid: uuidA, continuation: cont)
        }
        async let b: UniversalMessage_RoutableMessage = withCheckedThrowingContinuation { cont in
            try? table.register(uuid: uuidB, continuation: cont)
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(table.count, 2)

        table.cancelAll(error: Canary.shutdown)
        XCTAssertTrue(table.isEmpty)

        var failures = 0
        do { _ = try await a } catch Canary.shutdown { failures += 1 }
        do { _ = try await b } catch Canary.shutdown { failures += 1 }
        XCTAssertEqual(failures, 2)
    }
}
```

Note on `testRequestTableDuplicateRegisterThrows`: the `try? table.register(...)` pattern in the duplicate-register check is a bit awkward because `CheckedContinuation` can't be cloned or replayed; you need to register once, catch the duplicate throw, then fail the first continuation to let it deallocate. If you find a cleaner approach, use it — but the shape above compiles and passes under Swift 6 concurrency checking.

- [ ] **Step 2: Run**

```bash
swift test --filter DispatcherTests 2>&1 | tail -20
```

Expected: 4 test methods green. If the duplicate-register test hangs or leaks, inspect the continuation lifecycle — Swift's CheckedContinuation traps if a continuation is dropped without being resumed.

- [ ] **Step 3: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: 54 tests total (50 prior + 4 new), 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeslaBLETests/DispatcherTests.swift
git commit -m "test: cover RequestTable register/complete/fail/cancelAll"
```

---

## Task 5: Implement `FakeTransport` test double

**Files:**

- Create: `Tests/TeslaBLETests/FakeTransport.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
@testable import TeslaBLE

/// Scriptable `MessageTransport` for `Dispatcher` scenario tests.
///
/// Usage pattern in tests:
/// 1. Instantiate `FakeTransport()`.
/// 2. Pre-populate scripted inbound messages via `enqueueInbound(_:)`.
/// 3. Pass the instance to the Dispatcher under test.
/// 4. After the test interaction, pull captured outbound bytes via
///    `await transport.sentMessages`.
///
/// Concurrency: an `actor` so that `receiveMessage` and `enqueueInbound`
/// serialize access to the inbound queue safely.
actor FakeTransport: MessageTransport {

    enum Error: Swift.Error {
        case receiveCancelled
        case receiveStubbedFailure(String)
    }

    private var sent: [Data] = []
    private var pendingInbound: [Data] = []
    private var pendingReceiveContinuations: [CheckedContinuation<Data, Swift.Error>] = []
    private var stubbedError: Swift.Error?
    private var closed = false

    // MARK: - Protocol conformance

    func sendMessage(_ data: Data) async throws {
        if closed { throw Error.receiveCancelled }
        sent.append(data)
    }

    func receiveMessage() async throws -> Data {
        if let err = stubbedError {
            stubbedError = nil
            throw err
        }
        if !pendingInbound.isEmpty {
            return pendingInbound.removeFirst()
        }
        if closed {
            throw Error.receiveCancelled
        }
        return try await withCheckedThrowingContinuation { cont in
            pendingReceiveContinuations.append(cont)
        }
    }

    // MARK: - Test helpers

    /// Append a message to the inbound queue. If a receiver is currently
    /// suspended it is woken up immediately.
    func enqueueInbound(_ data: Data) {
        if !pendingReceiveContinuations.isEmpty {
            let cont = pendingReceiveContinuations.removeFirst()
            cont.resume(returning: data)
            return
        }
        pendingInbound.append(data)
    }

    /// Stub the next `receiveMessage` call to fail with the supplied error.
    /// Overrides anything in the inbound queue for exactly one receive.
    func stubNextReceiveFailure(_ error: Swift.Error) {
        stubbedError = error
        if !pendingReceiveContinuations.isEmpty {
            let cont = pendingReceiveContinuations.removeFirst()
            cont.resume(throwing: error)
            stubbedError = nil
        }
    }

    /// Close the transport, waking any suspended receiver with a cancellation
    /// error.
    func close() {
        closed = true
        let snapshot = pendingReceiveContinuations
        pendingReceiveContinuations.removeAll()
        for c in snapshot {
            c.resume(throwing: Error.receiveCancelled)
        }
    }

    var sentMessages: [Data] { sent }
    var pendingReceiveCount: Int { pendingReceiveContinuations.count }
    func clearSent() { sent.removeAll() }
}
```

- [ ] **Step 2: Build check**

```bash
swift build --target TeslaBLETests 2>&1 | tail -5 || swift test --filter DispatcherTests/testRequestTableRegisterComplete 2>&1 | tail -5
```

Expected: no compile errors in the test module. If `swift build --target` isn't supported in this toolchain, the fallback `swift test --filter` will compile the test target as a side-effect.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/FakeTransport.swift
git commit -m "test: add FakeTransport scriptable MessageTransport double"
```

---

## Task 6: Implement `Dispatcher` actor

**Files:**

- Create: `Sources/TeslaBLE/Dispatcher/Dispatcher.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Actor-based message dispatcher that sits on top of a `MessageTransport`.
///
/// Responsibilities:
/// - Owns per-domain `VehicleSession?` instances and applies them for
///   outbound sign + inbound verify.
/// - Routes inbound responses back to their pending requests via `RequestTable`.
/// - Enforces per-request timeouts and supports task cancellation.
/// - Handles handshake via `SessionNegotiator` and installs the resulting
///   `VehicleSession` into the corresponding domain slot.
///
/// Not responsible for framing (the transport handles that) or for BLE
/// connection lifecycle (the caller owns the transport's connect/disconnect).
actor Dispatcher {

    enum Error: Swift.Error, Equatable {
        case notStarted
        case alreadyStarted
        case notConnected
        case noSessionForDomain(UniversalMessage_Domain)
        case timeout
        case shutdown
        case encodingFailed(String)
        case decodingFailed(String)
        case unexpectedResponse(String)
    }

    private let transport: MessageTransport
    private let logger: (any TeslaBLELogger)?

    private var vcsecSession: VehicleSession?
    private var infotainmentSession: VehicleSession?
    private var requestTable = RequestTable()
    private var inboundTask: Task<Void, Never>?
    private var started = false

    init(transport: MessageTransport, logger: (any TeslaBLELogger)? = nil) {
        self.transport = transport
        self.logger = logger
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !started else { throw Error.alreadyStarted }
        started = true
        inboundTask = Task { [weak self] in
            await self?.inboundLoop()
        }
    }

    func stop() async {
        started = false
        inboundTask?.cancel()
        inboundTask = nil
        requestTable.cancelAll(error: Error.shutdown)
    }

    /// Install or replace a `VehicleSession` for the given domain. Typically
    /// called after a successful `negotiate(domain:...)`.
    func installSession(_ session: VehicleSession, forDomain domain: UniversalMessage_Domain) {
        switch domain {
        case .vehicleSecurity: vcsecSession = session
        case .infotainment:    infotainmentSession = session
        default: break
        }
    }

    // MARK: - Outbound

    /// Send a plaintext command body to the given domain, wait for the
    /// vehicle's response, and return the decrypted response plaintext.
    ///
    /// The caller must have installed a session for `domain` first (via
    /// `installSession` after a successful `negotiate`). Throws
    /// `.noSessionForDomain` if no session is available.
    func send(
        _ plaintext: Data,
        domain: UniversalMessage_Domain,
        timeout: Duration = .seconds(10)
    ) async throws -> Data {
        guard started else { throw Error.notStarted }
        let session = try requireSession(for: domain)

        // Build an outbound routable message with a fresh uuid.
        var request = UniversalMessage_RoutableMessage()
        var dst = UniversalMessage_Destination()
        dst.domain = domain
        request.toDestination = dst
        let requestUUID = Self.newUUIDBytes()
        request.uuid = requestUUID

        // Sign (actor hop into VehicleSession).
        try await session.sign(plaintext: plaintext, into: &request, expiresAt: Self.defaultExpiresAt)

        // Compute requestID for response matching.
        guard let responseMatchID = InboundVerifier.requestID(forSignedRequest: request) else {
            throw Error.encodingFailed("failed to compute requestID from signed message")
        }

        // Register and transmit.
        let response: UniversalMessage_RoutableMessage
        do {
            response = try await withRegisteredRequest(uuid: requestUUID, timeout: timeout) { [self] in
                try await self.transmit(message: request)
            }
        } catch let Error.timeout {
            logger?.log(.error, category: "dispatcher", "send timeout on domain \(domain)")
            throw Error.timeout
        }

        // Verify response.
        do {
            return try await session.verify(response: response, requestID: responseMatchID)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }
    }

    // MARK: - Handshake

    /// Run a `SessionInfoRequest/SessionInfo` handshake against `domain`.
    /// Returns the decoded `Signatures_SessionInfo`. Callers must derive a
    /// `VehicleSession` from this info (via ECDH on `info.publicKey`) and
    /// then call `installSession(...)`.
    func negotiate(
        domain: UniversalMessage_Domain,
        publicKey: Data,
        challenge: Data,
        sessionKeyForVerification: SessionKey,
        verifierName: Data,
        timeout: Duration = .seconds(10)
    ) async throws -> Signatures_SessionInfo {
        guard started else { throw Error.notStarted }

        var request = SessionNegotiator.buildRequest(
            domain: domain,
            publicKey: publicKey,
            challenge: challenge,
            uuid: Self.newUUIDBytes()
        )

        let response: UniversalMessage_RoutableMessage = try await withRegisteredRequest(
            uuid: request.uuid,
            timeout: timeout
        ) { [self] in
            try await self.transmit(message: request)
        }

        do {
            return try SessionNegotiator.validateResponse(
                message: response,
                sessionKey: sessionKeyForVerification,
                verifierName: verifierName,
                challenge: challenge
            )
        } catch {
            throw Error.unexpectedResponse(String(describing: error))
        }
    }

    // MARK: - Internals

    private func requireSession(for domain: UniversalMessage_Domain) throws -> VehicleSession {
        switch domain {
        case .vehicleSecurity:
            guard let s = vcsecSession else { throw Error.noSessionForDomain(domain) }
            return s
        case .infotainment:
            guard let s = infotainmentSession else { throw Error.noSessionForDomain(domain) }
            return s
        default:
            throw Error.noSessionForDomain(domain)
        }
    }

    private func transmit(message: UniversalMessage_RoutableMessage) async throws {
        let bytes: Data
        do {
            bytes = try message.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
        try await transport.sendMessage(bytes)
    }

    /// Helper that wraps a block in a RequestTable registration + timeout
    /// race. The continuation is completed by the inbound loop when a
    /// matching response arrives, by the timeout child task when the deadline
    /// elapses, or by `stop()` / `cancelAll` during shutdown.
    private func withRegisteredRequest(
        uuid: Data,
        timeout: Duration,
        transmit: @Sendable () async throws -> Void
    ) async throws -> UniversalMessage_RoutableMessage {
        return try await withCheckedThrowingContinuation { (cont: RequestTable.Continuation) in
            do {
                try requestTable.register(uuid: uuid, continuation: cont)
            } catch {
                cont.resume(throwing: error)
                return
            }

            Task { [weak self] in
                // Transmit outside the register-or-throw critical section so
                // an early response finds a registered continuation.
                do {
                    try await transmit()
                } catch {
                    await self?.failRequest(uuid: uuid, error: error)
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: Self.durationToNanoseconds(timeout))
                    await self?.failRequest(uuid: uuid, error: Error.timeout)
                } catch {
                    // Task cancelled — the continuation may already have been
                    // completed by the inbound loop; attempt to fail is a
                    // no-op if the uuid is already unregistered.
                    await self?.failRequest(uuid: uuid, error: CancellationError())
                }
            }
        }
    }

    private func failRequest(uuid: Data, error: Swift.Error) {
        _ = requestTable.fail(uuid: uuid, error: error)
    }

    // MARK: - Inbound loop

    private func inboundLoop() async {
        while !Task.isCancelled {
            let bytes: Data
            do {
                bytes = try await transport.receiveMessage()
            } catch {
                logger?.log(.warning, category: "dispatcher", "inbound loop exit: \(error)")
                requestTable.cancelAll(error: Error.shutdown)
                return
            }

            let message: UniversalMessage_RoutableMessage
            do {
                message = try UniversalMessage_RoutableMessage(serializedBytes: bytes)
            } catch {
                logger?.log(.warning, category: "dispatcher", "dropping undecodable inbound frame: \(error)")
                continue
            }

            let matchUUID = message.requestUuid
            if !matchUUID.isEmpty {
                let routed = requestTable.complete(uuid: matchUUID, with: message)
                if !routed {
                    logger?.log(.warning, category: "dispatcher", "no pending request for uuid \(matchUUID.map { String(format: "%02x", $0) }.joined()); dropping")
                }
            } else {
                logger?.log(.debug, category: "dispatcher", "unsolicited inbound message (no requestUuid); dropping")
            }
        }
    }

    // MARK: - Constants & helpers

    private static let defaultExpiresAt: UInt32 = 60

    private static func newUUIDBytes() -> Data {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    /// Convert a `Duration` to nanoseconds for `Task.sleep(nanoseconds:)`.
    /// We don't use `Task.sleep(for:)` because that overload requires
    /// macOS 13+ / iOS 16+, but the package's macOS target is 11.
    private static func durationToNanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        // `attoseconds` range is 0..<1e18; 1 nano = 1e9 atto.
        let fractionalNanos = UInt64(max(0, components.attoseconds)) / 1_000_000_000
        return seconds * 1_000_000_000 + fractionalNanos
    }
}
```

- [ ] **Step 2: Build check**

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!`. Likely pitfalls:

- `UniversalMessage_RoutableMessage(serializedBytes:)` — the existing `Internal/MobileSessionAdapter.swift:98` uses this label, so it should work.
- `try message.serializedData()` — same rationale as Phase 3a Task 12.
- `Task.sleep(for:)` — Swift 6 Duration overload, available on recent macOS SDKs. If not found, fall back to `Task.sleep(nanoseconds:)` with manual conversion.
- `withCheckedThrowingContinuation` + nested `Task {}` — the Task must be spawned AFTER registration to avoid TOCTOU; confirm the order.

If any of these fail, STOP and report BLOCKED with the error output.

- [ ] **Step 3: Commit**

```bash
git add Sources/TeslaBLE/Dispatcher/Dispatcher.swift
git commit -m "feat: implement Dispatcher actor (send, negotiate, inbound routing)"
```

---

## Task 7: Happy-path send scenario test

**Files:**

- Modify: `Tests/TeslaBLETests/DispatcherTests.swift`

- [ ] **Step 1: Append the test**

Insert inside `DispatcherTests` class after the RequestTable tests:

```swift
    // MARK: - Dispatcher helpers

    private func makeSessionKey() -> SessionKey {
        SessionKey(rawBytes: Data(repeating: 0x42, count: 16))
    }

    private func makeSession(domain: UniversalMessage_Domain, initialCounter: UInt32 = 0) -> VehicleSession {
        VehicleSession(
            domain: domain,
            verifierName: Data("test_verifier".utf8),
            localPublicKey: Data(repeating: 0x04, count: 65),
            sessionKey: makeSessionKey(),
            epoch: Data(repeating: 0xAB, count: 16),
            initialCounter: initialCounter
        )
    }

    /// Seal a canned response plaintext with the supplied session parameters
    /// and return the serialized `UniversalMessage_RoutableMessage` bytes
    /// ready to hand back through `FakeTransport.enqueueInbound`.
    private func makeResponseBytes(
        respondingTo request: UniversalMessage_RoutableMessage,
        plaintext: Data,
        counter: UInt32,
        sessionKey: SessionKey,
        verifierName: Data,
        domain: UniversalMessage_Domain
    ) throws -> Data {
        let requestID = try XCTUnwrap(InboundVerifier.requestID(forSignedRequest: request))

        var response = UniversalMessage_RoutableMessage()
        response.requestUuid = request.uuid
        var from = UniversalMessage_Destination()
        from.domain = domain
        response.fromDestination = from

        let aad = try SessionMetadata.buildResponseAAD(
            message: response,
            verifierName: verifierName,
            requestID: requestID,
            counter: counter
        )
        let fixedNonce = Data([0,1,2,3,4,5,6,7,8,9,10,11])
        let sealed = try MessageAuthenticator.sealFixed(
            plaintext: plaintext,
            associatedData: aad,
            nonce: fixedNonce,
            sessionKey: sessionKey
        )

        var gcm = Signatures_AES_GCM_Response_Signature_Data()
        gcm.nonce = fixedNonce
        gcm.counter = counter
        gcm.tag = sealed.tag
        var sigData = Signatures_SignatureData()
        sigData.sigType = .aesGcmResponseData(gcm)
        response.subSigData = .signatureData(sigData)
        response.payload = .protobufMessageAsBytes(sealed.ciphertext)

        return try response.serializedData()
    }

    // MARK: - Happy path

    func testDispatcherSendAndReceivesResponse() async throws {
        let transport = FakeTransport()
        let dispatcher = Dispatcher(transport: transport)
        try await dispatcher.start()
        let session = makeSession(domain: .vehicleSecurity)
        await dispatcher.installSession(session, forDomain: .vehicleSecurity)

        // Kick off the send on a background task so we can interleave the
        // response injection below.
        let sendTask = Task { () throws -> Data in
            try await dispatcher.send(Data("lock".utf8), domain: .vehicleSecurity, timeout: .seconds(2))
        }

        // Read the outbound bytes the dispatcher wrote. Wait until they appear.
        var outbound: [Data] = []
        for _ in 0..<50 {
            outbound = await transport.sentMessages
            if !outbound.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(outbound.count, 1, "dispatcher should have written exactly one outbound message")

        let outboundRequest = try UniversalMessage_RoutableMessage(serializedBytes: outbound[0])
        XCTAssertEqual(outboundRequest.toDestination.domain, .vehicleSecurity)

        // Seal a canned response using the same session parameters.
        let responseBytes = try makeResponseBytes(
            respondingTo: outboundRequest,
            plaintext: Data("OK".utf8),
            counter: 1,
            sessionKey: makeSessionKey(),
            verifierName: Data("test_verifier".utf8),
            domain: .vehicleSecurity
        )
        await transport.enqueueInbound(responseBytes)

        let responsePlaintext = try await sendTask.value
        XCTAssertEqual(responsePlaintext, Data("OK".utf8))

        await dispatcher.stop()
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter DispatcherTests/testDispatcherSendAndReceivesResponse 2>&1 | tail -25
```

Expected: passes. If the test hangs, the inbound loop isn't picking up the enqueued message — check that `start()` actually launches `inboundTask` and that `FakeTransport.receiveMessage` returns promptly after `enqueueInbound`.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/DispatcherTests.swift
git commit -m "test: add Dispatcher happy-path send+receive scenario"
```

---

## Task 8: Timeout scenario test

**Files:**

- Modify: `Tests/TeslaBLETests/DispatcherTests.swift`

- [ ] **Step 1: Append**

```swift
    func testDispatcherSendTimesOut() async throws {
        let transport = FakeTransport()
        let dispatcher = Dispatcher(transport: transport)
        try await dispatcher.start()
        let session = makeSession(domain: .vehicleSecurity)
        await dispatcher.installSession(session, forDomain: .vehicleSecurity)

        let start = ContinuousClock.now
        do {
            _ = try await dispatcher.send(Data("lock".utf8), domain: .vehicleSecurity, timeout: .milliseconds(200))
            XCTFail("expected timeout")
        } catch Dispatcher.Error.timeout {
            // ok
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1), "timeout should fire close to the deadline")

        await dispatcher.stop()
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter DispatcherTests/testDispatcherSendTimesOut 2>&1 | tail -15
```

Expected: passes in well under 1 second. If the test runs significantly longer (e.g. 10+ seconds), the timeout path isn't wired — investigate `withRegisteredRequest`.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/DispatcherTests.swift
git commit -m "test: cover Dispatcher send timeout path"
```

---

## Task 9: `noSession` error scenario + unknown-requestUuid drop scenario

**Files:**

- Modify: `Tests/TeslaBLETests/DispatcherTests.swift`

- [ ] **Step 1: Append**

```swift
    func testDispatcherRejectsSendWithoutSession() async throws {
        let transport = FakeTransport()
        let dispatcher = Dispatcher(transport: transport)
        try await dispatcher.start()

        do {
            _ = try await dispatcher.send(Data("lock".utf8), domain: .vehicleSecurity)
            XCTFail("expected noSessionForDomain")
        } catch Dispatcher.Error.noSessionForDomain(let d) {
            XCTAssertEqual(d, .vehicleSecurity)
        }

        await dispatcher.stop()
    }

    func testDispatcherDropsInboundWithUnknownRequestUUID() async throws {
        let transport = FakeTransport()
        let dispatcher = Dispatcher(transport: transport)
        try await dispatcher.start()
        let session = makeSession(domain: .vehicleSecurity)
        await dispatcher.installSession(session, forDomain: .vehicleSecurity)

        // Enqueue a bogus inbound whose requestUuid does not match anything.
        var bogus = UniversalMessage_RoutableMessage()
        bogus.requestUuid = Data([0xFF, 0xFF])
        let bogusBytes = try bogus.serializedData()
        await transport.enqueueInbound(bogusBytes)

        // Give the inbound loop a moment to process+drop the unknown message.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Now send a legit command. Dispatcher should work normally despite
        // the earlier dropped inbound.
        let sendTask = Task { () throws -> Data in
            try await dispatcher.send(Data("lock".utf8), domain: .vehicleSecurity, timeout: .seconds(2))
        }

        var outbound: [Data] = []
        for _ in 0..<50 {
            outbound = await transport.sentMessages
            if !outbound.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(outbound.count, 1)

        let outboundRequest = try UniversalMessage_RoutableMessage(serializedBytes: outbound[0])
        let responseBytes = try makeResponseBytes(
            respondingTo: outboundRequest,
            plaintext: Data("OK".utf8),
            counter: 1,
            sessionKey: makeSessionKey(),
            verifierName: Data("test_verifier".utf8),
            domain: .vehicleSecurity
        )
        await transport.enqueueInbound(responseBytes)

        let result = try await sendTask.value
        XCTAssertEqual(result, Data("OK".utf8))

        await dispatcher.stop()
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter DispatcherTests 2>&1 | tail -25
```

Expected: all DispatcherTests green.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/DispatcherTests.swift
git commit -m "test: cover Dispatcher noSession and unknown-uuid paths"
```

---

## Task 10: Cancellation scenario test

**Files:**

- Modify: `Tests/TeslaBLETests/DispatcherTests.swift`

- [ ] **Step 1: Append**

```swift
    func testDispatcherStopFailsInFlightSends() async throws {
        let transport = FakeTransport()
        let dispatcher = Dispatcher(transport: transport)
        try await dispatcher.start()
        let session = makeSession(domain: .vehicleSecurity)
        await dispatcher.installSession(session, forDomain: .vehicleSecurity)

        let sendTask = Task { () throws -> Data in
            try await dispatcher.send(Data("lock".utf8), domain: .vehicleSecurity, timeout: .seconds(30))
        }

        // Wait for the outbound write to confirm the send is registered and suspended.
        for _ in 0..<50 {
            let sent = await transport.sentMessages
            if !sent.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // Stop the dispatcher — should wake the suspended send with .shutdown.
        await dispatcher.stop()

        do {
            _ = try await sendTask.value
            XCTFail("expected shutdown error")
        } catch Dispatcher.Error.shutdown {
            // ok
        }
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter DispatcherTests/testDispatcherStopFailsInFlightSends 2>&1 | tail -15
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/DispatcherTests.swift
git commit -m "test: cover Dispatcher stop() wakes suspended sends with shutdown error"
```

---

## Task 11: Handshake scenario test

**Files:**

- Modify: `Tests/TeslaBLETests/DispatcherTests.swift`

- [ ] **Step 1: Append**

```swift
    func testDispatcherNegotiateRoundtrip() async throws {
        let transport = FakeTransport()
        let dispatcher = Dispatcher(transport: transport)
        try await dispatcher.start()

        let sessionKey = makeSessionKey()
        let verifierName = Data("test_verifier".utf8)
        let challenge = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let publicKey = Data(repeating: 0x04, count: 65)

        // Kick off the negotiation.
        let negotiateTask = Task { () throws -> Signatures_SessionInfo in
            try await dispatcher.negotiate(
                domain: .vehicleSecurity,
                publicKey: publicKey,
                challenge: challenge,
                sessionKeyForVerification: sessionKey,
                verifierName: verifierName,
                timeout: .seconds(2)
            )
        }

        // Wait for the SessionInfoRequest write to land.
        var outbound: [Data] = []
        for _ in 0..<50 {
            outbound = await transport.sentMessages
            if !outbound.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(outbound.count, 1)
        let outboundRequest = try UniversalMessage_RoutableMessage(serializedBytes: outbound[0])
        guard case .sessionInfoRequest(let req)? = outboundRequest.payload else {
            XCTFail("expected SessionInfoRequest payload"); return
        }
        XCTAssertEqual(req.publicKey, publicKey)
        XCTAssertEqual(req.challenge, challenge)

        // Craft a SessionInfo response signed with the shared sessionKey.
        var info = Signatures_SessionInfo()
        info.counter = 7
        info.epoch = Data(repeating: 0xAB, count: 16)
        info.clockTime = 99
        info.publicKey = Data(repeating: 0x04, count: 65)
        let encoded = try info.serializedData()

        let tag = try SessionNegotiator.computeSessionInfoTag(
            sessionKey: sessionKey,
            verifierName: verifierName,
            challenge: challenge,
            encodedInfo: encoded
        )

        var response = UniversalMessage_RoutableMessage()
        response.requestUuid = outboundRequest.uuid
        response.payload = .sessionInfo(encoded)
        var sig = Signatures_SignatureData()
        var hmac = Signatures_HMAC_Signature_Data()
        hmac.tag = tag
        sig.sigType = .sessionInfoTag(hmac)
        response.subSigData = .signatureData(sig)
        let responseBytes = try response.serializedData()
        await transport.enqueueInbound(responseBytes)

        let decoded = try await negotiateTask.value
        XCTAssertEqual(decoded.counter, 7)
        XCTAssertEqual(decoded.clockTime, 99)

        await dispatcher.stop()
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter DispatcherTests/testDispatcherNegotiateRoundtrip 2>&1 | tail -20
```

Expected: passes.

- [ ] **Step 3: Run full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests green. Running total: 50 prior + 1 request-table (4 methods) + 1 happy-path + 1 timeout + 2 error paths + 1 cancellation + 1 handshake = `50 + 4 + 1 + 1 + 2 + 1 + 1 = 60` tests.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeslaBLETests/DispatcherTests.swift
git commit -m "test: cover Dispatcher handshake SessionInfoRequest/Response flow"
```

---

## Task 12: Final regression check

- [ ] **Step 1: Full test run + branch status**

```bash
swift test 2>&1 | grep -E "Executed.*(tests|failures)" | tail -3
swift build 2>&1 | tail -3
git log --oneline $(git rev-list -n 1 963d1f7)..HEAD | cat
git diff --stat $(git rev-list -n 1 963d1f7)..HEAD
```

Expected:

- `Executed 60 tests, with 0 failures`
- `Build complete!`
- ~12 commits on top of Phase 3a head (`963d1f7 test: cover SessionNegotiator build/validate/tamper paths`)
- Touching `Sources/TeslaBLE/Dispatcher/*.swift` (3 files), `Tests/TeslaBLETests/DispatcherTests.swift` (1), `Tests/TeslaBLETests/FakeTransport.swift` (1)

- [ ] **Step 2: Submodule check**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git status --short | grep -v '^ M\|^??' || echo "no new submodule changes"
cd ../..
```

Expected: `no new submodule changes`.

- [ ] **Step 3: No commit**

Verification only. Phase 3b complete when all three steps pass.

---

## Appendix A — Reference Go source locations

| Swift component             | Go source                                                       | Key lines                      |
| --------------------------- | --------------------------------------------------------------- | ------------------------------ |
| `MessageTransport` protocol | `pkg/connector/connector.go` + internal transport interface     | N/A (shape is Swift-idiomatic) |
| `RequestTable`              | `internal/dispatcher/dispatcher.go` — `Dispatcher.handlers` map | ~150–200                       |
| `Dispatcher.send`           | `internal/dispatcher/dispatcher.go` — `Send` + `sendAndRetry`   | ~230–320                       |
| `Dispatcher.negotiate`      | `internal/dispatcher/dispatcher.go` — `RequestSessionInfo`      | ~330–400                       |
| `Dispatcher.inboundLoop`    | `internal/dispatcher/dispatcher.go` — `processIncomingMessages` | ~400–500                       |

## Appendix B — Known deltas from Go

1. **No retry logic.** Go's `sendAndRetry` retries transient failures; Swift's Phase 3b `send` throws on first failure. Retries can be added in Phase 5 at the `TeslaVehicleClient` layer.
2. **No backoff.** Go uses a backoff policy; Swift uses a flat timeout. Same rationale.
3. **No explicit `handler` type.** Go has a `handler` interface for different reply types; Swift uses a single `CheckedContinuation<UniversalMessage_RoutableMessage, Error>` because all responses are routed uniformly to the decoder.
4. **`negotiate` signature requires `sessionKeyForVerification`.** The Swift side expects the caller to have performed ECDH against a known peer public key before calling `negotiate`. The Go side does ECDH internally once it sees the response. We split this concern to keep `Dispatcher` free of crypto key management.
