# Crypto & Session Fixture Vectors

Deterministic test vectors consumed by `CryptoVectorTests.swift` and `SessionTests.swift`. Each file is committed as ground truth — tests never regenerate them at runtime.

## Layout

- `crypto/window_vectors.json` — sliding replay window cases, hand-transcribed from `Vendor/tesla-vehicle-command/internal/authentication/window_test.go`.
- `crypto/metadata_sha256_vectors.json` — TLV metadata checksums with plain-SHA256 context. One case from Go `TestCheckSum`, four hand-authored edge cases computed via Python `hashlib`.
- `crypto/session_key_vectors.json` — ECDH shared-X → SHA1 → first 16 bytes derivation, 4 vectors produced by a Go dump script.
- `crypto/metadata_hmac_vectors.json` — TLV metadata with HMAC-SHA256 context, covering both `"authenticated command"` (signing) and `"session info"` (handshake) labels. 2 vectors from the same Go dump.
- `crypto/gcm_roundtrip_vectors.json` — AES-GCM-128 seal with a fixed nonce, known AAD, and known plaintext. 3 vectors from the same Go dump.
- `session/signing_aad_vectors.json` — 3 signing-path AAD vectors (SHA256 over TLV metadata), produced from `peer.extractMetadata`.
- `session/response_aad_vectors.json` — 3 response-path AAD vectors, produced from `peer.responseMetadata`.

## Hand-authored vectors

`window_vectors.json` and the first case in `metadata_sha256_vectors.json` are transcribed from Go literal test tables. They do not require running Go — edit the JSON directly and recompute expected hashes via a short Python script if needed.

## Regenerating the Go-sourced vectors

If Tesla updates the proto schema or you need to add new cases to `session_key_vectors`, `metadata_hmac_vectors`, `gcm_roundtrip_vectors`, `session/signing_aad_vectors`, or `session/response_aad_vectors`, follow this recipe:

1. Create a new file at `Vendor/tesla-vehicle-command/internal/authentication/fixture_dump_test.go` with a build tag `//go:build fixture_dump` and test functions that write JSON to `$SWIFT_FIXTURES_DIR`. Use `internal/authentication/metadata.go`, `peer.go`, `native.go`, and `signer.go` as the reference for which fields go where.

2. Each test function should:
   - Gate itself on `if os.Getenv("DUMP") != "1" { t.Skip() }` so it's inert under normal `go test`.
   - Build inputs from deterministic constants (fixed scalars / fixed nonces / fixed verifier name).
   - Call the relevant Go helper (`extractMetadata`, `responseMetadata`, `NativeSession.Encrypt`, etc.) to produce the expected output.
   - Serialize `(inputs, expectedOutputs)` as JSON and write it via `os.Create`/`json.NewEncoder`.

3. Run the dump:

   ```bash
   cd Vendor/tesla-vehicle-command
   SWIFT_FIXTURES_DIR="$PWD/../../Tests/TeslaBLETests/Fixtures/crypto" \
     DUMP=1 \
     go test -tags fixture_dump -run 'TestDump.*' ./internal/authentication/
   rm -f internal/authentication/fixture_dump_test.go
   cd ../..
   ```

4. Delete the dump file from the submodule working tree before anything else — it must never be committed upstream. Verify the submodule is clean with `git -C Vendor/tesla-vehicle-command status`.

5. Inspect the diff in `Tests/TeslaBLETests/Fixtures/` and commit whichever JSON files actually changed.

A reference dump file was used during Phase 0+2 of the rewrite and produced all the Go-sourced vectors currently in this directory. That file is no longer stored in the repository (Go tooling is deliberately absent from this package); recreate it from scratch if needed using the recipe above. The Go reference is under 300 lines of test code.
