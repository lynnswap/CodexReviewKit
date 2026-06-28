#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-asset.sh --version <tag> --repo <owner/name> --expected-team-id <team-id> [--download-dir <dir>]
EOF
}

version=""
repo="${GITHUB_REPOSITORY:-}"
download_dir="${RUNNER_TEMP:-/tmp}/codex-reviewkit-release-verification"
expected_team_id="${EXPECTED_DEVELOPER_ID_TEAM_ID:-}"
app_name="CodexReviewMonitor"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --download-dir)
      download_dir="${2:-}"
      shift 2
      ;;
    --expected-team-id)
      expected_team_id="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$version" || -z "$repo" || -z "$expected_team_id" ]]; then
  usage
  exit 1
fi

if [[ ! "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Expected Developer ID Team ID must be a 10-character Apple team identifier." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required to download the release asset." >&2
  exit 1
fi

asset_name="${app_name}_${version#v}.dmg"
rm -rf "$download_dir"
mkdir -p "$download_dir"

gh release download "$version" \
  --repo "$repo" \
  --pattern "$asset_name" \
  --dir "$download_dir" \
  --clobber

archive_path="$download_dir/$asset_name"
if [[ ! -f "$archive_path" ]]; then
  echo "Expected release asset was not downloaded: $asset_name" >&2
  exit 1
fi

require_developer_id_signature() {
  local path="$1"
  local label="$2"
  local signature

  codesign --verify --verbose=2 "$path"
  signature="$(codesign -dv --verbose=4 "$path" 2>&1 || true)"

  if ! grep -q '^Authority=Developer ID Application:' <<<"$signature"; then
    echo "$label is not signed with a Developer ID Application certificate." >&2
    exit 1
  fi

  if ! grep -q "^TeamIdentifier=${expected_team_id}$" <<<"$signature"; then
    echo "$label is not signed by expected Team ID ${expected_team_id}." >&2
    exit 1
  fi
}

require_developer_id_signature "$archive_path" "$asset_name"
xcrun stapler validate "$archive_path"
spctl -a -vv -t open --context context:primary-signature "$archive_path"

mount_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-reviewkit-release.XXXXXX")"
mount_point="$mount_root/mount"
mkdir -p "$mount_point"

cleanup() {
  hdiutil detach "$mount_point" >/dev/null 2>&1 || hdiutil detach -force "$mount_point" >/dev/null 2>&1 || true
  rm -rf "$mount_root"
}
trap cleanup EXIT

hdiutil attach \
  -nobrowse \
  -readonly \
  -mountpoint "$mount_point" \
  "$archive_path"

app_path="$mount_point/${app_name}.app"
if [[ ! -d "$app_path" ]]; then
  echo "Release DMG does not contain ${app_name}.app at the volume root." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
require_developer_id_signature "$app_path" "${app_name}.app"

echo "Verified release asset: $asset_name"
