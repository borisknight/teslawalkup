# Swift Native Rewrite — Phase 0 + 2: Fixture Extraction & Crypto Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce JSON test-vector fixtures extracted from the Go `tesla-vehicle-command` test suite, then implement the Swift `Crypto/` layer and drive it entirely green against those fixtures.

**Architecture:** This plan is Phase 0 and Phase 2 of the rewrite described in `docs/superpowers/specs/2026-04-13-swift-native-rewrite-design.md`. Phase 0 extracts deterministic test vectors from the Go code via a local patch applied to the vendored submodule. Phase 2 implements `Sources/TeslaBLE/Crypto/` (five files) and a fixture-driven unit test target (`CryptoVectorTests.swift`). All work happens on a new `native-swift` branch. The existing `TeslaCommand.xcframework` build path is left completely alone — new Swift files are added under `Sources/TeslaBLE/Crypto/` but are not yet referenced from `TeslaVehicleClient`, so `swift build` continues to work throughout.

**Tech Stack:** Swift 6, CryptoKit (`P256.KeyAgreement`, `SymmetricKey`, `AES.GCM`, `HMAC<SHA256>`, `Insecure.SHA1`, `SHA256`), SwiftPM (existing), Go 1.21+ (one-shot fixture dump only), `jq` (spot-checking). No new SwiftPM dependencies.

**Wire-compatibility invariants (memorize these — they are the hard part of this plan):**

1. Session key = `SHA1(shared_x_32B_big_endian)[0..<16]`. SHA-1, not SHA-256. First 16 bytes. Non-negotiable — the car expects it.
2. ECDH shared secret = `P-256` scalar multiply, then pad the resulting X coordinate to **exactly 32 bytes** big-endian (`FillBytes` semantics — left-zero-pad short values). CryptoKit's `SharedSecret` is already 32 bytes for P-256, so `.withUnsafeBytes { Data($0) }` works.
3. Metadata TLV bytes are written to a hash context as `[tag_byte][len_byte][value_bytes...]`. Tags must be added in strictly ascending order. Length is a single byte (so value ≤ 255 bytes). The context is terminated by writing the single byte `0xFF` (TAG_END) followed by a "message" blob (sometimes empty), then hashing with `.finalize()` / `Sum(nil)`.
4. Metadata contexts use one of three hash types depending on caller: plain `SHA256` (for AES-GCM AAD and AES-GCM response AAD), `HMAC<SHA256>` keyed with `subkey("authenticated command")` (for `AuthorizeHMAC` tag over VCSEC/HMAC path), or `HMAC<SHA256>` keyed with `subkey("session info")` (for `SessionInfoHMAC` handshake verification). `subkey(label) = HMAC-SHA256(sessionKey, label_utf8_bytes)`.
5. `Signatures_Tag` enum raw values: `signatureType=0`, `domain=1`, `personalization=2`, `epoch=3`, `expiresAt=4`, `counter=5`, `challenge=6`, `flags=7`, `requestHash=8`, `fault=9`, `end=255`. Stored in `Sources/TeslaBLE/Generated/signatures.pb.swift` lines 28–95.
6. `Signatures_SignatureType` raw values: `aesGcm=0`, `aesGcmPersonalized=5`, `hmac=6`, `hmacPersonalized=8`, `aesGcmResponse=9`. Same file, lines 97–130.
7. `expiresAt` and `counter` TLV values are `uint32` **big-endian** 4-byte encodings.
8. The sliding replay window is 32-wide (`windowSize = 32` from `crypto.go` line 21), stored as `uint64`. Bit _i_ tracks whether `counter - (i+1)` has been seen. See §4.1 for the algorithm.

**What NOT to do in this plan:**

- Do not touch `Sources/TeslaBLE/Client/`, `Sources/TeslaBLE/Internal/MobileSessionAdapter.swift`, or `Sources/TeslaBLE/Transport/BLETransportBridge.swift`. They remain in place and continue to drive the xcframework path.
- Do not modify `Package.swift` except to add the `Fixtures` resource copy rule in the existing test target (Task 18).
- Do not delete `Vendor/tesla-vehicle-command` or any Go files. The submodule stays intact for `.proto` files and future fixture regeneration.
- Do not implement `Session/`, `Dispatcher/`, or `Commands/` yet — those are later phases.

---

## File Structure

### Files to create

**Source — Swift `Crypto/` layer (implementation):**

- `Sources/TeslaBLE/Crypto/P256ECDH.swift` — ~80 lines. Thin wrapper over CryptoKit `P256.KeyAgreement.PrivateKey` that produces raw 32-byte shared secrets.
- `Sources/TeslaBLE/Crypto/SessionKey.swift` — ~40 lines. SHA-1 truncation of shared secret → 16-byte AES-GCM-128 key. Wraps `SymmetricKey`.
- `Sources/TeslaBLE/Crypto/CounterWindow.swift` — ~90 lines. Value-semantics sliding-window struct. Direct port of `internal/authentication/window.go`.
- `Sources/TeslaBLE/Crypto/MetadataHash.swift` — ~140 lines. Implements the TLV metadata builder used by every crypto path. Supports three hash contexts: plain SHA256, HMAC-SHA256 with subkey, and SHA256 response path.
- `Sources/TeslaBLE/Crypto/MessageAuthenticator.swift` — ~130 lines. Glue around AES-GCM seal/open plus the specific AAD-construction variants used by signers/verifiers. Exposes `signGCM`, `verifyGCMResponse`, `signHMAC`, `verifySessionInfoHMAC`, and the `subkey` helper.

**Test — layer-A fixture-driven unit tests:**

- `Tests/TeslaBLETests/CryptoVectorTests.swift` — ~350 lines. Parametric fixture runner — one `@Test` or `func testX()` per fixture file, iterating through cases.
- `Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json` — 7 cases (directly transcribed from `window_test.go` lines 17–82).
- `Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json` — 1 case (the `TestCheckSum` case in `metadata_test.go` lines 45–65) plus 4 hand-authored edge cases.
- `Tests/TeslaBLETests/Fixtures/crypto/metadata_hmac_vectors.json` — 2 cases (one signing-path, one session-info-path) generated by the Go dump patch.
- `Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json` — 4 cases generated by the Go dump patch.
- `Tests/TeslaBLETests/Fixtures/crypto/gcm_roundtrip_vectors.json` — 3 cases generated by the Go dump patch.
- `Tests/TeslaBLETests/Fixtures/README.md` — ~20 lines. Brief explanation of fixture format, regeneration instructions, and pointer to `GoPatches/fixture-dump.patch`.

**Patches — one-off fixture extraction tooling (committed alongside fixtures):**

- `GoPatches/fixture-dump.patch` — The unified-diff form of the temporary Go test additions. Saved for future regeneration runs when Tesla updates proto definitions or when new vectors are needed.

### Files to modify

- `Package.swift` — Add `resources: [.copy("Fixtures")]` to the existing `.testTarget` declaration so the JSON files are reachable via `Bundle.module` at test runtime. This is the **only** Package.swift change in this plan.

### Files to leave alone

- Everything under `Sources/TeslaBLE/Client/`, `Internal/`, `Transport/`, `Keys/`, `Model/`, `Support/`, `Generated/`.
- `GoPatches/mobile.go`, `scripts/bootstrap.sh`, `scripts/build-xcframework.sh`, `Vendor/tesla-vehicle-command/` (except the _temporary_ working-tree edits for the Go dump, which are explicitly reverted and saved as a patch).

### Branching and commit cadence

Work is done on a new branch `native-swift`. Every task ends with an explicit commit. A task may contain multiple edits but always ends in exactly one commit unless otherwise noted. Prefer small commits; if a single task runs long, feel free to split the commit but stay within the task boundary.

---

## Task 1: Create the work branch and empty directories

**Files:**

- Create (empty): `Sources/TeslaBLE/Crypto/`
- Create (empty): `Tests/TeslaBLETests/Fixtures/crypto/`

- [ ] **Step 1: Confirm starting state**

