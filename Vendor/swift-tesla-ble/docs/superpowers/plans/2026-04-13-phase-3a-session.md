# Swift Native Rewrite — Phase 3a: Session Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `internal/authentication/signer.go` + `verifier.go` to Swift as the `Session/` layer — pure metadata-AAD helpers, a stateless outbound signer, a stateless inbound verifier, and a stateful `VehicleSession` actor that holds per-domain counter / epoch / replay state. Validate against fixture-dumped AAD bytes from Go and a Swift-side sign→verify roundtrip.

**Architecture:** This plan is Phase 3a of the rewrite described in `docs/superpowers/specs/2026-04-13-swift-native-rewrite-design.md`. Phase 2 delivered `Crypto/` (P256ECDH, SessionKey, CounterWindow, MetadataHash, MessageAuthenticator) with 40 tests green. Phase 3a adds five source files under `Sources/TeslaBLE/Session/` plus extended fixture coverage for the AAD construction paths. No `Dispatcher/` work yet — that is Phase 3b.

**Tech Stack:** Swift 6, CryptoKit (already used), SwiftProtobuf (already wired), Foundation. No new SwiftPM dependencies. Fixture extraction reuses the Go dump patch from Phase 0 and the `fixture_dump` build tag.

**Wire-critical invariants (memorize):**

1. **Signing-path AAD TLV order (from `peer.go extractMetadata` + `signer.go encryptWithCounter`)**: `TAG_SIGNATURE_TYPE(=5, AES_GCM_PERSONALIZED)` → `TAG_DOMAIN(=domain byte from message.ToDestination)` → `TAG_PERSONALIZATION(=verifierName)` → `TAG_EPOCH(=16 bytes)` → `TAG_EXPIRES_AT(=u32 BE)` → `TAG_COUNTER(=u32 BE)` → `TAG_FLAGS(=u32 BE, only added if message.flags > 0)`. Terminator: `TAG_END (0xff)` + empty message. Then `SHA256.finalize()` → 32-byte AAD.
2. **Response-path AAD TLV order (from `peer.go responseMetadata`)**: `TAG_SIGNATURE_TYPE(=9, AES_GCM_RESPONSE)` → `TAG_DOMAIN(=domain byte from message.FromDestination)` → `TAG_PERSONALIZATION(=verifierName)` → `TAG_COUNTER` → `TAG_FLAGS(=u32 BE, ALWAYS added, even if 0 — this differs from signing path)` → `TAG_REQUEST_HASH(=id bytes)` → `TAG_FAULT(=u32 BE of signedMessageStatus.signedMessageFault)`. Terminator: `TAG_END` + empty message.
3. **Request-ID bytes for response matching (from `peer.go RequestID`)**: for AES-GCM responses, id is `[SIGNATURE_TYPE_AES_GCM_PERSONALIZED (=5)] || signerGCMData.tag`. For HMAC-personalized responses, id is `[SIGNATURE_TYPE_HMAC_PERSONALIZED (=8)] || tag[0..<16 for VCSEC | full tag for other domains]`.
4. **Nonce size**: 12 bytes (CryptoKit default; already enforced by `MessageAuthenticator`). Signer generates random nonce; responder echoes with its own random nonce.
5. **Epoch length**: 16 bytes. Counter max: `0xFFFFFFFF`. Window size: 32 bits (from Phase 2 `CounterWindow.windowSize`).
6. **ExpiresAt**: seconds since signer's `timeZero`, clamped by caller. For Phase 3a tests we use a fixed literal value (e.g. 60). The actual clock arithmetic lives in `VehicleSession` but the stateless helpers take `expiresAt` as a caller-supplied `UInt32`.
7. **Domain enum raw values** (from `Sources/TeslaBLE/Generated/universal_message.pb.swift:28-62`): `broadcast = 0`, `vehicleSecurity = 2`, `infotainment = 3`.
8. **Signing test fixtures**: deterministic scalars and verifier name from `peer_test.go:16-57`. Verifier scalar (32 bytes hex):
   ```
   72e9a493ba41e792b10427433110 5fa6c908c27f15913eecc2f4ec11 5b281ae0
   ```
   Signer scalar (32 bytes hex):
   ```
   4807e29d46425d07df48193249a6 241d411ac4007375c75d5d4a22ec f189cdde
   ```
   Both should be concatenated with no whitespace when used in fixtures. The test plaintext is `"hello world"` (11 bytes ASCII). The test verifierName is `"test_verifier"` (13 bytes ASCII). The test domain is `vehicleSecurity` (=2). The test challenge is the 8-byte sequence `0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07`.

**What NOT to do in this plan:**

- Do NOT touch `Sources/TeslaBLE/Client/`, `Internal/MobileSessionAdapter.swift`, or `Transport/BLETransportBridge.swift`. Those continue to drive the legacy xcframework path until Phase 5.
- Do NOT create `Sources/TeslaBLE/Dispatcher/` files yet. That's Phase 3b.
- Do NOT modify `Package.swift`. The test target's `Fixtures/` resource copy is already wired.
- Do NOT delete `Vendor/tesla-vehicle-command`. Submodule stays intact.
- Do NOT refactor Phase 2's `Crypto/` files. If a bug surfaces there, stop and report it — don't silently patch.

---

## File Structure

### Files to create

**Source — Swift `Session/` layer (implementation):**

- `Sources/TeslaBLE/Session/SessionMetadata.swift` — ~140 lines. Pure functions: `buildSigningAAD(...)` and `buildResponseAAD(...)`. No CryptoKit state, no actors — just TLV assembly via `MetadataHash.sha256Context()`.
- `Sources/TeslaBLE/Session/OutboundSigner.swift` — ~130 lines. Stateless `signGCM(plaintext:message:sessionKey:verifierName:epoch:counter:expiresAt:)` that seals the plaintext with a random nonce, builds the signing AAD, and mutates a `UniversalMessage_RoutableMessage` to embed the signed envelope (`Signatures_AES_GCM_Personalized_Signature_Data`).
- `Sources/TeslaBLE/Session/InboundVerifier.swift` — ~140 lines. Stateless `openGCMResponse(message:sessionKey:verifierName:requestID:)` that extracts the `Signatures_AES_GCM_Response_Signature_Data`, builds the response AAD, opens the ciphertext, and returns `(counter, plaintext)`. Also exposes `requestID(for: routable) -> Data` to produce the matching id bytes.
- `Sources/TeslaBLE/Session/VehicleSession.swift` — ~170 lines. `actor VehicleSession` holding `{ sessionKey, epoch, verifierName, domain, counterOut, window: CounterWindow, clockOffset }`. Methods: `sign(plaintext:into:expiresIn:) throws` (auto-increments counter, calls `OutboundSigner`), `verify(response:) throws -> Data` (calls `InboundVerifier`, then pushes counter through window). First-cut clock: seconds-since-init stored as `Date`.
- `Sources/TeslaBLE/Session/SessionNegotiator.swift` — ~120 lines. Stateless helpers to build a `UniversalMessage_RoutableMessage` containing a `SessionInfoRequest` for a given domain + local public key, and to validate a `Signatures_SessionInfo` response (check HMAC via `MetadataHash.hmacContext(sessionKey:label:"session info")` + `peer.SessionInfoHMAC` TLV shape).

**Test — layer B (partial — AAD coverage + roundtrip + VehicleSession state):**

- `Tests/TeslaBLETests/SessionTests.swift` — ~400 lines. Fixture-driven AAD tests, Swift-side sign→verify roundtrip tests, and VehicleSession state-transition tests.
- `Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json` — 3 cases, generated from extended Go dump patch.
- `Tests/TeslaBLETests/Fixtures/session/response_aad_vectors.json` — 3 cases, generated.

### Files to modify

- `GoPatches/fixture-dump.patch` — extend with two new `TestDump*AAD` functions appended to the existing `fixture_dump_test.go`. Regenerate the saved patch.

### Files to leave alone

- Everything under `Sources/TeslaBLE/Client/`, `Internal/`, `Transport/`, `Keys/`, `Model/`, `Support/`, `Crypto/`, `Generated/`.
- `Package.swift`.
- `Vendor/tesla-vehicle-command/*` (read-only reference + temporary fixture dump run).

### Branching and commit cadence

Work continues on `dev` branch (no new branch per operator instruction in Phase 0+2). Every task ends with an explicit commit. Prefer small commits; split within a task if it runs long.

