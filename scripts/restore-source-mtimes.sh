#!/usr/bin/env bash

set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TIMESTAMP_FLOOR=946684800
readonly TIMESTAMP_SPAN=631152000

cd "$REPOSITORY_ROOT"

# Restored build records compare input mtimes. A content-derived historical
# timestamp keeps unchanged inputs stable across runners while making a changed
# blob invalidate the incremental record.
while IFS= read -r -d '' tracked_file; do
  blob="$(git rev-parse "HEAD:$tracked_file")"
  if [[ -z "$blob" ]]; then
    echo "No blob found for tracked build input: $tracked_file" >&2
    exit 1
  fi

  timestamp=$((TIMESTAMP_FLOOR + (16#${blob:0:8} % TIMESTAMP_SPAN)))
  touch -t "$(date -r "$timestamp" +%Y%m%d%H%M.%S)" "$tracked_file"
done < <(
  git ls-files -z -- \
    Package.swift \
    Package.resolved \
    Sources \
    Tests \
    Tools
)