Run:

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git status
git rev-parse --abbrev-ref HEAD
```

Expected: working tree clean, branch is `dev` (or `main` depending on caller convention). If not clean, stash or commit existing work before proceeding.

- [ ] **Step 2: Create the work branch**

```bash
git checkout -b native-swift
```

Expected output: `Switched to a new branch 'native-swift'`.

- [ ] **Step 3: Create the empty directories**

Directories in Swift Package Manager don't exist without a file, so create them with `.gitkeep` placeholders. These get deleted in Task 2 and Task 11 when real files arrive — but for this task we just want an explicit "skeleton exists" commit.

```bash
mkdir -p Sources/TeslaBLE/Crypto
mkdir -p Tests/TeslaBLETests/Fixtures/crypto
touch Sources/TeslaBLE/Crypto/.gitkeep
touch Tests/TeslaBLETests/Fixtures/crypto/.gitkeep
```

- [ ] **Step 4: Verify `swift build` still compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!` (or whatever the toolchain's success marker is). The `.gitkeep` files are not Swift sources and `swift build` ignores them.

- [ ] **Step 5: Commit**

```bash
git add Sources/TeslaBLE/Crypto/.gitkeep Tests/TeslaBLETests/Fixtures/crypto/.gitkeep
git commit -m "chore: scaffold Crypto/ and Fixtures/crypto/ directories"
```

---

## Task 2: Write `window_vectors.json` by hand from Go test source

The `window_test.go` cases are already literal-valued test vectors — no Go runtime is needed to extract them. Transcribing them to JSON is the cleanest starting fixture and validates the test-loading plumbing before we touch the Go submodule.

**Files:**

- Create: `Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json`
- Delete: `Tests/TeslaBLETests/Fixtures/crypto/.gitkeep`

- [ ] **Step 1: Re-read the Go source to confirm values**

The canonical cases are in `Vendor/tesla-vehicle-command/internal/authentication/window_test.go` lines 17–82. Each case has five values: `counter`, `window`, `newCounter`, `expectedUpdatedCounter`, `expectedUpdatedWindow`, `expectedOk`. The `window` values are written with `(1<<N) | (1<<M)` style bit-ORs — compute them as plain integers.

Bit math cheat-sheet:

- `(1<<0) | (1<<5) = 0x21` (decimal 33)
- `1 | (1<<1) | (1<<6) = 0x43` (decimal 67)
- `(1<<2) | (1<<3) | (1<<8) = 0x10c` (decimal 268)
- `(1<<0) | (1<<1) | (1<<5) = 0x23` (decimal 35)

- [ ] **Step 2: Write the JSON**

Create `Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json` with this exact content:

```json
{
  "description": "Transcribed from internal/authentication/window_test.go TestSlidingWindow",
  "cases": [
    {
      "name": "advance_by_one",
      "counter": 100,
      "window": 33,
      "newCounter": 101,
      "expectedCounter": 101,
      "expectedWindow": 67,
      "expectedOk": true
    },
    {
      "name": "advance_with_skip",
      "counter": 100,
      "window": 33,
      "newCounter": 103,
      "expectedCounter": 103,
      "expectedWindow": 268,
      "expectedOk": true
    },
    {
      "name": "advance_beyond_window",
      "counter": 100,
      "window": 33,
      "newCounter": 500,
      "expectedCounter": 500,
      "expectedWindow": 0,
      "expectedOk": true
    },
    {
      "name": "late_fill_within_window",
      "counter": 100,
      "window": 33,
      "newCounter": 98,
      "expectedCounter": 100,
      "expectedWindow": 35,
      "expectedOk": true
    },
    {
      "name": "replay_within_window_rejected",
      "counter": 100,
      "window": 33,
      "newCounter": 99,
      "expectedCounter": 100,
      "expectedWindow": 33,
      "expectedOk": false
    },
    {
      "name": "below_window_rejected",
      "counter": 100,
      "window": 33,
      "newCounter": 3,
      "expectedCounter": 100,
      "expectedWindow": 33,
      "expectedOk": false
    },
    {
      "name": "equal_counter_rejected",
      "counter": 100,
      "window": 33,
      "newCounter": 100,
      "expectedCounter": 100,
      "expectedWindow": 33,
      "expectedOk": false
    }
  ]
}
```

- [ ] **Step 3: Spot-check with `jq`**

```bash
jq '.cases | length' Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json
jq '.cases[0]' Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json
```

Expected: first command prints `7`, second prints the `advance_by_one` object.

- [ ] **Step 4: Remove the placeholder**

```bash
git rm Tests/TeslaBLETests/Fixtures/crypto/.gitkeep
```

- [ ] **Step 5: Commit**

```bash
git add Tests/TeslaBLETests/Fixtures/crypto/window_vectors.json
git commit -m "test: add window sliding-window fixture vectors"
```

---

## Task 3: Write `metadata_sha256_vectors.json` by hand

The `metadata_test.go::TestCheckSum` case (lines 45–65) is another fully literal test vector. Hand-transcribe it. We also add 4 small edge cases so the Swift runner has variety — edge cases are derived from the `metadata.go` semantics (ordering requirement, empty value, max length) without needing to run Go.

**Files:**

- Create: `Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json`

- [ ] **Step 1: Write the JSON**

Create `Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json`. The `testCheckSum_from_go` expected hash is the 32-byte sum from `metadata_test.go` lines 54–58; concatenated it is `abab04d804499813382efd74a06791ce2de777439603246dfbaa8392ca05868e`. Hex values must have no whitespace.

```json
{
  "description": "Metadata TLV → SHA256 Checksum fixtures. Primary case is from internal/authentication/metadata_test.go TestCheckSum. Tags encoded as decimal raw values from Signatures_Tag enum.",
  "cases": [
    {
      "name": "testCheckSum_from_go",
      "hashType": "sha256",
      "items": [
        { "tag": 0, "valueHex": "05" },
        { "tag": 1, "valueHex": "02" },
        { "tag": 2, "valueHex": "7465737456494e" },
        { "tag": 3, "valueHex": "aada928a4f215f55f9e6e45e66b6521e" },
        { "tag": 4, "valueHex": "00000e74" },
        { "tag": 5, "valueHex": "0000053a" }
      ],
      "messageHex": "",
      "expectedChecksumHex": "abab04d804499813382efd74a06791ce2de777439603246dfbaa8392ca05868e"
    },
    {
      "name": "single_tag_empty_message",
      "hashType": "sha256",
      "items": [{ "tag": 1, "valueHex": "02" }],
      "messageHex": "",
      "expectedChecksumHex": "__COMPUTED_IN_TASK_4__"
    },
    {
      "name": "single_tag_with_message_body",
      "hashType": "sha256",
      "items": [{ "tag": 1, "valueHex": "02" }],
      "messageHex": "deadbeef",
      "expectedChecksumHex": "__COMPUTED_IN_TASK_4__"
    },
    {
      "name": "two_tags_ascending",
      "hashType": "sha256",
      "items": [
        { "tag": 0, "valueHex": "05" },
        { "tag": 1, "valueHex": "02" }
      ],
      "messageHex": "",
      "expectedChecksumHex": "__COMPUTED_IN_TASK_4__"
    },
    {
      "name": "max_length_value",
      "hashType": "sha256",
      "items": [
        {
          "tag": 2,
          "valueHex": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        }
      ],
      "messageHex": "",
      "expectedChecksumHex": "__COMPUTED_IN_TASK_4__"
    }
  ]
}
```

- [ ] **Step 2: Verify with `jq`**

```bash
jq '.cases[0].expectedChecksumHex' Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json
jq '.cases | length' Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json
```

Expected: first prints the 64-char hex without spaces, second prints `5`.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json
git commit -m "test: add metadata SHA256 fixture skeleton (4 placeholders)"
```

Note: the four `__COMPUTED_IN_TASK_4__` placeholders are intentional — they get filled in Task 4 using a short Python script as the authoritative oracle. We commit the skeleton so the next task has a concrete file to edit.

---

## Task 4: Compute placeholder SHA256 values with a Python oracle

We use Python's `hashlib` (guaranteed reproducible, no Go toolchain needed) to compute the four remaining expected hex values. Python and Go's `crypto/sha256` are bit-identical — SHA256 has no Endian or framing differences.

**Files:**

- Modify: `Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json`

- [ ] **Step 1: Write and run the oracle script**

Save this as a temporary file `/tmp/metadata_oracle.py` (don't commit it):

```python
import hashlib

TAG_END = 0xFF

def checksum(items, message_hex: str) -> str:
    h = hashlib.sha256()
    last_tag = -1
    for item in items:
        tag = item["tag"]
        value = bytes.fromhex(item["valueHex"])
        assert tag >= last_tag, f"out-of-order tag {tag} after {last_tag}"
        assert len(value) <= 255, f"value too long: {len(value)}"
        last_tag = tag
        h.update(bytes([tag]))
        h.update(bytes([len(value)]))
        h.update(value)
    h.update(bytes([TAG_END]))
    h.update(bytes.fromhex(message_hex))
    return h.hexdigest()

cases = [
    {
        "name": "single_tag_empty_message",
        "items": [{"tag": 1, "valueHex": "02"}],
        "messageHex": "",
    },
    {
        "name": "single_tag_with_message_body",
        "items": [{"tag": 1, "valueHex": "02"}],
        "messageHex": "deadbeef",
    },
    {
        "name": "two_tags_ascending",
        "items": [
            {"tag": 0, "valueHex": "05"},
            {"tag": 1, "valueHex": "02"},
        ],
        "messageHex": "",
    },
    {
        "name": "max_length_value",
        "items": [{"tag": 2, "valueHex": "ff" * 255}],
        "messageHex": "",
    },
]

for c in cases:
    print(f'{c["name"]}: {checksum(c["items"], c["messageHex"])}')
```

Run it:

```bash
python3 /tmp/metadata_oracle.py
```

Expected output (four lines, each a case name and a 64-char hex digest — the exact digests are deterministic and reproducible):

```
single_tag_empty_message: <64 hex chars>
single_tag_with_message_body: <64 hex chars>
two_tags_ascending: <64 hex chars>
max_length_value: <64 hex chars>
```

Copy each digest.

- [ ] **Step 2: Paste the digests into the fixture file**

Edit `Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json`, replacing each `"__COMPUTED_IN_TASK_4__"` with the corresponding digest produced in Step 1. Use `Edit` tool, one replacement at a time.

- [ ] **Step 3: Verify no placeholders remain**

```bash
grep -c COMPUTED Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json
```

Expected: `0`.

- [ ] **Step 4: Commit**

```bash
git add Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json
git commit -m "test: fill metadata SHA256 fixture expected hashes"
```

---

## Task 5: Craft the Go dump patch for session-key, HMAC metadata, and GCM round-trip vectors

This task introduces the temporary Go edit that dumps vectors that are hard to compute by hand. The edits are made to `Vendor/tesla-vehicle-command/internal/authentication/fixture_dump_test.go` (a new file that the dump-patch creates). Running `go test -run TestDumpVectors` produces the JSON files. The task ends by **reverting** the submodule to clean state and saving the diff as `GoPatches/fixture-dump.patch`.

**Files:**

- Create (temporary): `Vendor/tesla-vehicle-command/internal/authentication/fixture_dump_test.go`
- Create: `GoPatches/fixture-dump.patch`
- Create: `Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json`
- Create: `Tests/TeslaBLETests/Fixtures/crypto/metadata_hmac_vectors.json`
- Create: `Tests/TeslaBLETests/Fixtures/crypto/gcm_roundtrip_vectors.json`

- [ ] **Step 1: Confirm Go is installed**

```bash
go version
```

Expected: `go version go1.21.x` or newer. If not present, install it (brew / `go.dev/dl`) before proceeding.

- [ ] **Step 2: Create the dump test file**

Create `Vendor/tesla-vehicle-command/internal/authentication/fixture_dump_test.go` with this content:

```go
//go:build fixture_dump

package authentication

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/teslamotors/vehicle-command/pkg/protocol/protobuf/signatures"
)