---

## Task 1: Extend the Go fixture-dump patch with AAD dumps

Add two new test functions to the temporary Go fixture_dump file, run them, save the extended patch, revert submodule.

**Files:**

- Create (temporary): `Vendor/tesla-vehicle-command/internal/authentication/fixture_dump_test.go` (applied from existing `GoPatches/fixture-dump.patch`, then extended with new functions)
- Modify: `GoPatches/fixture-dump.patch` (regenerated to include the new functions)
- Create: `Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json`
- Create: `Tests/TeslaBLETests/Fixtures/session/response_aad_vectors.json`

- [ ] **Step 1: Apply the existing Phase 0 patch as the starting point**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git apply ../../GoPatches/fixture-dump.patch
ls internal/authentication/fixture_dump_test.go
cd ../..
```

Expected: the file appears.

- [ ] **Step 2: Append the two new dump functions**

Edit `Vendor/tesla-vehicle-command/internal/authentication/fixture_dump_test.go`. Append these functions at the end of the file (after the existing `TestDumpGCMRoundtrip`):

```go
// TestDumpSigningAAD emits the signing-path metadata AAD bytes (the 32-byte
// SHA256 checksum fed to AES-GCM Seal as authenticatedData) for a set of
// deterministic RoutableMessage + signer-state inputs.
func TestDumpSigningAAD(t *testing.T) {
	if os.Getenv("DUMP") != "1" {
		t.Skip("set DUMP=1 to run")
	}
	type caseOut struct {
		Name           string `json:"name"`
		Domain         uint32 `json:"domain"`
		VerifierNameHex string `json:"verifierNameHex"`
		EpochHex       string `json:"epochHex"`
		ExpiresAt      uint32 `json:"expiresAt"`
		Counter        uint32 `json:"counter"`
		Flags          uint32 `json:"flags"`
		ExpectedAADHex string `json:"expectedAadHex"`
	}

	type caseIn struct {
		name     string
		domain   universal.Domain
		verifier []byte
		epoch    []byte
		expires  uint32
		counter  uint32
		flags    uint32
	}

	inputs := []caseIn{
		{
			name:     "vcsec_counter1_no_flags",
			domain:   universal.Domain_DOMAIN_VEHICLE_SECURITY,
			verifier: []byte("test_verifier"),
			epoch:    []byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef},
			expires:  60,
			counter:  1,
			flags:    0,
		},
		{
			name:     "infotainment_counter100_with_flags",
			domain:   universal.Domain_DOMAIN_INFOTAINMENT,
			verifier: []byte("5YJ3E1EA4JF000001"),
			epoch:    []byte{0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99},
			expires:  300,
			counter:  100,
			flags:    0x0001,
		},
		{
			name:     "vcsec_maxcounter",
			domain:   universal.Domain_DOMAIN_VEHICLE_SECURITY,
			verifier: []byte("test_verifier"),
			epoch:    []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
			expires:  1,
			counter:  0xFFFFFFFE,
			flags:    0,
		},
	}

	var cases []interface{}
	for _, in := range inputs {
		msg := &universal.RoutableMessage{
			ToDestination: &universal.Destination{
				SubDestination: &universal.Destination_Domain{Domain: in.domain},
			},
			Payload: &universal.RoutableMessage_ProtobufMessageAsBytes{
				ProtobufMessageAsBytes: []byte("hello world"),
			},
			Flags: in.flags,
		}
		gcmData := &signatures.AES_GCM_Personalized_Signature_Data{
			Epoch:     append([]byte{}, in.epoch...),
			Counter:   in.counter,
			ExpiresAt: in.expires,
		}
		peer := Peer{
			verifierName: in.verifier,
		}
		copy(peer.epoch[:], in.epoch)
		meta := newMetadata()
		if err := peer.extractMetadata(meta, msg, gcmData, signatures.SignatureType_SIGNATURE_TYPE_AES_GCM_PERSONALIZED); err != nil {
			t.Fatalf("%s: extractMetadata: %s", in.name, err)
		}
		sum := meta.Checksum(nil)
		cases = append(cases, caseOut{
			Name:            in.name,
			Domain:          uint32(in.domain),
			VerifierNameHex: hex.EncodeToString(in.verifier),
			EpochHex:        hex.EncodeToString(in.epoch),
			ExpiresAt:       in.expires,
			Counter:         in.counter,
			Flags:           in.flags,
			ExpectedAADHex:  hex.EncodeToString(sum),
		})
	}

	writeJSON(t, filepath.Join(outputDir(t), "../session/signing_aad_vectors.json"), jsonFile{
		Description: "Signing-path AAD (SHA256 checksum over TLV metadata) per peer.extractMetadata",
		Cases:       cases,
	})
}

// TestDumpResponseAAD emits the response-path AAD bytes (the 32-byte SHA256
// checksum fed to AES-GCM Open when verifying a vehicle response).
func TestDumpResponseAAD(t *testing.T) {
	if os.Getenv("DUMP") != "1" {
		t.Skip("set DUMP=1 to run")
	}
	type caseOut struct {
		Name            string `json:"name"`
		FromDomain      uint32 `json:"fromDomain"`
		VerifierNameHex string `json:"verifierNameHex"`
		RequestIDHex    string `json:"requestIdHex"`
		Counter         uint32 `json:"counter"`
		Flags           uint32 `json:"flags"`
		FaultCode       uint32 `json:"faultCode"`
		ExpectedAADHex  string `json:"expectedAadHex"`
	}

	type caseIn struct {
		name      string
		from      universal.Domain
		verifier  []byte
		id        []byte
		counter   uint32
		flags     uint32
		faultCode universal.MessageFault_E
	}

	inputs := []caseIn{
		{
			name:     "vcsec_response_counter1",
			from:     universal.Domain_DOMAIN_VEHICLE_SECURITY,
			verifier: []byte("test_verifier"),
			id:       []byte{byte(signatures.SignatureType_SIGNATURE_TYPE_AES_GCM_PERSONALIZED), 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f},
			counter:  1,
			flags:    0,
			faultCode: universal.MessageFault_E_MESSAGEFAULT_ERROR_NONE,
		},
		{
			name:     "infotainment_response_with_fault",
			from:     universal.Domain_DOMAIN_INFOTAINMENT,
			verifier: []byte("5YJ3E1EA4JF000001"),
			id:       []byte{byte(signatures.SignatureType_SIGNATURE_TYPE_AES_GCM_PERSONALIZED), 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00},
			counter:  42,
			flags:    0x0002,
			faultCode: universal.MessageFault_E_MESSAGEFAULT_ERROR_INVALID_SIGNATURE,
		},
		{
			name:     "vcsec_response_with_flags",
			from:     universal.Domain_DOMAIN_VEHICLE_SECURITY,
			verifier: []byte("test_verifier"),
			id:       []byte{byte(signatures.SignatureType_SIGNATURE_TYPE_HMAC_PERSONALIZED), 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00},
			counter:  7,
			flags:    0x0001,
			faultCode: universal.MessageFault_E_MESSAGEFAULT_ERROR_NONE,
		},
	}

	var cases []interface{}
	for _, in := range inputs {
		msg := &universal.RoutableMessage{
			FromDestination: &universal.Destination{
				SubDestination: &universal.Destination_Domain{Domain: in.from},
			},
			Flags: in.flags,
		}
		if in.faultCode != universal.MessageFault_E_MESSAGEFAULT_ERROR_NONE {
			msg.SignedMessageStatus = &universal.MessageStatus{
				SignedMessageFault: in.faultCode,
			}
		}
		peer := Peer{
			verifierName: in.verifier,
		}
		aad, err := peer.responseMetadata(msg, in.id, in.counter)
		if err != nil {
			t.Fatalf("%s: responseMetadata: %s", in.name, err)
		}
		cases = append(cases, caseOut{
			Name:            in.name,
			FromDomain:      uint32(in.from),
			VerifierNameHex: hex.EncodeToString(in.verifier),
			RequestIDHex:    hex.EncodeToString(in.id),
			Counter:         in.counter,
			Flags:           in.flags,
			FaultCode:       uint32(in.faultCode),
			ExpectedAADHex:  hex.EncodeToString(aad),
		})
	}

	writeJSON(t, filepath.Join(outputDir(t), "../session/response_aad_vectors.json"), jsonFile{
		Description: "Response-path AAD (SHA256 checksum over TLV metadata) per peer.responseMetadata",
		Cases:       cases,
	})
}
```

Note on the `writeJSON` path: `outputDir(t)` returns `$SWIFT_FIXTURES_DIR` which will be set to the crypto/ fixtures directory. The `../session/` relative path writes to the sibling directory. Your Step 3 will create that directory.

- [ ] **Step 3: Create the session/ fixtures directory**

```bash
mkdir -p Tests/TeslaBLETests/Fixtures/session
```

- [ ] **Step 4: Run the extended dump**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
SWIFT_FIXTURES_DIR="$PWD/../../Tests/TeslaBLETests/Fixtures/crypto" \
DUMP=1 \
go test -tags fixture_dump -run 'TestDump.*' ./internal/authentication/ 2>&1 | tail -10
cd ../..
```

