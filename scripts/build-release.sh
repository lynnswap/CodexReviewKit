#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>] [--signing-identity <identity>]
EOF
}

version=""
dist_root="dist"
signing_identity="${CODE_SIGN_IDENTITY:-}"
app_name="CodexReviewMonitor"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --signing-identity)
      signing_identity="${2:-}"
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

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi

arch="arm64"
derived_data_path="$repo_root/.build/release-$arch"
out_dir="$dist_base/$arch"
app_out="$out_dir/${app_name}.app"

pushd "$repo_root" >/dev/null

rm -rf "$out_dir" "$derived_data_path"
mkdir -p "$out_dir"

xcodebuild build \
  -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj \
  -scheme CodexReviewMonitor \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data_path" \
  ARCHS="$arch" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

ditto "$derived_data_path/Build/Products/Release/${app_name}.app" "$app_out"

if [[ -n "$signing_identity" ]]; then
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$app_out"
  codesign --verify --deep --strict --verbose=2 "$app_out"
else
  codesign \
    --force \
    --deep \
    --sign - \
    "$app_out"
  codesign --verify --deep --strict --verbose=2 "$app_out"
  echo "Warning: ${app_name}.app was ad-hoc signed for local inspection only. Downloaded release archives will be blocked by Gatekeeper." >&2
fi

popd >/dev/null

echo "Staged ${app_name} $version release artifact at: $app_out"
