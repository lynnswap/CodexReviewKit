#!/bin/bash

set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly TARGET="arm64-apple-macosx26.0"
readonly SCRATCH_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/text-transitions-api.XXXXXX")"
readonly DEBUG_API_SHA256="1996a5c9d5bb57367caec91fdccae66608c68c2a1ac9d6d5b9f7c5bb36260555"
readonly RELEASE_API_SHA256="e749f705ed082ae4d54ecdc2a812add5aaf9efc02c13e656c7917dc5e27f392a"

cleanup() {
  rm -rf "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT

mkdir -p "$SCRATCH_DIRECTORY/debug" "$SCRATCH_DIRECTORY/release"

sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$REPOSITORY_ROOT/Sources/TextTransitions" -name '*.swift' -type f -print | sort)
if [[ ${#sources[@]} -eq 0 ]]; then
  echo "No TextTransitions sources found" >&2
  exit 1
fi

xcrun swiftc "${sources[@]}" \
  -parse-as-library \
  -emit-module \
  -module-name TextTransitions \
  -swift-version 6 \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -Onone \
  -D SWIFT_PACKAGE \
  -D DEBUG \
  -enable-testing \
  -emit-module-path "$SCRATCH_DIRECTORY/debug/TextTransitions.swiftmodule"

xcrun swiftc "${sources[@]}" \
  -parse-as-library \
  -emit-module \
  -module-name TextTransitions \
  -swift-version 6 \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -O \
  -D SWIFT_PACKAGE \
  -emit-module-path "$SCRATCH_DIRECTORY/release/TextTransitions.swiftmodule"

dump_api() {
  local configuration="$1"

  xcrun swift-api-digester \
    -dump-sdk \
    -module TextTransitions \
    -swift-only \
    -avoid-location \
    -avoid-tool-args \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -I "$SCRATCH_DIRECTORY/$configuration" \
    -o "$SCRATCH_DIRECTORY/$configuration.json"
}

verify_api() {
  local configuration="$1"
  local expected_sha256="$2"
  local actual_sha256

  actual_sha256="$(shasum -a 256 "$SCRATCH_DIRECTORY/$configuration.json" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "TextTransitions $configuration API changed" >&2
    echo "expected: $expected_sha256" >&2
    echo "actual:   $actual_sha256" >&2
    echo "generated API: $SCRATCH_DIRECTORY/$configuration.json" >&2
    trap - EXIT
    exit 1
  fi

  echo "TextTransitions $configuration API verified: $actual_sha256"
}

dump_api debug
dump_api release
verify_api debug "$DEBUG_API_SHA256"
verify_api release "$RELEASE_API_SHA256"