Expected: `ok` line from `go test`. Two new files appear in `Tests/TeslaBLETests/Fixtures/session/`. Verify:

```bash
ls Tests/TeslaBLETests/Fixtures/session/
jq '.cases | length' Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json
jq '.cases | length' Tests/TeslaBLETests/Fixtures/session/response_aad_vectors.json
jq -r '.cases[0].expectedAadHex | length' Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json
```

Expected: `3`, `3`, `64`.

Also verify the Phase 0 crypto fixtures are still byte-identical (Task 17 of Phase 0+2 proved the round-trip; this confirms we haven't broken it):

```bash
jq '.cases | length' Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json
```

Expected: `4` (unchanged).

- [ ] **Step 5: Regenerate the saved patch**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git add -N internal/authentication/fixture_dump_test.go
git diff --no-color -- internal/authentication/fixture_dump_test.go > /tmp/fixture-dump.patch
cd ../..
wc -l /tmp/fixture-dump.patch
mv /tmp/fixture-dump.patch GoPatches/fixture-dump.patch
```

Expected: the new patch is larger than the old one (~430+ lines vs 270 lines).

- [ ] **Step 6: Revert the submodule**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git reset HEAD internal/authentication/fixture_dump_test.go 2>/dev/null || true
rm -f internal/authentication/fixture_dump_test.go
git status | head -5
cd ../..
```

Expected: submodule has no new untracked/staged fixture_dump_test.go file.

- [ ] **Step 7: Commit**

```bash
git add Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json
git add Tests/TeslaBLETests/Fixtures/session/response_aad_vectors.json
git add GoPatches/fixture-dump.patch
git commit -m "test: dump session AAD fixtures (signing + response paths)"
git log --oneline -3
```

---

## Task 2: Scaffold Session/ directory

**Files:**

- Create: `Sources/TeslaBLE/Session/.gitkeep`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p Sources/TeslaBLE/Session
touch Sources/TeslaBLE/Session/.gitkeep
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 2: Commit**

```bash
git add Sources/TeslaBLE/Session/.gitkeep
git commit -m "chore: scaffold Session/ directory"
```

---

## Task 3: Failing test for `SessionMetadata.buildSigningAAD` + stub

TDD red step.

**Files:**

- Create: `Tests/TeslaBLETests/SessionTests.swift`
- Create: `Sources/TeslaBLE/Session/SessionMetadata.swift` (stub)

- [ ] **Step 1: Create `SessionTests.swift`**

Create `Tests/TeslaBLETests/SessionTests.swift` with this exact content:

```swift
import Foundation
import XCTest
@testable import TeslaBLE

private extension Data {
    init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }
}

final class SessionTests: XCTestCase {

    // MARK: - Fixture loading

    private func loadJSON<T: Decodable>(_ type: T.Type, named filename: String) throws -> T {
        guard let url = Bundle.module.url(forResource: "Fixtures/session/\(filename)", withExtension: nil) else {
            XCTFail("Missing fixture: Fixtures/session/\(filename)")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Signing AAD

    private struct SigningAADFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let domain: UInt32
            let verifierNameHex: String
            let epochHex: String
            let expiresAt: UInt32
            let counter: UInt32
            let flags: UInt32
            let expectedAadHex: String
        }
    }

    func testSigningAADVectors() throws {
        let fixture = try loadJSON(SigningAADFixture.self, named: "signing_aad_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            var message = UniversalMessage_RoutableMessage()
            var destination = UniversalMessage_Destination()
            destination.domain = UniversalMessage_Domain(rawValue: Int(testCase.domain)) ?? .broadcast
            message.toDestination = destination
            message.flags = testCase.flags

            let verifierName = try XCTUnwrap(Data(hex: testCase.verifierNameHex))
            let epoch = try XCTUnwrap(Data(hex: testCase.epochHex))
            let expectedAAD = try XCTUnwrap(Data(hex: testCase.expectedAadHex))

            let actualAAD = try SessionMetadata.buildSigningAAD(
                message: message,
                verifierName: verifierName,
                epoch: epoch,
                counter: testCase.counter,
                expiresAt: testCase.expiresAt
            )

            XCTAssertEqual(actualAAD, expectedAAD, "[\(testCase.name)] signing AAD mismatch")
        }
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
swift test --filter SessionTests/testSigningAADVectors 2>&1 | tail -15
```

Expected: compile error about `SessionMetadata` not being defined.

- [ ] **Step 3: Create a stub so the test compiles**

Create `Sources/TeslaBLE/Session/SessionMetadata.swift`:

```swift
import Foundation

/// TLV metadata AAD construction for AES-GCM signing and response verification.
/// Intentionally broken stub — Task 4 replaces the body with the correct
/// implementation.
enum SessionMetadata {

    enum Error: Swift.Error, Equatable {
        case invalidDomain
        case tlvBuildFailed
    }

    static func buildSigningAAD(
        message: UniversalMessage_RoutableMessage,
        verifierName: Data,
        epoch: Data,
        counter: UInt32,
        expiresAt: UInt32
    ) throws -> Data {
        // Placeholder — returns empty data so fixture tests fail loudly.
        return Data()
    }
}
```

Remove `.gitkeep`:

```bash
git rm Sources/TeslaBLE/Session/.gitkeep
```

- [ ] **Step 4: Run — expect semantic failure**

```bash
swift test --filter SessionTests/testSigningAADVectors 2>&1 | tail -20
```

Expected: test runs and fails with AAD mismatches across all 3 cases (empty Data vs 32-byte SHA256 digests).

- [ ] **Step 5: Commit**

```bash
git add Tests/TeslaBLETests/SessionTests.swift Sources/TeslaBLE/Session/SessionMetadata.swift
git commit -m "test(wip): add failing signing AAD fixture test + SessionMetadata stub"
```

---

## Task 4: Implement `SessionMetadata.buildSigningAAD` correctly

**Files:**

- Modify: `Sources/TeslaBLE/Session/SessionMetadata.swift`

- [ ] **Step 1: Replace the body**

Rewrite `Sources/TeslaBLE/Session/SessionMetadata.swift` with this content:

```swift
import Foundation

/// TLV metadata AAD construction for AES-GCM signing and response verification.
///
/// Ports `internal/authentication/peer.go extractMetadata` (signing path) and
/// `responseMetadata` (response path). Both produce a 32-byte SHA256 checksum
/// over a TLV-encoded metadata blob. The checksum is then passed to
/// AES-GCM-128 as the Additional Authenticated Data.
enum SessionMetadata {

    enum Error: Swift.Error, Equatable {
        case invalidDomain
        case tlvBuildFailed(String)
    }

    // MARK: - Signing path

    /// Build the AAD for an outbound AES-GCM-PERSONALIZED request. The TLV
    /// order matches `peer.go extractMetadata`:
    ///
    ///     TAG_SIGNATURE_TYPE (=5, AES_GCM_PERSONALIZED)
    ///     TAG_DOMAIN         (=message.toDestination.domain byte)
    ///     TAG_PERSONALIZATION (=verifierName bytes)
    ///     TAG_EPOCH          (=16 bytes)
    ///     TAG_EXPIRES_AT     (=u32 BE)
    ///     TAG_COUNTER        (=u32 BE)
    ///     TAG_FLAGS          (=u32 BE, only added if message.flags > 0)
    ///
    /// Terminated by `TAG_END` + empty message blob.
    static func buildSigningAAD(
        message: UniversalMessage_RoutableMessage,
        verifierName: Data,
        epoch: Data,
        counter: UInt32,
        expiresAt: UInt32
    ) throws -> Data {
        let domain = try domainByte(fromTo: message)

        var builder = MetadataHash.sha256Context()
        do {
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.signatureType.rawValue),
                value: Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)])
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.domain.rawValue),
                value: Data([domain])
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.personalization.rawValue),
                value: verifierName
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.epoch.rawValue),
                value: epoch
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.expiresAt.rawValue),
                value: expiresAt
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.counter.rawValue),
                value: counter
            )
            if message.flags > 0 {
                try builder.addUInt32(
                    tagRaw: UInt8(Signatures_Tag.flags.rawValue),
                    value: message.flags
                )
            }
        } catch {
            throw Error.tlvBuildFailed(String(describing: error))
        }
        return builder.checksum(over: Data())
    }

    // MARK: - Internals

    private static func domainByte(fromTo message: UniversalMessage_RoutableMessage) throws -> UInt8 {
        let raw = message.toDestination.domain.rawValue
        guard raw >= 0, raw <= 255 else {
            throw Error.invalidDomain
        }
        return UInt8(raw)
    }
}
```

- [ ] **Step 2: Run the signing AAD test**

```bash
swift test --filter SessionTests/testSigningAADVectors 2>&1 | tail -20
```

Expected: all 3 cases pass.

If any case fails, the most likely suspect is the TLV order or the flags handling. The `vcsec_counter1_no_flags` case has `flags=0` and must NOT add a TAG_FLAGS entry. The `infotainment_counter100_with_flags` case has `flags=1` and must add TAG_FLAGS with value `0x00000001` (big-endian).

- [ ] **Step 3: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: 40 prior tests + 1 new method = 41 total, all green.

- [ ] **Step 4: Commit**

```bash
git add Sources/TeslaBLE/Session/SessionMetadata.swift
git commit -m "feat: implement SessionMetadata.buildSigningAAD"
```

---

## Task 5: Failing test for `buildResponseAAD` + implementation

**Files:**

- Modify: `Tests/TeslaBLETests/SessionTests.swift`
- Modify: `Sources/TeslaBLE/Session/SessionMetadata.swift`

- [ ] **Step 1: Append the response-AAD test to `SessionTests.swift`**

Insert this block inside `SessionTests` class, after `testSigningAADVectors`:

```swift
    // MARK: - Response AAD

    private struct ResponseAADFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let fromDomain: UInt32
            let verifierNameHex: String
            let requestIdHex: String
            let counter: UInt32
            let flags: UInt32
            let faultCode: UInt32
            let expectedAadHex: String
        }
    }

    func testResponseAADVectors() throws {
        let fixture = try loadJSON(ResponseAADFixture.self, named: "response_aad_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            var message = UniversalMessage_RoutableMessage()
            var from = UniversalMessage_Destination()
            from.domain = UniversalMessage_Domain(rawValue: Int(testCase.fromDomain)) ?? .broadcast
            message.fromDestination = from
            message.flags = testCase.flags
            if testCase.faultCode != 0 {
                var status = UniversalMessage_MessageStatus()
                // Note: the generated enum case for "no error" is `.rrorNone`
                // (codegen quirk — protoc stripped the leading `E` from `ERROR_NONE`).
                status.signedMessageFault = UniversalMessage_MessageFault_E(rawValue: Int(testCase.faultCode)) ?? .rrorNone
                message.signedMessageStatus = status
            }

            let verifierName = try XCTUnwrap(Data(hex: testCase.verifierNameHex))
            let requestID = try XCTUnwrap(Data(hex: testCase.requestIdHex))
            let expectedAAD = try XCTUnwrap(Data(hex: testCase.expectedAadHex))

            let actualAAD = try SessionMetadata.buildResponseAAD(
                message: message,
                verifierName: verifierName,
                requestID: requestID,
                counter: testCase.counter
            )

            XCTAssertEqual(actualAAD, expectedAAD, "[\(testCase.name)] response AAD mismatch")
        }
    }
```

Note on the `UniversalMessage_MessageFault_E` type — verify its actual type name in `Sources/TeslaBLE/Generated/universal_message.pb.swift`; if the generated name differs (e.g., `UniversalMessage_MessageFault`), adjust accordingly. Run `grep "messagefaultErrorNone" Sources/TeslaBLE/Generated/universal_message.pb.swift` to find the type.

- [ ] **Step 2: Run — expect compile failure**

```bash
swift test --filter SessionTests/testResponseAADVectors 2>&1 | tail -15
```

Expected: `buildResponseAAD` undefined.

- [ ] **Step 3: Append `buildResponseAAD` to `SessionMetadata.swift`**

Before the `// MARK: - Internals` section, add:

```swift
    // MARK: - Response path

    /// Build the AAD for verifying a vehicle response (AES-GCM-RESPONSE).
    /// The TLV order matches `peer.go responseMetadata`:
    ///
    ///     TAG_SIGNATURE_TYPE (=9, AES_GCM_RESPONSE)
    ///     TAG_DOMAIN         (=message.fromDestination.domain byte)
    ///     TAG_PERSONALIZATION (=verifierName bytes)
    ///     TAG_COUNTER        (=u32 BE)
    ///     TAG_FLAGS          (=u32 BE, ALWAYS added — differs from signing path)
    ///     TAG_REQUEST_HASH   (=requestID bytes)
    ///     TAG_FAULT          (=u32 BE of signedMessageStatus.signedMessageFault)
    ///
    /// Terminated by `TAG_END` + empty message blob.
    static func buildResponseAAD(
        message: UniversalMessage_RoutableMessage,
        verifierName: Data,
        requestID: Data,
        counter: UInt32
    ) throws -> Data {
        let domain = try domainByte(fromFrom: message)

        var builder = MetadataHash.sha256Context()
        do {
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.signatureType.rawValue),
                value: Data([UInt8(Signatures_SignatureType.aesGcmResponse.rawValue)])
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.domain.rawValue),
                value: Data([domain])
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.personalization.rawValue),
                value: verifierName
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.counter.rawValue),
                value: counter
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.flags.rawValue),
                value: message.flags
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.requestHash.rawValue),
                value: requestID
            )
            let faultRaw = UInt32(message.signedMessageStatus.signedMessageFault.rawValue)
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.fault.rawValue),
                value: faultRaw
            )
        } catch {
            throw Error.tlvBuildFailed(String(describing: error))
        }
        return builder.checksum(over: Data())
    }
```

Also add a second internal helper beside `domainByte(fromTo:)`:

```swift
    private static func domainByte(fromFrom message: UniversalMessage_RoutableMessage) throws -> UInt8 {
        let raw = message.fromDestination.domain.rawValue
        guard raw >= 0, raw <= 255 else {
            throw Error.invalidDomain
        }
        return UInt8(raw)
    }
```

- [ ] **Step 4: Run the response AAD test**

```bash
swift test --filter SessionTests/testResponseAADVectors 2>&1 | tail -20
```

Expected: all 3 cases pass. If `infotainment_response_with_fault` fails but the no-fault cases pass, the fault byte encoding is off — double-check that `faultRaw` reads from `signedMessageStatus.signedMessageFault.rawValue` and matches the Go fixture's `faultCode`.

- [ ] **Step 5: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: 42 tests total, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Tests/TeslaBLETests/SessionTests.swift Sources/TeslaBLE/Session/SessionMetadata.swift
git commit -m "feat: implement SessionMetadata.buildResponseAAD"
```

---

## Task 6: Implement `OutboundSigner.signGCM`

Pure Swift stateless wrapper — builds signing AAD via `SessionMetadata.buildSigningAAD`, seals via `MessageAuthenticator.seal` (random nonce), mutates the `RoutableMessage` to embed the signature data.

**Files:**

- Create: `Sources/TeslaBLE/Session/OutboundSigner.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Outbound signing path — takes a plaintext message body plus signer state,
/// produces a fully-signed `UniversalMessage_RoutableMessage` whose payload is
/// the AES-GCM ciphertext and whose `signatureData` field holds the epoch,
/// counter, nonce, and 16-byte tag.
///
/// Stateless on purpose: the caller (`VehicleSession`) owns the counter,
/// epoch, and session key. This module only wires them into the wire format.
enum OutboundSigner {

    enum Error: Swift.Error, Equatable {
        case metadataFailed(String)
        case sealFailed(String)
    }

    /// Signs and encrypts `plaintext` in-place into `message` using
    /// AES-GCM-PERSONALIZED. The supplied counter and expiresAt are copied
    /// into the gcm signature data; the caller must ensure counter is
    /// monotonically increasing and not repeating.
    static func signGCM(
        plaintext: Data,
        message: inout UniversalMessage_RoutableMessage,
        sessionKey: SessionKey,
        localPublicKey: Data,
        verifierName: Data,
        epoch: Data,
        counter: UInt32,
        expiresAt: UInt32
    ) throws {
        let aad: Data
        do {
            aad = try SessionMetadata.buildSigningAAD(
                message: message,
                verifierName: verifierName,
                epoch: epoch,
                counter: counter,
                expiresAt: expiresAt
            )
        } catch {
            throw Error.metadataFailed(String(describing: error))
        }

        let sealed: (nonce: Data, ciphertext: Data, tag: Data)
        do {
            sealed = try MessageAuthenticator.seal(
                plaintext: plaintext,
                associatedData: aad,
                sessionKey: sessionKey
            )
        } catch {
            throw Error.sealFailed(String(describing: error))
        }

        var gcmData = Signatures_AES_GCM_Personalized_Signature_Data()
        gcmData.epoch = epoch
        gcmData.nonce = sealed.nonce
        gcmData.counter = counter
        gcmData.expiresAt = expiresAt
        gcmData.tag = sealed.tag

        var identity = Signatures_KeyIdentity()
        identity.publicKey = localPublicKey

        var sigData = Signatures_SignatureData()
        sigData.signerIdentity = identity
        sigData.sigType = .aesGcmPersonalizedData(gcmData)

        message.subSigData = .signatureData(sigData)
        message.payload = .protobufMessageAsBytes(sealed.ciphertext)
    }
}
```

- [ ] **Step 2: Run `swift build`**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. If `Signatures_KeyIdentity` doesn't expose a `publicKey` field in the shape above, inspect `Sources/TeslaBLE/Generated/signatures.pb.swift` — the oneof is `identityType` with case `.publicKey(Data)`. If so, replace `identity.publicKey = localPublicKey` with `identity.identityType = .publicKey(localPublicKey)`.

- [ ] **Step 3: Commit**

```bash
git add Sources/TeslaBLE/Session/OutboundSigner.swift
git commit -m "feat: implement OutboundSigner.signGCM (stateless AES-GCM envelope)"
```

---

## Task 7: Implement `InboundVerifier.openGCMResponse` + requestID helper

**Files:**

- Create: `Sources/TeslaBLE/Session/InboundVerifier.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Inbound verification path — extracts the response signature data from a
/// `UniversalMessage_RoutableMessage`, builds the response AAD via
/// `SessionMetadata.buildResponseAAD`, opens the AES-GCM sealed payload, and
/// returns (counter, plaintext).
///
/// Like `OutboundSigner`, this is stateless. The caller (`VehicleSession`)
/// feeds the returned counter through its `CounterWindow`.
enum InboundVerifier {

    enum Error: Swift.Error, Equatable {
        case missingSignatureData
        case notAnAESGCMResponse
        case missingPayload
        case metadataFailed(String)
        case openFailed(String)
        case authenticationFailure
    }

    /// Compute the request-ID bytes used to match a response to its request.
    /// Port of `peer.go RequestID`.
    ///
    /// For AES-GCM responses: `[SIGNATURE_TYPE_AES_GCM_PERSONALIZED (=5)]`
    /// followed by the request's signer-side 16-byte GCM tag.
    ///
    /// For HMAC-personalized responses, the full tag is used for
    /// non-VCSEC domains; for VCSEC the tag is truncated to 16 bytes.
    static func requestID(forSignedRequest request: UniversalMessage_RoutableMessage) -> Data? {
        guard case .signatureData(let sigData)? = request.subSigData else { return nil }
        switch sigData.sigType {
        case .aesGcmPersonalizedData(let gcm):
            return Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]) + gcm.tag
        case .hmacPersonalizedData(let hm):
            var tag = hm.tag
            if request.toDestination.domain == .vehicleSecurity, tag.count > 16 {
                tag = tag.prefix(16)
            }
            return Data([UInt8(Signatures_SignatureType.hmacPersonalized.rawValue)]) + tag
        default:
            return nil
        }
    }

    /// Open a response message and return the decoded plaintext and counter.
    /// The `requestID` parameter is produced by `requestID(forSignedRequest:)`
    /// on the original outbound message that elicited this response.
    static func openGCMResponse(
        message: UniversalMessage_RoutableMessage,
        sessionKey: SessionKey,
        verifierName: Data,
        requestID: Data
    ) throws -> (counter: UInt32, plaintext: Data) {
        guard case .signatureData(let sigData)? = message.subSigData else {
            throw Error.missingSignatureData
        }
        guard case .aesGcmResponseData(let gcmResponse)? = sigData.sigType else {
            throw Error.notAnAESGCMResponse
        }
        guard case .protobufMessageAsBytes(let ciphertext)? = message.payload else {
            throw Error.missingPayload
        }

        let aad: Data
        do {
            aad = try SessionMetadata.buildResponseAAD(
                message: message,
                verifierName: verifierName,
                requestID: requestID,
                counter: gcmResponse.counter
            )
        } catch {
            throw Error.metadataFailed(String(describing: error))
        }

        do {
            let plaintext = try MessageAuthenticator.open(
                ciphertext: ciphertext,
                tag: gcmResponse.tag,
                nonce: gcmResponse.nonce,
                associatedData: aad,
                sessionKey: sessionKey
            )
            return (gcmResponse.counter, plaintext)
        } catch MessageAuthenticator.Error.authenticationFailure {
            throw Error.authenticationFailure
        } catch {
            throw Error.openFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 2: Run `swift build`**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/TeslaBLE/Session/InboundVerifier.swift
git commit -m "feat: implement InboundVerifier.openGCMResponse and requestID"
```

---

## Task 8: Swift-side sign→verify round-trip test

Integration test: build a plaintext request, sign it with `OutboundSigner`, pretend the "vehicle" is really a local echo that swaps the envelope to a response, verify it with `InboundVerifier`, confirm plaintext matches.

For this test we simulate the response side in pure Swift. Since Swift IS the responder in a Phase 5 reversal test scenario (we don't have a Go fake vehicle here), we use the same primitives (`MessageAuthenticator.sealFixed` + `SessionMetadata.buildResponseAAD`) to stand in for the vehicle.

**Files:**

- Modify: `Tests/TeslaBLETests/SessionTests.swift`

- [ ] **Step 1: Append the roundtrip test**

Insert inside `SessionTests` class after `testResponseAADVectors`:

```swift
    // MARK: - Round-trip sign/verify

    func testSignAndVerifyRoundtrip() throws {
        // Fixed deterministic session key and identity.
        let sessionKey = SessionKey(rawBytes: Data(repeating: 0x42, count: 16))
        let verifierName = Data("test_verifier".utf8)
        let epoch = Data(repeating: 0xAB, count: 16)
        let counter: UInt32 = 1
        let expiresAt: UInt32 = 60
        let localPublic = Data(repeating: 0x04, count: 65)

        // Build an outbound VCSEC request.
        var request = UniversalMessage_RoutableMessage()
        var dst = UniversalMessage_Destination()
        dst.domain = .vehicleSecurity
        request.toDestination = dst
        request.uuid = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let plaintext = Data("lock command".utf8)
        try OutboundSigner.signGCM(
            plaintext: plaintext,
            message: &request,
            sessionKey: sessionKey,
            localPublicKey: localPublic,
            verifierName: verifierName,
            epoch: epoch,
            counter: counter,
            expiresAt: expiresAt
        )

        // Assert the envelope is well-formed.
        guard case .signatureData(let sigData)? = request.subSigData else {
            XCTFail("request missing signature data"); return
        }
        guard case .aesGcmPersonalizedData(let gcm) = sigData.sigType else {
            XCTFail("wrong signature type"); return
        }
        XCTAssertEqual(gcm.epoch, epoch)
        XCTAssertEqual(gcm.counter, counter)
        XCTAssertEqual(gcm.expiresAt, expiresAt)
        XCTAssertEqual(gcm.nonce.count, 12)
        XCTAssertEqual(gcm.tag.count, 16)

        // Now pretend to be the vehicle: construct a response that echoes the
        // request's request-id, sealing a different plaintext with a fresh
        // deterministic nonce.
        let requestID = try XCTUnwrap(InboundVerifier.requestID(forSignedRequest: request))
        XCTAssertEqual(requestID.first, UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue))
        XCTAssertEqual(requestID.count, 17, "requestID = [type_byte] + 16-byte GCM tag")

        let responseCounter: UInt32 = 1
        let responsePlaintext = Data("OK".utf8)

        var response = UniversalMessage_RoutableMessage()
        var from = UniversalMessage_Destination()
        from.domain = .vehicleSecurity
        response.fromDestination = from
        response.requestUuid = request.uuid

        let responseAAD = try SessionMetadata.buildResponseAAD(
            message: response,
            verifierName: verifierName,
            requestID: requestID,
            counter: responseCounter
        )
        let fixedNonce = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b])
        let responseSealed = try MessageAuthenticator.sealFixed(
            plaintext: responsePlaintext,
            associatedData: responseAAD,
            nonce: fixedNonce,
            sessionKey: sessionKey
        )
        var responseGCM = Signatures_AES_GCM_Response_Signature_Data()
        responseGCM.nonce = fixedNonce
        responseGCM.counter = responseCounter
        responseGCM.tag = responseSealed.tag
        var responseSigData = Signatures_SignatureData()
        responseSigData.sigType = .aesGcmResponseData(responseGCM)
        response.subSigData = .signatureData(responseSigData)
        response.payload = .protobufMessageAsBytes(responseSealed.ciphertext)

        // Verify with InboundVerifier.
        let opened = try InboundVerifier.openGCMResponse(
            message: response,
            sessionKey: sessionKey,
            verifierName: verifierName,
            requestID: requestID
        )
        XCTAssertEqual(opened.counter, responseCounter)
        XCTAssertEqual(opened.plaintext, responsePlaintext)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SessionTests/testSignAndVerifyRoundtrip 2>&1 | tail -20
