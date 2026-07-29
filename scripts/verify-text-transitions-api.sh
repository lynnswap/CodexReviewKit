#!/bin/bash

set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly TARGET="arm64-apple-macosx26.0"
readonly SCRATCH_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/text-transitions-api.XXXXXX")"
readonly DEBUG_API_SHA256="8b6f247ace04cfbdb38c131d935f9b8d6dcbfbb0409282ebb69d28a89aaa8a03"
readonly RELEASE_API_SHA256="51ef185f3a36321bc6038b578f0eb3e1b9260c4bfa7af4e7e9dfdc858082d16b"

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
  -enable-library-evolution \
  -emit-module-interface-path "$SCRATCH_DIRECTORY/debug/TextTransitions.swiftinterface" \
  -emit-module-path "$SCRATCH_DIRECTORY/debug/TextTransitions.swiftmodule" \
  -module-name TextTransitions \
  -swift-version 6 \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -Onone \
  -D SWIFT_PACKAGE \
  -D DEBUG \
  -enable-testing

xcrun swiftc "${sources[@]}" \
  -parse-as-library \
  -emit-module \
  -enable-library-evolution \
  -emit-module-interface-path "$SCRATCH_DIRECTORY/release/TextTransitions.swiftinterface" \
  -emit-module-path "$SCRATCH_DIRECTORY/release/TextTransitions.swiftmodule" \
  -module-name TextTransitions \
  -swift-version 6 \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -O \
  -D SWIFT_PACKAGE

normalize_api() {
  local configuration="$1"

  sed '/^\/\/ swift-/d' \
    "$SCRATCH_DIRECTORY/$configuration/TextTransitions.swiftinterface" \
    > "$SCRATCH_DIRECTORY/$configuration.normalized.swiftinterface"
}

verify_api() {
  local configuration="$1"
  local expected_sha256="$2"
  local actual_sha256

  actual_sha256="$(shasum -a 256 "$SCRATCH_DIRECTORY/$configuration.normalized.swiftinterface" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "TextTransitions $configuration API changed" >&2
    echo "expected: $expected_sha256" >&2
    echo "actual:   $actual_sha256" >&2
    echo "generated API: $SCRATCH_DIRECTORY/$configuration.normalized.swiftinterface" >&2
    trap - EXIT
    exit 1
  fi

  echo "TextTransitions $configuration API verified: $actual_sha256"
}

normalize_api debug
normalize_api release
verify_api debug "$DEBUG_API_SHA256"
verify_api release "$RELEASE_API_SHA256"
