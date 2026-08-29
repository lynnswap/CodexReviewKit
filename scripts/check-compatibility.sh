#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_path="$repo_root/Fixtures/CodexReviewKitProductConsumer"
consumer_lock="$fixture_path/Package.resolved"
consumer_lock_created=false

cleanup() {
  if [[ "$consumer_lock_created" == true ]]; then
    rm -f "$consumer_lock"
  fi
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Usage: scripts/check-compatibility.sh [all|consumer|api|mcp]

With no argument, runs all v0.6.2 compatibility gates:
  scripts/check-compatibility.sh
EOF
}

run_consumer() {
  [[ ! -e "$consumer_lock" ]] || {
    echo "Refusing to replace unexpected fixture lockfile: $consumer_lock" >&2
    return 1
  }
  cp "$repo_root/Package.resolved" "$consumer_lock"
  consumer_lock_created=true
  swift run \
    --package-path "$fixture_path" \
    --scratch-path "$repo_root/.build/compatibility-consumer" \
    --build-system swiftbuild \
    --disable-automatic-resolution \
    CodexReviewKitProductConsumer
  rm -f "$consumer_lock"
  consumer_lock_created=false
}

run_api() {
  "$repo_root/scripts/check-public-api-compatibility.sh"
}

run_mcp() {
  swift test \
    --package-path "$repo_root" \
    --build-system swiftbuild \
    --disable-automatic-resolution \
    --no-parallel \
    --filter toolsListMatchesPublishedV062Golden
}

gate="${1:-all}"
case "$gate" in
  all)
    run_consumer
    run_api
    run_mcp
    ;;
  consumer)
    run_consumer
    ;;
  api)
    run_api
    ;;
  mcp)
    run_mcp
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown compatibility gate: $gate" >&2
    usage >&2
    exit 1
    ;;
esac