```

Expected: test passes. If opening fails with `authenticationFailure`, the most likely cause is a mismatched AAD — the signing and verifying sides must both use `buildResponseAAD` with the same inputs. Check `requestID`, `counter`, `verifierName`, and `fromDestination.domain`.

- [ ] **Step 3: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: 43 tests total, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeslaBLETests/SessionTests.swift
git commit -m "test: add Swift sign->verify roundtrip integration check"
```

---

## Task 9: Implement `VehicleSession` actor

Stateful wrapper: owns the session key, epoch, counter, and replay window for one BLE domain. Exposes `sign(into:plaintext:expiresIn:)` and `verify(response:requestID:)` that delegate to the stateless helpers plus do counter management.

**Files:**

- Create: `Sources/TeslaBLE/Session/VehicleSession.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Stateful wrapper around the stateless sign/verify helpers. One instance per
/// BLE domain (VCSEC, INFOTAINMENT). Owns:
///
/// - the session key derived from ECDH
/// - the current epoch (16 bytes) advertised by the vehicle
/// - the verifier name (VIN or VCSEC id, used as personalization)
/// - the outbound counter (monotonically increasing)
/// - a replay window over the inbound counter
/// - the local public key (echoed into signerIdentity)
///
/// Concurrency: `actor` so multiple commands can be dispatched without racing
/// on the counter state.
actor VehicleSession {

    enum Error: Swift.Error, Equatable {
        case counterRollover
        case signFailed(String)
        case verifyFailed(String)
        case replayRejected
    }

    let domain: UniversalMessage_Domain
    let verifierName: Data
    let localPublicKey: Data
    let sessionKey: SessionKey

    private var epoch: Data
    private var counter: UInt32
    private var window: CounterWindow

    init(
        domain: UniversalMessage_Domain,
        verifierName: Data,
        localPublicKey: Data,
        sessionKey: SessionKey,
        epoch: Data,
        initialCounter: UInt32 = 0
    ) {
        self.domain = domain
        self.verifierName = verifierName
        self.localPublicKey = localPublicKey
        self.sessionKey = sessionKey
        self.epoch = epoch
        self.counter = initialCounter
        self.window = CounterWindow()
    }

    /// Outbound sign: increments counter, seals plaintext into message.
    func sign(
        plaintext: Data,
        into message: inout UniversalMessage_RoutableMessage,
        expiresAt: UInt32
    ) throws {
        if counter == UInt32.max {
            throw Error.counterRollover
        }
        counter &+= 1
        do {
            try OutboundSigner.signGCM(
                plaintext: plaintext,
                message: &message,
                sessionKey: sessionKey,
                localPublicKey: localPublicKey,
                verifierName: verifierName,
                epoch: epoch,
                counter: counter,
                expiresAt: expiresAt
            )
        } catch {
            // Rollback counter so the next attempt reuses the same value.
            counter &-= 1
            throw Error.signFailed(String(describing: error))
        }
    }

    /// Inbound verify: extracts plaintext + counter, runs counter through the
    /// replay window, returns plaintext on success.
    func verify(
        response: UniversalMessage_RoutableMessage,
        requestID: Data
    ) throws -> Data {
        let result: (counter: UInt32, plaintext: Data)
        do {
            result = try InboundVerifier.openGCMResponse(
                message: response,
                sessionKey: sessionKey,
                verifierName: verifierName,
                requestID: requestID
            )
        } catch {
            throw Error.verifyFailed(String(describing: error))
        }

        // Counter=0 responses bypass the replay window (see verifier.go
        // verifySessionInfo — some responses intentionally allow out-of-order
        // delivery). We treat 0 as "do not track".
        if result.counter > 0 {
            guard window.accept(result.counter) else {
                throw Error.replayRejected
            }
        }
        return result.plaintext
    }

    /// Update the session's epoch and counter to match a fresh SessionInfo
    /// received from the vehicle (e.g. after an error-triggered resync).
    func resync(epoch: Data, counter: UInt32) {
        self.epoch = epoch
        self.counter = counter
        self.window = CounterWindow()
    }

    /// Test-only accessors.
    #if DEBUG
    var currentCounter: UInt32 { counter }
    var currentEpoch: Data { epoch }
    #endif
}
```

