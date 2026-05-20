#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>]
EOF
}

version=""
dist_root="dist"

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
app_out="$out_dir/ReviewMonitor.app"

pushd "$repo_root" >/dev/null

rm -rf "$out_dir" "$derived_data_path"
mkdir -p "$out_dir"

xcodebuild build \
  -project Tools/ReviewMonitor/ReviewMonitor.xcodeproj \
  -scheme ReviewMonitor \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data_path" \
  ARCHS="$arch" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

ditto "$derived_data_path/Build/Products/Release/ReviewMonitor.app" "$app_out"

popd >/dev/null

echo "Staged ReviewMonitor $version release artifact at: $app_out"
