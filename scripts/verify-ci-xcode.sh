#!/usr/bin/env bash

set -euo pipefail

: "${EXPECTED_XCODE_VERSION_LINE:?EXPECTED_XCODE_VERSION_LINE is required}"
: "${EXPECTED_XCODE_BUILD_LINE:?EXPECTED_XCODE_BUILD_LINE is required}"

actual_version="$(xcodebuild -version)"
if ! grep -Fxq "$EXPECTED_XCODE_VERSION_LINE" <<< "$actual_version" \
  || ! grep -Fxq "$EXPECTED_XCODE_BUILD_LINE" <<< "$actual_version"
then
  echo "Unexpected Xcode toolchain" >&2
  echo "expected:" >&2
  printf '%s\n%s\n' "$EXPECTED_XCODE_VERSION_LINE" "$EXPECTED_XCODE_BUILD_LINE" >&2
  echo "actual:" >&2
  printf '%s\n' "$actual_version" >&2
  exit 1
fi

printf '%s\n' "$actual_version"
swift --version

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  cache_id="$(printf '%s' "$actual_version" | tr '\n ' '--' | tr -cd '[:alnum:]._-')"
  echo "cache-id=$cache_id" >> "$GITHUB_OUTPUT"
fi