- [ ] **Step 2: Build check**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. If `CounterWindow.init()` can't be called without arguments, check Phase 2's `CounterWindow.swift` — it should have a default-argument init.

- [ ] **Step 3: Commit**

```bash
git add Sources/TeslaBLE/Session/VehicleSession.swift
git commit -m "feat: implement VehicleSession actor (per-domain state)"
```

---

## Task 10: `VehicleSession` state-transition tests

**Files:**

- Modify: `Tests/TeslaBLETests/SessionTests.swift`

- [ ] **Step 1: Append tests**

Insert inside `SessionTests` after the roundtrip test:

```swift
    // MARK: - VehicleSession state transitions

    private func makeTestSession(initialCounter: UInt32 = 0) -> VehicleSession {
        VehicleSession(
            domain: .vehicleSecurity,
            verifierName: Data("test_verifier".utf8),
            localPublicKey: Data(repeating: 0x04, count: 65),
            sessionKey: SessionKey(rawBytes: Data(repeating: 0x42, count: 16)),
            epoch: Data(repeating: 0xAB, count: 16),
            initialCounter: initialCounter
        )
    }

    private func makeVCSECRequest() -> UniversalMessage_RoutableMessage {
        var m = UniversalMessage_RoutableMessage()
        var d = UniversalMessage_Destination()
        d.domain = .vehicleSecurity
        m.toDestination = d
        return m
    }

    func testVehicleSessionSignIncrementsCounter() async throws {
        let session = makeTestSession(initialCounter: 10)
        var message = makeVCSECRequest()
        try await session.sign(plaintext: Data("a".utf8), into: &message, expiresAt: 60)

        #if DEBUG
        let counterAfter = await session.currentCounter
        XCTAssertEqual(counterAfter, 11, "counter must increment by 1 per sign")
        #endif

        guard case .signatureData(let s)? = message.subSigData,
              case .aesGcmPersonalizedData(let gcm) = s.sigType else {
            XCTFail("missing envelope"); return
        }
        XCTAssertEqual(gcm.counter, 11)
    }

    func testVehicleSessionCounterRolloverThrows() async throws {
        let session = makeTestSession(initialCounter: UInt32.max)
        var message = makeVCSECRequest()
        do {
            try await session.sign(plaintext: Data("a".utf8), into: &message, expiresAt: 60)
            XCTFail("expected rollover throw")
        } catch VehicleSession.Error.counterRollover {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testVehicleSessionVerifyReplayIsRejected() async throws {
        let session = makeTestSession()

        // Construct a signed request we'll later use as the "request" for
        // requestID computation.
        var request = makeVCSECRequest()
        try await session.sign(plaintext: Data("req".utf8), into: &request, expiresAt: 60)
        let requestID = try XCTUnwrap(InboundVerifier.requestID(forSignedRequest: request))

        // Fabricate a response sealed by the same session key.
        let responseCounter: UInt32 = 5
        var response = UniversalMessage_RoutableMessage()
        var from = UniversalMessage_Destination()
        from.domain = .vehicleSecurity
        response.fromDestination = from
        let aad = try SessionMetadata.buildResponseAAD(
            message: response,
            verifierName: Data("test_verifier".utf8),
            requestID: requestID,
            counter: responseCounter
        )
        let nonce = Data([0,1,2,3,4,5,6,7,8,9,10,11])
        let sealed = try MessageAuthenticator.sealFixed(
            plaintext: Data("OK".utf8),
            associatedData: aad,
            nonce: nonce,
            sessionKey: SessionKey(rawBytes: Data(repeating: 0x42, count: 16))
        )
        var gcm = Signatures_AES_GCM_Response_Signature_Data()
        gcm.nonce = nonce
        gcm.counter = responseCounter
        gcm.tag = sealed.tag
        var sigData = Signatures_SignatureData()
        sigData.sigType = .aesGcmResponseData(gcm)
        response.subSigData = .signatureData(sigData)
        response.payload = .protobufMessageAsBytes(sealed.ciphertext)

        // First verify succeeds.
        let plaintext = try await session.verify(response: response, requestID: requestID)
        XCTAssertEqual(plaintext, Data("OK".utf8))

        // Second verify with the same counter must be rejected as replay.
        do {
            _ = try await session.verify(response: response, requestID: requestID)
            XCTFail("expected replay rejection")
        } catch VehicleSession.Error.replayRejected {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testVehicleSessionResyncResetsState() async {
        let session = makeTestSession(initialCounter: 50)
        let newEpoch = Data(repeating: 0xCD, count: 16)
        await session.resync(epoch: newEpoch, counter: 0)

        #if DEBUG
        let c = await session.currentCounter
        let e = await session.currentEpoch
        XCTAssertEqual(c, 0)
        XCTAssertEqual(e, newEpoch)
        #endif
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SessionTests 2>&1 | tail -25
```

