.PHONY: format build test clean proto

# Format Swift sources with SwiftFormat and Markdown/JSON/YAML with Prettier.
# Vendor/ is excluded via .swiftformat and .prettierignore.
format:
	prettier --write "**/*.{md,json,yml,yaml}"
	shfmt -w -i 4 -ci scripts/
	swiftformat .

build:
	swift build

test:
	swift test

# Regenerate Sources/TeslaBLE/Generated/*.pb.swift from the .proto sources in
# the Vendor/tesla-vehicle-command submodule. Requires protoc and
# protoc-gen-swift on PATH. Only needed when the upstream proto schema changes.
proto:
	./scripts/generate-protos.sh

clean:
	swift package clean
	rm -rf .build
