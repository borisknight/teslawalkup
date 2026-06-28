#!/usr/bin/env bash
# Regenerate Swift .pb.swift files from tesla-vehicle-command .proto sources.
#
# Inputs:  Vendor/tesla-vehicle-command/pkg/protocol/protobuf/*.proto (git submodule)
# Outputs: Sources/TeslaBLE/Generated/*.pb.swift
#
# Prerequisites:
#   - protoc         (brew install protobuf)
#   - protoc-gen-swift (brew install swift-protobuf)
#
# Run from the repo root:  ./scripts/generate-protos.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTO_SRC="$REPO_ROOT/Vendor/tesla-vehicle-command/pkg/protocol/protobuf"
SWIFT_OUT="$REPO_ROOT/Sources/TeslaBLE/Generated"

if [[ ! -d "$PROTO_SRC" ]]; then
    echo "error: proto source directory not found: $PROTO_SRC" >&2
    echo "did you run 'git submodule update --init'?" >&2
    exit 1
fi

if ! command -v protoc >/dev/null 2>&1; then
    echo "error: protoc not found. Install with: brew install protobuf" >&2
    exit 1
fi

if ! command -v protoc-gen-swift >/dev/null 2>&1; then
    echo "error: protoc-gen-swift not found. Install with: brew install swift-protobuf" >&2
    exit 1
fi

mkdir -p "$SWIFT_OUT"

# Generate all .proto files in one invocation.
#   --swift_opt=Visibility=Public   — make generated types part of TeslaBLE's public-ish surface
#                                     so Commands/, Session/ etc. can reference them internally
#   --swift_opt=FileNaming=DropPath — emit <basename>.pb.swift flat under $SWIFT_OUT
protoc \
    --proto_path="$PROTO_SRC" \
    --swift_out="$SWIFT_OUT" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=DropPath \
    "$PROTO_SRC"/*.proto

echo "generated:"
ls -1 "$SWIFT_OUT"/*.pb.swift | sed "s|^$REPO_ROOT/||"

cat <<EOF

next steps:
  1. Inspect git diff for unexpected changes (field renames, removed types).
  2. Run 'swift build' — if any TeslaBLE source file references a type that
     disappeared, the compile error points to the affected command encoder /
     decoder. Adapt them.
  3. Run 'swift test' — 91 tests should still pass unless the proto wire
     format itself changed (rare). Any failures indicate a real upstream
     change that needs a manual port.
  4. Commit the regenerated files together with any encoder / decoder updates.
EOF