Expected: all 7 SessionTests methods green (4 AAD / roundtrip + 3 state transition = wait, let me recount: testSigningAADVectors, testResponseAADVectors, testSignAndVerifyRoundtrip, testVehicleSessionSignIncrementsCounter, testVehicleSessionCounterRolloverThrows, testVehicleSessionVerifyReplayIsRejected, testVehicleSessionResyncResetsState = 7 methods).

- [ ] **Step 3: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: 47 tests total, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeslaBLETests/SessionTests.swift
git commit -m "test: cover VehicleSession counter, rollover, replay, and resync"
```

---

## Task 11: Implement `SessionNegotiator`

Stateless helpers for building a `SessionInfoRequest` routable message and for validating the vehicle's `SessionInfo` response HMAC.

**Files:**

- Create: `Sources/TeslaBLE/Session/SessionNegotiator.swift`

- [ ] **Step 1: Read the generated `SessionInfoRequest` type**

Before writing code, run:

```bash
grep -A 10 "public struct UniversalMessage_SessionInfoRequest" Sources/TeslaBLE/Generated/universal_message.pb.swift
```

Confirm the field layout. The Go equivalent has `PublicKey []byte` and `Challenge []byte`. The generated Swift struct should expose `publicKey: Data` and `challenge: Data`.

- [ ] **Step 2: Create the file**

```swift
import Foundation