// Output root is SWIFT_FIXTURES_DIR (env var, absolute path) or ./fixtures_out if unset.
func outputDir(t *testing.T) string {
	dir := os.Getenv("SWIFT_FIXTURES_DIR")
	if dir == "" {
		dir = "./fixtures_out"
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %s", err)
	}
	return dir
}

type jsonFile struct {
	Description string        `json:"description"`
	Cases       []interface{} `json:"cases"`
}

func writeJSON(t *testing.T, path string, file jsonFile) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %s: %s", path, err)
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(file); err != nil {
		t.Fatalf("encode %s: %s", path, err)
	}
}

// Deterministic P-256 key from a seed scalar. The scalar must be < curve order; all seeds
// used here are well below that.
func scalarToKey(seed string) *ecdsa.PrivateKey {
	d, ok := new(big.Int).SetString(seed, 16)
	if !ok {
		panic("bad seed: " + seed)
	}
	curve := elliptic.P256()
	if d.Sign() == 0 || d.Cmp(curve.Params().N) >= 0 {
		panic("seed out of range: " + seed)
	}
	priv := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: curve}}
	priv.D = d
	priv.PublicKey.X, priv.PublicKey.Y = curve.ScalarBaseMult(d.Bytes())
	return priv
}

// TestDumpSessionKey produces session_key_vectors.json. Each case walks the full derivation
// pipeline: local_scalar + peer_public_bytes -> ecdh(x) -> SHA1 -> first 16 bytes.
func TestDumpSessionKey(t *testing.T) {
	if os.Getenv("DUMP") != "1" {
		t.Skip("set DUMP=1 to run")
	}
	type caseOut struct {
		Name             string `json:"name"`
		LocalScalarHex   string `json:"localScalarHex"`
		PeerPublicHex    string `json:"peerPublicHex"`
		SharedXHex       string `json:"sharedXHex"`
		SessionKeyHex    string `json:"sessionKeyHex"`
	}

	seeds := []struct {
		name, local, peer string
	}{
		{"vector_1", "01", "02"},
		{"vector_2", "deadbeef", "1234abcd"},
		{"vector_3", "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "10"},
		{"vector_4", "42", "cafebabe"},
	}

	var cases []interface{}
	for _, s := range seeds {
		local := scalarToKey(s.local)
		peer := scalarToKey(s.peer)
		peerBytes := elliptic.Marshal(elliptic.P256(), peer.X, peer.Y)

		sharedX, _ := elliptic.P256().ScalarMult(peer.X, peer.Y, local.D.Bytes())
		shared := make([]byte, 32)
		sharedX.FillBytes(shared)
		digest := sha1.Sum(shared)
		sessionKey := digest[:SharedKeySizeBytes]

		cases = append(cases, caseOut{
			Name:           s.name,
			LocalScalarHex: hex.EncodeToString(local.D.Bytes()),
			PeerPublicHex:  hex.EncodeToString(peerBytes),
			SharedXHex:     hex.EncodeToString(shared),
			SessionKeyHex:  hex.EncodeToString(sessionKey),
		})
	}

	writeJSON(t, filepath.Join(outputDir(t), "session_key_vectors.json"), jsonFile{
		Description: "Session key derivation: ECDH shared-X (32B BE) -> SHA1 -> first 16B",
		Cases:       cases,
	})
}

// TestDumpMetadataHMAC produces metadata_hmac_vectors.json covering both labels:
// "authenticated command" (signing) and "session info" (handshake).
func TestDumpMetadataHMAC(t *testing.T) {
	if os.Getenv("DUMP") != "1" {
		t.Skip("set DUMP=1 to run")
	}
	type caseOut struct {
		Name         string              `json:"name"`
		SessionKey   string              `json:"sessionKeyHex"`
		Label        string              `json:"label"`
		Items        []map[string]string `json:"items"`
		MessageHex   string              `json:"messageHex"`
		ExpectedHex  string              `json:"expectedChecksumHex"`
	}

	// A fixed synthetic session key, 16 bytes.
	sk := []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff}

	type item struct {
		Tag   signatures.Tag
		Value []byte
	}

	mkCase := func(name, label string, items []item, message []byte) caseOut {
		session := &NativeSession{key: sk}
		meta := newMetadataHash(session.NewHMAC(label))
		itemsJSON := make([]map[string]string, 0, len(items))
		for _, it := range items {
			if err := meta.Add(it.Tag, it.Value); err != nil {
				panic(err)
			}
			itemsJSON = append(itemsJSON, map[string]string{
				"tag":      fmt.Sprintf("%d", int(it.Tag)),
				"valueHex": hex.EncodeToString(it.Value),
			})
		}
		sum := meta.Checksum(message)
		return caseOut{
			Name:        name,
			SessionKey:  hex.EncodeToString(sk),
			Label:       label,
			Items:       itemsJSON,
			MessageHex:  hex.EncodeToString(message),
			ExpectedHex: hex.EncodeToString(sum),
		}
	}

	// Case 1: signing-path metadata. Mirrors signer.go Encrypt() TLV order.
	case1 := mkCase(
		"signing_path_typical",
		labelMessageAuth,
		[]item{
			{signatures.Tag_TAG_SIGNATURE_TYPE, []byte{byte(signatures.SignatureType_SIGNATURE_TYPE_AES_GCM_PERSONALIZED)}},
			{signatures.Tag_TAG_DOMAIN, []byte{0x02}},
			{signatures.Tag_TAG_PERSONALIZATION, []byte("5YJ3E1EA4JF000001")},
			{signatures.Tag_TAG_EPOCH, []byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef}},
			{signatures.Tag_TAG_EXPIRES_AT, []byte{0x00, 0x00, 0x00, 0x0a}},
			{signatures.Tag_TAG_COUNTER, []byte{0x00, 0x00, 0x00, 0x01}},
		},
		nil,
	)

	// Case 2: session-info-path metadata. Mirrors native.go SessionInfoHMAC() TLV order.
	case2 := mkCase(
		"session_info_path_typical",
		labelSessionInfo,
		[]item{
			{signatures.Tag_TAG_SIGNATURE_TYPE, []byte{byte(signatures.SignatureType_SIGNATURE_TYPE_HMAC)}},
			{signatures.Tag_TAG_PERSONALIZATION, []byte("5YJ3E1EA4JF000001")},
			{signatures.Tag_TAG_CHALLENGE, []byte{0xde, 0xad, 0xbe, 0xef}},
		},
		[]byte{0xaa, 0xbb, 0xcc}, // encodedInfo stand-in
	)

	writeJSON(t, filepath.Join(outputDir(t), "metadata_hmac_vectors.json"), jsonFile{
		Description: "HMAC-keyed metadata TLV checksums (signing path + session-info path)",
		Cases:       []interface{}{case1, case2},
	})
}

// TestDumpGCMRoundtrip produces gcm_roundtrip_vectors.json: fixed session key + fixed nonce
// + known plaintext + known AAD -> expected ciphertext + tag. We use NativeSession.Encrypt
// to guarantee byte-identical output with the vehicle stack.
func TestDumpGCMRoundtrip(t *testing.T) {
	if os.Getenv("DUMP") != "1" {
		t.Skip("set DUMP=1 to run")
	}
	type caseOut struct {
		Name         string `json:"name"`
		SessionKey   string `json:"sessionKeyHex"`
		NonceHex     string `json:"nonceHex"`
		PlaintextHex string `json:"plaintextHex"`
		AADHex       string `json:"aadHex"`
		CiphertextHex string `json:"ciphertextHex"`
		TagHex       string `json:"tagHex"`
	}

	sk := []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff}
	block, err := aes.NewCipher(sk)
	if err != nil {
		t.Fatalf("aes: %s", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("gcm: %s", err)
	}

	fixedNonces := [][]byte{
		{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b},
		{0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44},
		{0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa},
	}
	plaintexts := [][]byte{
		{},
		{0x01},
		[]byte("hello tesla"),
	}
	aads := [][]byte{
		{},
		{0xde, 0xad, 0xbe, 0xef},
		{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00},
	}
	names := []string{"empty_plaintext_empty_aad", "single_byte_plaintext_short_aad", "text_plaintext_long_aad"}

	var cases []interface{}
	for i := 0; i < 3; i++ {
		sealed := gcm.Seal(nil, fixedNonces[i], plaintexts[i], aads[i])
		ct := sealed[:len(sealed)-16]
		tag := sealed[len(sealed)-16:]
		cases = append(cases, caseOut{
			Name:          names[i],
			SessionKey:    hex.EncodeToString(sk),
			NonceHex:      hex.EncodeToString(fixedNonces[i]),
			PlaintextHex:  hex.EncodeToString(plaintexts[i]),
			AADHex:        hex.EncodeToString(aads[i]),
			CiphertextHex: hex.EncodeToString(ct),
			TagHex:        hex.EncodeToString(tag),
		})
	}

	writeJSON(t, filepath.Join(outputDir(t), "gcm_roundtrip_vectors.json"), jsonFile{
		Description: "AES-GCM-128 round-trip with fixed session key and fixed nonce",
		Cases:       cases,
	})
}
```

The `//go:build fixture_dump` tag and the `DUMP=1` env-var gate make triple-sure this file never runs during upstream tests. It only executes when invoked explicitly.