/// Handshake helpers — construct a `SessionInfoRequest` to send over BLE and
/// validate the vehicle's signed `SessionInfo` response.
///
/// The handshake itself is request/response and flows through the normal
/// Dispatcher send path (see Phase 3b). This module only handles the message
/// construction on the outbound side and the HMAC verification on the inbound
/// side.
///
/// Reference: `internal/authentication/native.go SessionInfoHMAC` and
/// `internal/authentication/signer.go UpdateSignedSessionInfo`.
enum SessionNegotiator {

    enum Error: Swift.Error, Equatable {
        case missingPayload
        case wrongSessionType
        case hmacMismatch
        case decodeFailed(String)
    }

    /// Build an outbound `SessionInfoRequest` for the given domain. Caller is
    /// responsible for generating a fresh `challenge` (8 random bytes is
    /// standard — see `getGCMVerifierAndSigner` in peer_test.go).
    static func buildRequest(
        domain: UniversalMessage_Domain,
        publicKey: Data,
        challenge: Data,
        uuid: Data = Data()
    ) -> UniversalMessage_RoutableMessage {
        var request = UniversalMessage_SessionInfoRequest()
        request.publicKey = publicKey
        request.challenge = challenge

        var destination = UniversalMessage_Destination()
        destination.domain = domain

        var message = UniversalMessage_RoutableMessage()
        message.toDestination = destination
        message.uuid = uuid
        message.payload = .sessionInfoRequest(request)
        return message
    }

    /// Validate a vehicle-supplied `SessionInfo` response. Returns the decoded
    /// `Signatures_SessionInfo` on success.
    ///
    /// Verification steps:
    /// 1. Extract the `sessionInfo` payload bytes from the response.
    /// 2. Extract the HMAC tag from the `sessionInfoTag` signature sub-data.
    /// 3. Derive the shared AES key from our private key + the vehicle's
    ///    public key embedded in the response (caller supplies the derived
    ///    `sessionKey` — `SessionNegotiator` does not do ECDH itself).
    /// 4. Recompute `SessionInfoHMAC(verifierName, challenge, encodedInfo)`
    ///    using `MetadataHash.hmacContext(sessionKey:label:"session info")`.
    /// 5. Constant-time compare against the supplied tag.
    /// 6. Decode the protobuf.
    static func validateResponse(
        message: UniversalMessage_RoutableMessage,
        sessionKey: SessionKey,
        verifierName: Data,
        challenge: Data
    ) throws -> Signatures_SessionInfo {
        guard case .sessionInfo(let encodedInfo)? = message.payload else {
            throw Error.missingPayload
        }
        guard case .signatureData(let sigData)? = message.subSigData else {
            throw Error.wrongSessionType
        }
        guard case .sessionInfoTag(let hmacSig)? = sigData.sigType else {
            throw Error.wrongSessionType
        }

        let expectedTag = try computeSessionInfoTag(
            sessionKey: sessionKey,
            verifierName: verifierName,
            challenge: challenge,
            encodedInfo: encodedInfo
        )
        guard Self.constantTimeEqual(expectedTag, hmacSig.tag) else {
            throw Error.hmacMismatch
        }

        do {
            return try Signatures_SessionInfo(serializedBytes: encodedInfo)
        } catch {
            throw Error.decodeFailed(String(describing: error))
        }
    }

    /// Compute the session-info HMAC tag. Exposed for tests.
    static func computeSessionInfoTag(
        sessionKey: SessionKey,
        verifierName: Data,
        challenge: Data,
        encodedInfo: Data
    ) throws -> Data {
        var builder = MetadataHash.hmacContext(sessionKey: sessionKey, label: "session info")
        try builder.add(
            tagRaw: UInt8(Signatures_Tag.signatureType.rawValue),
            value: Data([UInt8(Signatures_SignatureType.hmac.rawValue)])
        )
        try builder.add(
            tagRaw: UInt8(Signatures_Tag.personalization.rawValue),
            value: verifierName
        )
        try builder.add(
            tagRaw: UInt8(Signatures_Tag.challenge.rawValue),
            value: challenge
        )
        return builder.checksum(over: encodedInfo)
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.index(a.startIndex, offsetBy: i)] ^ b[b.index(b.startIndex, offsetBy: i)]
        }
        return diff == 0
    }
}
```

- [ ] **Step 2: Build check**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. `Signatures_SessionInfo` init should accept `serializedBytes:` — that's the API the existing `Sources/TeslaBLE/Internal/MobileSessionAdapter.swift:98` uses and it's confirmed available in the installed SwiftProtobuf version.

- [ ] **Step 3: Commit**

```bash
git add Sources/TeslaBLE/Session/SessionNegotiator.swift
git commit -m "feat: implement SessionNegotiator (request build + HMAC validation)"
```

---

## Task 12: `SessionNegotiator` unit tests

**Files:**

- Modify: `Tests/TeslaBLETests/SessionTests.swift`

- [ ] **Step 1: Append tests**

Insert inside `SessionTests` after the VehicleSession tests:

```swift
    // MARK: - SessionNegotiator

    func testSessionNegotiatorBuildsWellFormedRequest() {
        let publicKey = Data(repeating: 0x04, count: 65)
        let challenge = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let message = SessionNegotiator.buildRequest(
            domain: .vehicleSecurity,
            publicKey: publicKey,
            challenge: challenge,
            uuid: Data([0xDE, 0xAD])
        )
        XCTAssertEqual(message.toDestination.domain, .vehicleSecurity)
        XCTAssertEqual(message.uuid, Data([0xDE, 0xAD]))
        guard case .sessionInfoRequest(let req)? = message.payload else {
            XCTFail("wrong payload"); return
        }
        XCTAssertEqual(req.publicKey, publicKey)
        XCTAssertEqual(req.challenge, challenge)
    }

    func testSessionNegotiatorValidatesGoodResponse() throws {
        let sessionKey = SessionKey(rawBytes: Data(repeating: 0x11, count: 16))
        let verifierName = Data("test_verifier".utf8)
        let challenge = Data([0, 1, 2, 3, 4, 5, 6, 7])

        // Pretend the vehicle serialized a SessionInfo protobuf.
        var info = Signatures_SessionInfo()
        info.counter = 7
        info.publicKey = Data(repeating: 0x04, count: 65)
        info.epoch = Data(repeating: 0xAB, count: 16)
        info.clockTime = 12345
        let encoded = try info.serializedData()

        // Compute the tag we'd expect.
        let expectedTag = try SessionNegotiator.computeSessionInfoTag(
            sessionKey: sessionKey,
            verifierName: verifierName,
            challenge: challenge,
            encodedInfo: encoded
        )

        // Build the response message.
        var response = UniversalMessage_RoutableMessage()
        response.payload = .sessionInfo(encoded)
        var sig = Signatures_SignatureData()
        var hmac = Signatures_HMAC_Signature_Data()
        hmac.tag = expectedTag
        sig.sigType = .sessionInfoTag(hmac)
        response.subSigData = .signatureData(sig)

        let decoded = try SessionNegotiator.validateResponse(
            message: response,
            sessionKey: sessionKey,
            verifierName: verifierName,
            challenge: challenge
        )
        XCTAssertEqual(decoded.counter, 7)
        XCTAssertEqual(decoded.clockTime, 12345)
    }

    func testSessionNegotiatorRejectsTamperedTag() throws {
        let sessionKey = SessionKey(rawBytes: Data(repeating: 0x11, count: 16))
        let verifierName = Data("test_verifier".utf8)
        let challenge = Data([0, 1, 2, 3, 4, 5, 6, 7])

        var info = Signatures_SessionInfo()
        info.counter = 7
        info.epoch = Data(repeating: 0xAB, count: 16)
        let encoded = try info.serializedData()

        var expectedTag = try SessionNegotiator.computeSessionInfoTag(
            sessionKey: sessionKey,
            verifierName: verifierName,
            challenge: challenge,
            encodedInfo: encoded
        )
        expectedTag[0] ^= 0x01  // flip a bit

        var response = UniversalMessage_RoutableMessage()
        response.payload = .sessionInfo(encoded)
        var sig = Signatures_SignatureData()
        var hmac = Signatures_HMAC_Signature_Data()
        hmac.tag = expectedTag
        sig.sigType = .sessionInfoTag(hmac)
        response.subSigData = .signatureData(sig)

        XCTAssertThrowsError(try SessionNegotiator.validateResponse(
            message: response,
            sessionKey: sessionKey,
            verifierName: verifierName,
            challenge: challenge
        )) { error in
            XCTAssertEqual(error as? SessionNegotiator.Error, .hmacMismatch)
        }
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SessionTests 2>&1 | tail -20
```

Expected: 10 methods green (all prior + 3 negotiator tests).

- [ ] **Step 3: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: 50 tests total, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeslaBLETests/SessionTests.swift
git commit -m "test: cover SessionNegotiator build/validate/tamper paths"
```

---

## Task 13: Final regression check + branch status

- [ ] **Step 1: Full test run**

```bash
swift test 2>&1 | tee /tmp/phase3a_final.log | tail -20
grep -i "failed\|error:" /tmp/phase3a_final.log | grep -v "0 failures" || echo "CLEAN"
rm /tmp/phase3a_final.log
```

Expected: `CLEAN` (or only innocuous `0 failures` matches).

- [ ] **Step 2: Swift build**

```bash
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit summary**

```bash
git log --oneline dev | head -20
git diff --stat HEAD~13..HEAD
```

Expected: ~13 commits on top of the Phase 0+2 head, touching:

- `Sources/TeslaBLE/Session/*.swift` — 5 new files
- `Tests/TeslaBLETests/SessionTests.swift` — 1 new file
- `Tests/TeslaBLETests/Fixtures/session/*.json` — 2 new files
- `GoPatches/fixture-dump.patch` — modified (extended)

- [ ] **Step 4: Confirm submodule clean**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git status --short | grep -v '^ M\|^??' || echo "no new submodule changes"
cd ../..
```

Expected: `no new submodule changes` (the pre-existing `M` / `??` drift is unchanged from before).

- [ ] **Step 5: No commit**

Verification only. Phase 3a complete when all five steps pass.

---

## Appendix A — Reference Go source locations

| Swift component                           | Go source                                                                               | Key lines                          |
| ----------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------- |
| `SessionMetadata.buildSigningAAD`         | `internal/authentication/peer.go extractMetadata` + `signer.go encryptWithCounter`      | peer.go 34–71, signer.go 132–165   |
| `SessionMetadata.buildResponseAAD`        | `internal/authentication/peer.go responseMetadata`                                      | 105–117                            |
| `OutboundSigner.signGCM`                  | `internal/authentication/signer.go Encrypt` + `encryptWithCounter`                      | 167–176, 132–165                   |
| `InboundVerifier.openGCMResponse`         | `internal/authentication/signer.go Decrypt`                                             | 219–242                            |
| `InboundVerifier.requestID`               | `internal/authentication/peer.go RequestID`                                             | 82–103                             |
| `VehicleSession`                          | `internal/authentication/signer.go Signer` + `verifier.go Verifier` counter/epoch state | signer.go 17–22, verifier.go 17–73 |
| `SessionNegotiator.computeSessionInfoTag` | `internal/authentication/native.go SessionInfoHMAC`                                     | 76–88                              |
| `SessionNegotiator.validateResponse`      | `internal/authentication/signer.go NewAuthenticatedSigner` + `UpdateSignedSessionInfo`  | 49–62, 117–129                     |

## Appendix B — Known deltas from Go

1. **Nonce generation** lives inside `MessageAuthenticator.seal` (CryptoKit's default random nonce). Go exposes the nonce explicitly on `NativeSession.Encrypt`. The Swift wrapper hides this because the caller never needs to see it before it's written to the protobuf.
2. **`VehicleSession` does not own a clock.** Go's `Signer.Peer` has `timeZero` and uses wall-clock arithmetic for `expiresAt`. The Swift port takes `expiresAt` as a caller-supplied `UInt32`. The caller (Phase 3b Dispatcher or Phase 5 Client) computes it from its own clock. This simplifies tests: we don't have to freeze time.
3. **Response counter = 0 is permitted without replay check.** Matches Go `verifier.go verifySessionInfo` which documents that counter=0 disables the counter check for short-lived out-of-order responses.
4. **No `handle` field** on the Swift side. Go's `Verifier.handle` is used by some higher-level paths; Phase 3a's `VehicleSession` does not need it yet. Phase 3b will add it if dispatcher test cases require it.
5. **No `clockOffset` drift compensation.** Go's `verifier.go adjustClock` corrects monotonic-vs-wallclock skew after sleep. iOS `Task.sleep` uses continuous time; the equivalent correction would be more complex and is deferred. None of the Phase 3a fixtures exercise clock drift.