- [ ] **Step 3: Run the dump tests**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
SWIFT_FIXTURES_DIR="$PWD/../../Tests/TeslaBLETests/Fixtures/crypto" \
DUMP=1 \
go test -tags fixture_dump -run 'TestDump.*' ./internal/authentication/
cd ../..
```

Expected: three files appear in `Tests/TeslaBLETests/Fixtures/crypto/`:

- `session_key_vectors.json` (4 cases)
- `metadata_hmac_vectors.json` (2 cases)
- `gcm_roundtrip_vectors.json` (3 cases)

Verify with:

```bash
ls -la Tests/TeslaBLETests/Fixtures/crypto/*.json
jq '.cases | length' Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json
jq '.cases | length' Tests/TeslaBLETests/Fixtures/crypto/metadata_hmac_vectors.json
jq '.cases | length' Tests/TeslaBLETests/Fixtures/crypto/gcm_roundtrip_vectors.json
```

Expected: all three print `4`, `2`, `3` respectively, and each file is ~1–2 KB.

- [ ] **Step 4: Save the Go edit as a patch**

The dump file is untracked in the submodule, so `git diff` alone won't show it. Use `git add -N` first (intent-to-add) so `git diff` can emit a proper patch, then write the diff out:

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git add -N internal/authentication/fixture_dump_test.go
git diff --no-color -- internal/authentication/fixture_dump_test.go > /tmp/fixture-dump.patch
cd ../..
mkdir -p GoPatches
mv /tmp/fixture-dump.patch GoPatches/fixture-dump.patch
```

Verify the patch is non-empty and contains the file header:

```bash
head -5 GoPatches/fixture-dump.patch
wc -l GoPatches/fixture-dump.patch
```

Expected: header starts with `diff --git` and the file is ~200+ lines.

- [ ] **Step 5: Revert the submodule to clean state**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git reset HEAD internal/authentication/fixture_dump_test.go  2>/dev/null || true
rm -f internal/authentication/fixture_dump_test.go
git status
cd ../..
```

Expected: submodule `git status` shows "working tree clean".

- [ ] **Step 6: Commit the fixtures and patch**

```bash
git add Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json
git add Tests/TeslaBLETests/Fixtures/crypto/metadata_hmac_vectors.json
git add Tests/TeslaBLETests/Fixtures/crypto/gcm_roundtrip_vectors.json
git add GoPatches/fixture-dump.patch
git commit -m "test: generate crypto fixtures via Go dump (session_key, metadata_hmac, gcm_roundtrip)"
```

---

## Task 6: Write the Fixtures README

**Files:**

- Create: `Tests/TeslaBLETests/Fixtures/README.md`

- [ ] **Step 1: Write the README**

Create `Tests/TeslaBLETests/Fixtures/README.md`:

````markdown
# Crypto Fixture Vectors

Deterministic test vectors used by `CryptoVectorTests.swift` to validate the Swift `Crypto/` layer against the reference Go implementation in `Vendor/tesla-vehicle-command`.

## Layout

- `crypto/window_vectors.json` — sliding replay window (hand-transcribed from `window_test.go`)
- `crypto/metadata_sha256_vectors.json` — TLV metadata with plain-SHA256 context (one case from Go, four hand-authored)
- `crypto/metadata_hmac_vectors.json` — TLV metadata with HMAC-SHA256 context, both `authenticated command` and `session info` labels (generated)
- `crypto/session_key_vectors.json` — ECDH → shared-X → SHA1 → first 16B derivation (generated)
- `crypto/gcm_roundtrip_vectors.json` — AES-GCM-128 seal with fixed nonce, known AAD and plaintext (generated)

## Regeneration

Generated fixtures come from a temporary Go test file held in `GoPatches/fixture-dump.patch`. To regenerate:

```bash
cd Vendor/tesla-vehicle-command
git apply ../../GoPatches/fixture-dump.patch
SWIFT_FIXTURES_DIR="$PWD/../../Tests/TeslaBLETests/Fixtures/crypto" \
  DUMP=1 \
  go test -tags fixture_dump -run 'TestDump.*' ./internal/authentication/
git checkout -- internal/authentication/fixture_dump_test.go 2>/dev/null || true
rm -f internal/authentication/fixture_dump_test.go
cd ../..
git status
```
````

The submodule must be clean before committing (the dump file is never tracked upstream). Fixture files under `Tests/TeslaBLETests/Fixtures/crypto/*.json` are what actually gets committed.

## Hand-authored vs. generated

`window_vectors.json` and most of `metadata_sha256_vectors.json` are hand-transcribed from Go literal test tables — they do not require running Go. If you need to add a new case and cannot easily compute the expected value by hand, extend the dump-patch file and regenerate.

````

- [ ] **Step 2: Commit**

```bash
git add Tests/TeslaBLETests/Fixtures/README.md
git commit -m "docs: explain fixture layout and regeneration"
````

---

## Task 7: Wire `Fixtures` into the test target via Package.swift

**Files:**

- Modify: `Package.swift`

- [ ] **Step 1: Read the current Package.swift**

The file lives at `/Users/jiaxinshou/Developer/swift-tesla-ble/Package.swift`. The current test target block is:

```swift
.testTarget(
    name: "TeslaBLETests",
    dependencies: ["TeslaBLE"],
),
```

- [ ] **Step 2: Add the `resources` copy rule**

Use Edit to replace:

```swift
        .testTarget(
            name: "TeslaBLETests",
            dependencies: ["TeslaBLE"],
        ),
```

with:

```swift
        .testTarget(
            name: "TeslaBLETests",
            dependencies: ["TeslaBLE"],
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 3: Verify `swift build` still compiles**

```bash
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 4: Verify `swift test` discovers the resource bundle**

```bash
swift test 2>&1 | tail -10
```

Expected: all existing tests pass; no errors about missing or duplicate resources. The fixtures are not yet consumed by any test code, so this is just a smoke check.

- [ ] **Step 5: Commit**

```bash
git add Package.swift
git commit -m "build: expose Tests/TeslaBLETests/Fixtures/ as test resource bundle"
```

---

## Task 8: Implement `CounterWindow.swift` — the failing test first

We use TDD for the Crypto layer: write the test that loads the fixture, watch it fail (because the type doesn't exist yet), implement, watch it pass.

**Files:**

- Create: `Tests/TeslaBLETests/CryptoVectorTests.swift`
- Create: `Sources/TeslaBLE/Crypto/CounterWindow.swift` (stub that compiles but fails semantically — intentionally broken so the test has something to reject)

- [ ] **Step 1: Create the test file with a fixture-loading helper and the first test**

Create `Tests/TeslaBLETests/CryptoVectorTests.swift`:

```swift
import Foundation
import XCTest
@testable import TeslaBLE

/// Fixture-driven tests for the TeslaBLE Crypto layer. Each JSON fixture in
/// Tests/TeslaBLETests/Fixtures/crypto/ drives a parametric XCTest method.
final class CryptoVectorTests: XCTestCase {

    // MARK: - Fixture loading

    private struct WindowFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let counter: UInt32
            let window: UInt64
            let newCounter: UInt32
            let expectedCounter: UInt32
            let expectedWindow: UInt64
            let expectedOk: Bool
        }
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, named filename: String) throws -> T {
        guard let url = Bundle.module.url(forResource: "Fixtures/crypto/\(filename)", withExtension: nil) else {
            XCTFail("Missing fixture: Fixtures/crypto/\(filename)")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Window tests

    func testSlidingWindowVectors() throws {
        let fixture = try loadJSON(WindowFixture.self, named: "window_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty, "fixture has no cases")

        for testCase in fixture.cases {
            var window = CounterWindow(counter: testCase.counter, history: testCase.window, initialized: true)
            let ok = window.accept(testCase.newCounter)
            XCTAssertEqual(
                ok, testCase.expectedOk,
                "[\(testCase.name)] ok mismatch"
            )
            XCTAssertEqual(
                window.counter, testCase.expectedCounter,
                "[\(testCase.name)] counter mismatch"
            )
            XCTAssertEqual(
                window.history, testCase.expectedWindow,
                "[\(testCase.name)] history mismatch"
            )
        }
    }
}
```

- [ ] **Step 2: Run the test — expect compile failure**

```bash
swift test --filter CryptoVectorTests/testSlidingWindowVectors 2>&1 | tail -15
```

Expected: compile error mentioning `CounterWindow` is undefined. This confirms the test is wired up and the test target can see the `TeslaBLE` module.

- [ ] **Step 3: Create a deliberately-wrong stub so the test compiles**

Create `Sources/TeslaBLE/Crypto/CounterWindow.swift`:

```swift
import Foundation

/// Sliding replay window — tracks whether a counter has been seen before.
/// Intentionally broken in this first cut so the fixture test fails. Task 9
/// replaces this body with the correct algorithm.
struct CounterWindow: Sendable {
    var counter: UInt32
    var history: UInt64
    var initialized: Bool

    init(counter: UInt32 = 0, history: UInt64 = 0, initialized: Bool = false) {
        self.counter = counter
        self.history = history
        self.initialized = initialized
    }

    mutating func accept(_ newCounter: UInt32) -> Bool {
        // Deliberate placeholder — returns false for everything so the fixture
        // test fails and we can see the test actually runs.
        return false
    }
}
```

Remove the `.gitkeep`:

```bash
git rm Sources/TeslaBLE/Crypto/.gitkeep
```

- [ ] **Step 4: Run the test — expect semantic failure**

```bash
swift test --filter CryptoVectorTests/testSlidingWindowVectors 2>&1 | tail -15
```

Expected: test **runs** and fails at least the first case (`advance_by_one` expected ok=true, got ok=false).

- [ ] **Step 5: Commit the failing test and stub**

```bash
git add Tests/TeslaBLETests/CryptoVectorTests.swift Sources/TeslaBLE/Crypto/CounterWindow.swift
git commit -m "test(wip): add failing window fixture test + CounterWindow stub"
```

---

## Task 9: Implement `CounterWindow.accept` correctly

**Files:**

- Modify: `Sources/TeslaBLE/Crypto/CounterWindow.swift`

- [ ] **Step 1: Replace the body**

Replace the entire contents of `Sources/TeslaBLE/Crypto/CounterWindow.swift` with:

```swift
import Foundation

/// Sliding replay window over a 32-bit message counter.
///
/// Direct port of `internal/authentication/window.go`. The window tracks the
/// 32 most recent counters below `counter` via bit positions in `history`:
/// bit 0 corresponds to `counter - 1`, bit 1 to `counter - 2`, etc.
///
/// - Parameter counter: the highest-seen counter value so far.
/// - Parameter history: 64-bit bitmap of earlier counters seen, LSB = most recent.
/// - Parameter initialized: false until `accept` has been called at least once.
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
```

Note the single deviation from Go's algorithm: `window.go` computes `updatedWindow <<= shiftCount` which, in Go, for `shiftCount >= 64`, produces 0 (Go shift semantics on unsigned types saturate by zeroing). Swift's `<<` on `UInt64` has the same behavior up to 63, but at exactly 64 or more it traps. The `if shiftCount >= 64` guard preserves Go's zeroing semantics and prevents the trap. The `advance_beyond_window` fixture case has `shiftCount = 400 >> 64`, so without the guard the test would crash before even producing an assertion failure.

- [ ] **Step 2: Run the test — expect pass**

```bash
swift test --filter CryptoVectorTests/testSlidingWindowVectors 2>&1 | tail -15
```

Expected: test passes, all 7 cases green.

- [ ] **Step 3: Run the full test suite to confirm nothing else broke**

```bash
swift test 2>&1 | tail -15
```

Expected: all tests pass. The existing non-fixture tests should continue to work.

- [ ] **Step 4: Commit**

```bash
git add Sources/TeslaBLE/Crypto/CounterWindow.swift
git commit -m "feat: implement CounterWindow with sliding replay algorithm"
```

---

## Task 10: Implement `SessionKey.swift` and `P256ECDH.swift` + their tests

Both are small enough to pair in one task; together they form the "ECDH-to-AES-key" pipeline.

**Files:**

- Create: `Sources/TeslaBLE/Crypto/P256ECDH.swift`
- Create: `Sources/TeslaBLE/Crypto/SessionKey.swift`
- Modify: `Tests/TeslaBLETests/CryptoVectorTests.swift`

- [ ] **Step 1: Write the failing test for session-key derivation**

Append to `Tests/TeslaBLETests/CryptoVectorTests.swift`:

```swift
    // MARK: - Session key derivation tests

    private struct SessionKeyFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let localScalarHex: String
            let peerPublicHex: String
            let sharedXHex: String
            let sessionKeyHex: String
        }
    }

    func testSessionKeyVectors() throws {
        let fixture = try loadJSON(SessionKeyFixture.self, named: "session_key_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let rawScalar = try XCTUnwrap(Data(hex: testCase.localScalarHex))
            // Go's big.Int.Bytes() strips leading zeros; P-256 scalars are 32 bytes big-endian.
            var localScalar = Data(count: 32 - rawScalar.count)
            localScalar.append(rawScalar)
            let peerPublic = try XCTUnwrap(Data(hex: testCase.peerPublicHex))
            let expectedSharedX = try XCTUnwrap(Data(hex: testCase.sharedXHex))
            let expectedSessionKey = try XCTUnwrap(Data(hex: testCase.sessionKeyHex))

            let sharedX = try P256ECDH.sharedSecret(
                localScalar: localScalar,
                peerPublicUncompressed: peerPublic
            )
            XCTAssertEqual(
                sharedX, expectedSharedX,
                "[\(testCase.name)] shared X mismatch"
            )

            let derivedKey = SessionKey.derive(fromSharedSecret: sharedX)
            XCTAssertEqual(
                derivedKey.rawBytes, expectedSessionKey,
                "[\(testCase.name)] session key mismatch"
            )
        }
    }
```

Also add a small hex helper at the top of the test file, below the imports:

```swift
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
```

- [ ] **Step 2: Run the test — expect compile failure**

```bash
swift test --filter CryptoVectorTests/testSessionKeyVectors 2>&1 | tail -20
```

Expected: compile failure — `P256ECDH` and `SessionKey` don't exist yet.

- [ ] **Step 3: Implement `P256ECDH`**

Create `Sources/TeslaBLE/Crypto/P256ECDH.swift`:

```swift
import CryptoKit
import Foundation

/// Thin wrapper around CryptoKit's `P256.KeyAgreement` surfacing the raw
/// 32-byte shared X-coordinate in the exact format the vehicle expects.
///
/// The vehicle uses static-ECDH over NIST P-256. The shared secret is the
/// X-coordinate of the scalar-multiplied point, zero-padded to 32 bytes
/// big-endian. `CryptoKit.SharedSecret.withUnsafeBytes { Data($0) }` already
/// returns the secret in that exact form for P-256, so this wrapper is
/// effectively just a format-validating adapter.
enum P256ECDH {

    enum Error: Swift.Error, Equatable {
        case invalidPrivateKeyLength
        case invalidPrivateKey
        case invalidPublicKey
    }

    /// Computes the shared secret X-coordinate between a local private key
    /// (given as its 32-byte raw scalar) and a peer public key (given as its
    /// 65-byte uncompressed SEC1 encoding, i.e. `0x04 || X || Y`).
    ///
    /// Returns the 32-byte big-endian X coordinate of the shared point.
    static func sharedSecret(
        localScalar: Data,
        peerPublicUncompressed: Data
    ) throws -> Data {
        guard localScalar.count == 32 else {
            throw Error.invalidPrivateKeyLength
        }
        let privateKey: P256.KeyAgreement.PrivateKey
        do {
            privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: localScalar)
        } catch {
            throw Error.invalidPrivateKey
        }

        let publicKey: P256.KeyAgreement.PublicKey
        do {
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicUncompressed)
        } catch {
            throw Error.invalidPublicKey
        }

        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }
}
```

- [ ] **Step 4: Implement `SessionKey`**

Create `Sources/TeslaBLE/Crypto/SessionKey.swift`:

```swift
import CryptoKit
import Foundation

/// 16-byte AES-GCM-128 key derived from an ECDH shared secret.
///
/// Derivation is `SHA1(shared_x)[0..<16]`. SHA-1 is used here for wire
/// compatibility with the vehicle and is safe in this specific context: the
/// input (the X-coordinate of a random curve point) is already pseudorandom,
/// and the output is treated as a PRF seed rather than relied upon for
/// collision resistance. See `Vendor/tesla-vehicle-command/internal/authentication/native.go`
/// `NativeECDHKey.Exchange`.
struct SessionKey: Sendable, Equatable {

    /// The raw 16 bytes of the derived key.
    let rawBytes: Data

    /// CryptoKit-friendly view over the same bytes.
    var symmetric: SymmetricKey { SymmetricKey(data: rawBytes) }

    /// Derive a SessionKey from the raw 32-byte shared X coordinate.
    static func derive(fromSharedSecret sharedX: Data) -> SessionKey {
        precondition(sharedX.count == 32, "ECDH shared-X must be 32 bytes")
        let digest = Insecure.SHA1.hash(data: sharedX)
        let truncated = Data(digest.prefix(16))
        return SessionKey(rawBytes: truncated)
    }
}
```

- [ ] **Step 5: Run the test — expect pass**

```bash
swift test --filter CryptoVectorTests/testSessionKeyVectors 2>&1 | tail -15
```

Expected: 4/4 session_key vectors pass.

- [ ] **Step 6: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests green.

- [ ] **Step 7: Commit**

```bash
git add Sources/TeslaBLE/Crypto/P256ECDH.swift Sources/TeslaBLE/Crypto/SessionKey.swift Tests/TeslaBLETests/CryptoVectorTests.swift
git commit -m "feat: implement P256ECDH + SessionKey (SHA1 truncation, fixture-tested)"
```

---

## Task 11: Implement `MetadataHash.swift` — TLV builder

This is the single largest file in the Crypto layer. It implements the TLV encoding used in three different paths (plain SHA256 AAD, HMAC signing, HMAC session-info). Start with the failing test for the plain-SHA256 path.

**Files:**

- Modify: `Tests/TeslaBLETests/CryptoVectorTests.swift`
- Create: `Sources/TeslaBLE/Crypto/MetadataHash.swift`

- [ ] **Step 1: Add the SHA256 metadata test**

Append to `CryptoVectorTests.swift`:

```swift
    // MARK: - Metadata TLV checksum tests

    private struct MetadataSHA256Fixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let hashType: String
            let items: [Item]
            let messageHex: String
            let expectedChecksumHex: String

            struct Item: Decodable {
                let tag: Int
                let valueHex: String
            }
        }
    }

    func testMetadataSHA256Vectors() throws {
        let fixture = try loadJSON(MetadataSHA256Fixture.self, named: "metadata_sha256_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            XCTAssertEqual(testCase.hashType, "sha256", "[\(testCase.name)] unexpected hash type")

            var builder = MetadataHash.sha256Context()
            for item in testCase.items {
                let value = try XCTUnwrap(Data(hex: item.valueHex))
                try builder.add(tagRaw: UInt8(item.tag), value: value)
            }
            let message = try XCTUnwrap(Data(hex: testCase.messageHex))
            let expected = try XCTUnwrap(Data(hex: testCase.expectedChecksumHex))
            let actual = builder.checksum(over: message)
            XCTAssertEqual(actual, expected, "[\(testCase.name)] checksum mismatch")
        }
    }
```

- [ ] **Step 2: Run — expect compile failure**

```bash
swift test --filter CryptoVectorTests/testMetadataSHA256Vectors 2>&1 | tail -15
```

Expected: `MetadataHash` is undefined.

- [ ] **Step 3: Implement `MetadataHash.swift`**

Create `Sources/TeslaBLE/Crypto/MetadataHash.swift`:

```swift
import CryptoKit
import Foundation

/// TLV metadata builder used by every signing / verifying path in the
/// TeslaBLE crypto stack. Direct port of `internal/authentication/metadata.go`.
///
/// Values are added as `[tag][length][value...]` triples with the constraint
/// that tags must be added in strictly ascending order and each value must
/// be ≤ 255 bytes. The builder terminates the hash input with the `TAG_END`
/// byte (0xFF) followed by an optional "message" blob, then produces the
/// checksum via whatever hash context was supplied at construction.
///
/// Three context types are supported via factory methods:
/// - `sha256Context()` — plain `SHA256`. Used for AES-GCM AAD and for the
///   response-verification metadata.
/// - `hmacContext(sessionKey:label:)` — `HMAC<SHA256>` keyed with a subkey
///   derived as `HMAC-SHA256(sessionKey, label_utf8)`. Used for the
///   `AuthorizeHMAC` signing path and for `SessionInfoHMAC` handshake
///   verification.
///
/// The `last` tag field enforces the ordering requirement at runtime; adding
/// a tag out of order throws `.outOfOrder`.
struct MetadataHash {

    enum Error: Swift.Error, Equatable {
        case outOfOrder(tag: Int, previous: Int)
        case valueTooLong(Int)
    }

    // MARK: - Hash context abstraction

    /// Internal enum because CryptoKit's hash function types don't share a
    /// protocol we can store uniformly. We branch on the enum in `update`
    /// and `finalize`.
    private enum Context {
        case sha256(SHA256)
        case hmacSHA256(HMAC<SHA256>)

        mutating func update(_ data: Data) {
            switch self {
            case .sha256(var h):
                h.update(data: data)
                self = .sha256(h)
            case .hmacSHA256(var h):
                h.update(data: data)
                self = .hmacSHA256(h)
            }
        }

        func finalize() -> Data {
            switch self {
            case .sha256(let h):
                return Data(h.finalize())
            case .hmacSHA256(let h):
                return Data(h.finalize())
            }
        }
    }

    // MARK: - Constants

    /// Raw value of `Signatures_Tag.end` — the terminator byte. See
    /// `Sources/TeslaBLE/Generated/signatures.pb.swift:40`.
    static let tagEnd: UInt8 = 255

    // MARK: - Stored state

    private var context: Context
    private var lastTag: Int

    private init(context: Context) {
        self.context = context
        self.lastTag = -1
    }

    // MARK: - Factories

    /// Plain SHA256 context.
    static func sha256Context() -> MetadataHash {
        return MetadataHash(context: .sha256(SHA256()))
    }

    /// HMAC-SHA256 context keyed with a subkey derived from the session key
    /// and the label string. The subkey is `HMAC-SHA256(sessionKey, label)`
    /// (see `native.go` `NativeSession.subkey`), and the outer MAC is a fresh
    /// `HMAC<SHA256>` keyed on that subkey.
    static func hmacContext(sessionKey: SessionKey, label: String) -> MetadataHash {
        let labelBytes = Data(label.utf8)
        var inner = HMAC<SHA256>(key: sessionKey.symmetric)
        inner.update(data: labelBytes)
        let subkey = SymmetricKey(data: Data(inner.finalize()))
        return MetadataHash(context: .hmacSHA256(HMAC<SHA256>(key: subkey)))
    }

    // MARK: - Mutation

    /// Add a TLV entry. `tagRaw` is the raw enum value of `Signatures_Tag`.
    mutating func add(tagRaw: UInt8, value: Data) throws {
        let tagInt = Int(tagRaw)
        if tagInt < lastTag {
            throw Error.outOfOrder(tag: tagInt, previous: lastTag)
        }
        if value.count > 255 {
            throw Error.valueTooLong(value.count)
        }
        lastTag = tagInt
        context.update(Data([tagRaw]))
        context.update(Data([UInt8(value.count)]))
        context.update(value)
    }

    /// Convenience: add a UInt32 as 4 big-endian bytes.
    mutating func addUInt32(tagRaw: UInt8, value: UInt32) throws {
        var be = value.bigEndian
        let bytes = withUnsafeBytes(of: &be) { Data($0) }
        try add(tagRaw: tagRaw, value: bytes)
    }

    // MARK: - Finalization

    /// Terminate with the TAG_END byte + `message` blob and return the final
    /// digest / tag bytes. This mutates and consumes the builder — do not call
    /// twice.
    mutating func checksum(over message: Data) -> Data {
        context.update(Data([Self.tagEnd]))
        context.update(message)
        return context.finalize()
    }
}
```

- [ ] **Step 4: Run SHA256 metadata test**

```bash
swift test --filter CryptoVectorTests/testMetadataSHA256Vectors 2>&1 | tail -20
```

Expected: all 5 cases pass. If the first (`testCheckSum_from_go`) fails, there's a transcription bug — fix before moving on.

- [ ] **Step 5: Add the HMAC metadata test**

Append to `CryptoVectorTests.swift`:

```swift
    private struct MetadataHMACFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let sessionKeyHex: String
            let label: String
            let items: [Item]
            let messageHex: String
            let expectedChecksumHex: String

            struct Item: Decodable {
                let tag: String       // decimal as string in the dumped fixture
                let valueHex: String
            }
        }
    }

    func testMetadataHMACVectors() throws {
        let fixture = try loadJSON(MetadataHMACFixture.self, named: "metadata_hmac_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let keyBytes = try XCTUnwrap(Data(hex: testCase.sessionKeyHex))
            let sessionKey = SessionKey(rawBytes: keyBytes)
            var builder = MetadataHash.hmacContext(sessionKey: sessionKey, label: testCase.label)
            for item in testCase.items {
                let tagInt = try XCTUnwrap(Int(item.tag))
                let value = try XCTUnwrap(Data(hex: item.valueHex))
                try builder.add(tagRaw: UInt8(tagInt), value: value)
            }
            let message = try XCTUnwrap(Data(hex: testCase.messageHex))
            let expected = try XCTUnwrap(Data(hex: testCase.expectedChecksumHex))
            let actual = builder.checksum(over: message)
            XCTAssertEqual(actual, expected, "[\(testCase.name)] HMAC checksum mismatch")
        }
    }
```

Note the `tag` field is decoded as `String` because the Go dump writes it via `fmt.Sprintf("%d", ...)` — this was deliberate for compactness. If during Task 5 you notice Go encoding produces integer `tag` values, adjust the decoder accordingly. Grep `fixture_dump_test.go` or look at the generated file to confirm.

- [ ] **Step 6: Run HMAC metadata test**

```bash
swift test --filter CryptoVectorTests/testMetadataHMACVectors 2>&1 | tail -20
```

Expected: both HMAC cases pass. If one fails, most likely suspect is the subkey derivation order — verify `hmacContext` matches `NativeSession.subkey` (inner HMAC over label, then outer HMAC keyed on result).

- [ ] **Step 7: Make the `SessionKey` initializer accessible to tests**

The test above uses `SessionKey(rawBytes:)` directly. The current struct declares `rawBytes: Data` as `let` — the memberwise initializer is `internal` by default because `SessionKey` is `internal`. That's fine: tests import `@testable import TeslaBLE`. No changes needed — just verify.

```bash
swift test --filter CryptoVectorTests 2>&1 | tail -25
```

Expected: all Crypto fixture tests currently implemented (window, sessionKey, metadataSHA256, metadataHMAC) pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/TeslaBLE/Crypto/MetadataHash.swift Tests/TeslaBLETests/CryptoVectorTests.swift
git commit -m "feat: implement MetadataHash TLV builder (SHA256 + HMAC contexts)"
```

---

## Task 12: Implement `MessageAuthenticator.swift` — AES-GCM round-trip against fixture

**Files:**

- Modify: `Tests/TeslaBLETests/CryptoVectorTests.swift`
- Create: `Sources/TeslaBLE/Crypto/MessageAuthenticator.swift`

- [ ] **Step 1: Add the GCM round-trip test**

Append to `CryptoVectorTests.swift`:

```swift
    // MARK: - AES-GCM round-trip tests

    private struct GCMFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let sessionKeyHex: String
            let nonceHex: String
            let plaintextHex: String
            let aadHex: String
            let ciphertextHex: String
            let tagHex: String
        }
    }

    func testGCMRoundtripVectors() throws {
        let fixture = try loadJSON(GCMFixture.self, named: "gcm_roundtrip_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let keyBytes = try XCTUnwrap(Data(hex: testCase.sessionKeyHex))
            let nonce = try XCTUnwrap(Data(hex: testCase.nonceHex))
            let plaintext = try XCTUnwrap(Data(hex: testCase.plaintextHex))
            let aad = try XCTUnwrap(Data(hex: testCase.aadHex))
            let expectedCT = try XCTUnwrap(Data(hex: testCase.ciphertextHex))
            let expectedTag = try XCTUnwrap(Data(hex: testCase.tagHex))

            let sessionKey = SessionKey(rawBytes: keyBytes)

            // Seal with the fixed nonce and assert byte-for-byte agreement.
            let sealed = try MessageAuthenticator.sealFixed(
                plaintext: plaintext,
                associatedData: aad,
                nonce: nonce,
                sessionKey: sessionKey
            )
            XCTAssertEqual(sealed.ciphertext, expectedCT, "[\(testCase.name)] ciphertext mismatch")
            XCTAssertEqual(sealed.tag, expectedTag, "[\(testCase.name)] tag mismatch")

            // Open it back and confirm plaintext.
            let opened = try MessageAuthenticator.open(
                ciphertext: expectedCT,
                tag: expectedTag,
                nonce: nonce,
                associatedData: aad,
                sessionKey: sessionKey
            )
            XCTAssertEqual(opened, plaintext, "[\(testCase.name)] open mismatch")
        }
    }
```

- [ ] **Step 2: Run — expect compile failure**

```bash
swift test --filter CryptoVectorTests/testGCMRoundtripVectors 2>&1 | tail -15
```

Expected: `MessageAuthenticator` undefined.

- [ ] **Step 3: Implement `MessageAuthenticator`**

Create `Sources/TeslaBLE/Crypto/MessageAuthenticator.swift`:

```swift
import CryptoKit
import Foundation

/// AES-GCM-128 seal / open used by the TeslaBLE signing and verification
/// paths. Wraps CryptoKit's `AES.GCM` with the specific semantics expected
/// by the vehicle:
///
/// - 12-byte nonces (CryptoKit default)
/// - 16-byte tags (CryptoKit default)
/// - Ciphertext and tag are returned separately (not as a single blob)
enum MessageAuthenticator {

    enum Error: Swift.Error, Equatable {
        case sealFailed(String)
        case openFailed(String)
        case invalidNonce
    }

    struct Sealed {
        let ciphertext: Data
        let tag: Data
    }

    /// Seal plaintext with a caller-supplied fixed nonce. This form exists for
    /// fixture testing and for any future replay-of-previous-request path.
    /// The production signer uses `seal(plaintext:associatedData:sessionKey:)`
    /// which generates a random nonce.
    static func sealFixed(
        plaintext: Data,
        associatedData: Data,
        nonce: Data,
        sessionKey: SessionKey
    ) throws -> Sealed {
        guard nonce.count == 12 else {
            throw Error.invalidNonce
        }
        let gcmNonce: AES.GCM.Nonce
        do {
            gcmNonce = try AES.GCM.Nonce(data: nonce)
        } catch {
            throw Error.invalidNonce
        }
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: sessionKey.symmetric,
                nonce: gcmNonce,
                authenticating: associatedData
            )
            return Sealed(ciphertext: box.ciphertext, tag: Data(box.tag))
        } catch {
            throw Error.sealFailed(String(describing: error))
        }
    }

    /// Seal plaintext with a freshly-generated random nonce. Used by the
    /// production signer path. Returns nonce alongside ciphertext and tag.
    static func seal(
        plaintext: Data,
        associatedData: Data,
        sessionKey: SessionKey
    ) throws -> (nonce: Data, ciphertext: Data, tag: Data) {
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: sessionKey.symmetric,
                authenticating: associatedData
            )
            return (Data(box.nonce), box.ciphertext, Data(box.tag))
        } catch {
            throw Error.sealFailed(String(describing: error))
        }
    }

    /// Open a sealed box. Throws `.openFailed` on tag mismatch.
    static func open(
        ciphertext: Data,
        tag: Data,
        nonce: Data,
        associatedData: Data,
        sessionKey: SessionKey
    ) throws -> Data {
        guard nonce.count == 12 else {
            throw Error.invalidNonce
        }
        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let box = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(box, using: sessionKey.symmetric, authenticating: associatedData)
        } catch let e as MessageAuthenticator.Error {
            throw e
        } catch {
            throw Error.openFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run the GCM test**

```bash
swift test --filter CryptoVectorTests/testGCMRoundtripVectors 2>&1 | tail -15
```

Expected: all 3 GCM cases pass.

- [ ] **Step 5: Run the full suite**

```bash
swift test 2>&1 | tail -15
```

Expected: all tests pass, including pre-existing ones and the four new fixture test methods.

- [ ] **Step 6: Commit**

```bash
git add Sources/TeslaBLE/Crypto/MessageAuthenticator.swift Tests/TeslaBLETests/CryptoVectorTests.swift
git commit -m "feat: implement MessageAuthenticator (AES-GCM-128 seal/open)"
```

---

## Task 13: Add an out-of-order and value-too-long edge-case test for `MetadataHash`

The Go side has `TestOutOfOrder` and `TestValueTooLong` — we should have equivalents to lock in the error-throwing contract.

**Files:**

- Modify: `Tests/TeslaBLETests/CryptoVectorTests.swift`

- [ ] **Step 1: Add two new methods**

Append to `CryptoVectorTests.swift`:

```swift
    // MARK: - MetadataHash error-path tests

    func testMetadataHashOutOfOrderThrows() throws {
        var builder = MetadataHash.sha256Context()
        try builder.add(tagRaw: 1, value: Data([0x01]))
        try builder.add(tagRaw: 2, value: Data([0x02]))

        XCTAssertThrowsError(try builder.add(tagRaw: 1, value: Data([0x03]))) { error in
            guard case MetadataHash.Error.outOfOrder(let tag, let previous) = error else {
                XCTFail("expected outOfOrder, got \(error)")
                return
            }
            XCTAssertEqual(tag, 1)
            XCTAssertEqual(previous, 2)
        }
    }

    func testMetadataHashValueTooLongThrows() throws {
        var builder = MetadataHash.sha256Context()
        let tooLong = Data(repeating: 0x42, count: 256)
        XCTAssertThrowsError(try builder.add(tagRaw: 1, value: tooLong)) { error in
            guard case MetadataHash.Error.valueTooLong(let length) = error else {
                XCTFail("expected valueTooLong, got \(error)")
                return
            }
            XCTAssertEqual(length, 256)
        }
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter CryptoVectorTests 2>&1 | tail -20
```

Expected: both new tests pass along with the existing four.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/CryptoVectorTests.swift
git commit -m "test: cover MetadataHash out-of-order and too-long error paths"
```

---

## Task 14: Add an edge-case test for `CounterWindow` uninitialized path

The Go test only exercises the `updateSlidingWindow` free function with a pre-initialized state. The Swift port has an additional branch: the very first `accept` call when `initialized == false`. Cover it explicitly.

**Files:**

- Modify: `Tests/TeslaBLETests/CryptoVectorTests.swift`

- [ ] **Step 1: Add the test**

Append:

```swift
    // MARK: - CounterWindow uninitialized path

    func testCounterWindowFirstUseAcceptsAnyValue() {
        var window = CounterWindow()
        XCTAssertFalse(window.initialized)
        XCTAssertTrue(window.accept(12345))
        XCTAssertTrue(window.initialized)
        XCTAssertEqual(window.counter, 12345)
        XCTAssertEqual(window.history, 0)
    }

    func testCounterWindowHistoryZeroAfterLargeJump() {
        var window = CounterWindow(counter: 5, history: 0b111, initialized: true)
        XCTAssertTrue(window.accept(200))
        XCTAssertEqual(window.counter, 200)
        XCTAssertEqual(window.history, 0, "history must clear on shifts ≥ 64")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter CryptoVectorTests 2>&1 | tail -15
```

Expected: both new tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/CryptoVectorTests.swift
git commit -m "test: cover CounterWindow uninitialized and >=64 shift paths"
```

---

## Task 15: Add a `P256ECDH` negative test for invalid inputs

The `P256ECDH` wrapper throws three distinct errors. Lock them in.

**Files:**

- Modify: `Tests/TeslaBLETests/CryptoVectorTests.swift`

- [ ] **Step 1: Add the test**

Append:

```swift
    // MARK: - P256ECDH error paths

    func testP256ECDHRejectsShortPrivateKey() {
        let shortScalar = Data(repeating: 0x01, count: 31)
        let fakePublic = Data(repeating: 0x04, count: 65)
        XCTAssertThrowsError(try P256ECDH.sharedSecret(
            localScalar: shortScalar,
            peerPublicUncompressed: fakePublic
        )) { error in
            XCTAssertEqual(error as? P256ECDH.Error, .invalidPrivateKeyLength)
        }
    }

    func testP256ECDHRejectsMalformedPublicKey() {
        let scalar = Data(repeating: 0x01, count: 32)
        let bogusPublic = Data(repeating: 0x00, count: 65) // not a valid SEC1 point
        XCTAssertThrowsError(try P256ECDH.sharedSecret(
            localScalar: scalar,
            peerPublicUncompressed: bogusPublic
        )) { error in
            XCTAssertEqual(error as? P256ECDH.Error, .invalidPublicKey)
        }
    }
```

Note: `P256.KeyAgreement.PrivateKey(rawRepresentation:)` accepts any non-zero 32-byte value below the curve order, so it's hard to trigger `.invalidPrivateKey` without a concrete weak input. Skip that negative case for now — the positive fixture path already covers the happy branch.

- [ ] **Step 2: Run**

```bash
swift test --filter CryptoVectorTests 2>&1 | tail -15
```

Expected: both new tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/TeslaBLETests/CryptoVectorTests.swift
git commit -m "test: cover P256ECDH short-scalar and invalid public-key paths"
```

---

## Task 16: Run the full suite and confirm nothing from the existing `TeslaCommand` xcframework path regressed

Before declaring Phase 2 done we must confirm the legacy path still works.

- [ ] **Step 1: Run the full test suite**

```bash
swift test 2>&1 | tail -30
```

Expected: zero failures. Count the `Crypto`-related tests (should be ≥ 10 new test methods) and verify any pre-existing tests that depended on `TeslaCommand.xcframework` still pass.

- [ ] **Step 2: Run `swift build` to confirm the whole package still links**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. If this fails, the likely cause is an accidentally-public symbol in a new Crypto file clashing with something else — fix before committing.

- [ ] **Step 3: Confirm the submodule is clean**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Vendor/tesla-vehicle-command
git status
cd ../..
```

Expected: "working tree clean". If any stray files are present from the Task 5 dump work, delete them and confirm the patch in `GoPatches/fixture-dump.patch` still reproduces them cleanly.

- [ ] **Step 4: No commit needed**

This task is a verification checkpoint — no code changes.

---

## Task 17: Smoke-test the `GoPatches/fixture-dump.patch` round-trip

Prove that the saved patch actually regenerates the fixtures bit-identically. This is the regression guard for future Tesla proto updates.

- [ ] **Step 1: Save current fixture state**

```bash
cp Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json /tmp/sk_before.json
cp Tests/TeslaBLETests/Fixtures/crypto/metadata_hmac_vectors.json /tmp/mh_before.json
cp Tests/TeslaBLETests/Fixtures/crypto/gcm_roundtrip_vectors.json /tmp/gcm_before.json
```

- [ ] **Step 2: Apply the patch to the submodule**

```bash
cd Vendor/tesla-vehicle-command
git apply ../../GoPatches/fixture-dump.patch
ls internal/authentication/fixture_dump_test.go
cd ../..
```

Expected: the file appears in the submodule working tree.

- [ ] **Step 3: Re-run the dump to a scratch dir**

```bash
mkdir -p /tmp/fixture_regen
cd Vendor/tesla-vehicle-command
SWIFT_FIXTURES_DIR="/tmp/fixture_regen" \
DUMP=1 \
go test -tags fixture_dump -run 'TestDump.*' ./internal/authentication/
cd ../..
```

Expected: three JSON files in `/tmp/fixture_regen/`.

- [ ] **Step 4: Diff the re-generated files against committed ones**

```bash
diff /tmp/sk_before.json /tmp/fixture_regen/session_key_vectors.json
diff /tmp/mh_before.json /tmp/fixture_regen/metadata_hmac_vectors.json
diff /tmp/gcm_before.json /tmp/fixture_regen/gcm_roundtrip_vectors.json
```

Expected: no diff output for any of the three (byte-identical). If there's a diff, the patch is incomplete and must be regenerated.

- [ ] **Step 5: Clean up the submodule**

```bash
cd Vendor/tesla-vehicle-command
rm -f internal/authentication/fixture_dump_test.go
git status
cd ../..
rm -rf /tmp/fixture_regen /tmp/sk_before.json /tmp/mh_before.json /tmp/gcm_before.json
```

Expected: submodule clean.

- [ ] **Step 6: No commit**

Verification only.

---

## Task 18: Final `swift test` + confirmation

- [ ] **Step 1: Full test run**

```bash
swift test 2>&1 | tee /tmp/final_test_run.log | tail -30
```

Expected: zero failures. Search the log for `failed` to double-check:

```bash
grep -i "failed\|error:" /tmp/final_test_run.log | grep -v "0 failures" || echo "CLEAN"
```

Expected: prints `CLEAN` (or only innocuous matches like "X tests, 0 failures").

- [ ] **Step 2: Show branch status**

```bash
git log --oneline native-swift ^main 2>/dev/null || git log --oneline -20
git diff --stat main...native-swift 2>/dev/null || git diff --stat HEAD~18
```

Expected: ~18 commits on the branch, touching roughly these counts:

- `Sources/TeslaBLE/Crypto/*.swift`: 5 new files
- `Tests/TeslaBLETests/CryptoVectorTests.swift`: 1 new file
- `Tests/TeslaBLETests/Fixtures/crypto/*.json`: 5 new files
- `Tests/TeslaBLETests/Fixtures/README.md`: 1 new file
- `GoPatches/fixture-dump.patch`: 1 new file
- `Package.swift`: 1 modification

- [ ] **Step 3: No commit**

Phase 0 + 2 is done. The next plan picks up Phase 3 (Session + Dispatcher + Layer B session-replay tests).

---

## Appendix A — Reference: exact Go source locations used in this plan

| Swift component                         | Go source                                        | Key lines                     |
| --------------------------------------- | ------------------------------------------------ | ----------------------------- |
| `CounterWindow.accept`                  | `internal/authentication/window.go`              | 9–50 (updateSlidingWindow)    |
| `CounterWindow` test cases              | `internal/authentication/window_test.go`         | 17–82                         |
| `MetadataHash` TLV format               | `internal/authentication/metadata.go`            | 33–50 (Add), 80–84 (Checksum) |
| `MetadataHash.sha256Context` test case  | `internal/authentication/metadata_test.go`       | 45–65 (TestCheckSum)          |
| `SessionKey.derive` (SHA-1 truncation)  | `internal/authentication/native.go`              | 112–135 (Exchange)            |
| `MetadataHash.hmacContext` subkey       | `internal/authentication/native.go`              | 66–73 (subkey, NewHMAC)       |
| `MessageAuthenticator.seal`             | `internal/authentication/native.go`              | 38–52 (Encrypt)               |
| Tag raw values                          | `Sources/TeslaBLE/Generated/signatures.pb.swift` | 28–95                         |
| SignatureType raw values                | `Sources/TeslaBLE/Generated/signatures.pb.swift` | 97–130                        |
| `labelMessageAuth` / `labelSessionInfo` | `internal/authentication/crypto.go`              | 13–15                         |
| `SharedKeySizeBytes = 16`               | `internal/authentication/ecdh.go`                | 11                            |
| `windowSize = 32`                       | `internal/authentication/crypto.go`              | 21                            |

## Appendix B — Known deltas from Go

1. **Shift guard**: `CounterWindow.accept` explicitly zeros `history` when `shiftCount >= 64` to avoid a Swift shift trap. Go's `<<` on `uint64` saturates to 0 for out-of-range shifts, which is already the intended behavior. The Swift `>= 64` check preserves Go's semantics without the crash.
2. **`SessionKey` naming**: Go uses `NativeSession.key` as a plain `[]byte` field. The Swift port wraps it in a distinct `SessionKey` struct so that type-safety prevents accidentally passing the shared-X bytes or a subkey where an AES-GCM key is expected.
3. **Error enums**: Go wraps errors with `errCodeBadParameter`, `errCodeInvalidSignature`, etc. The Swift port defines fine-grained typed errors per component (`P256ECDH.Error`, `MetadataHash.Error`, `MessageAuthenticator.Error`). They will be collapsed into the top-level `TeslaBLEError` in Phase 5 (see spec §5.1 — this translation happens at the `VehicleSession` layer, which doesn't exist yet).
4. **No `Insecure.SHA1` import concerns**: CryptoKit explicitly puts SHA-1 behind `Insecure.SHA1` to flag it as not suitable for primary collision-resistance use. This plan imports it anyway because the wire format demands SHA-1. No exception is needed — `Insecure.SHA1` is a regular public API.
