#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--dist-root <dir>] [--output-dir <dir>]
EOF
}

version=""
dist_root="dist"
output_dir="release"

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
    --output-dir)
      output_dir="${2:-}"
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
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi

app_path="$dist_base/arm64/ReviewMonitor.app"
binary_path="$app_path/Contents/MacOS/ReviewMonitor"
asset_version="${version#v}"
archive_path="$output_base/ReviewMonitor_${asset_version}.dmg"

for path in "$app_path" "$binary_path"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing staged artifact: $path" >&2
    exit 1
  fi
done

if [[ "$(lipo -archs "$binary_path")" != "arm64" ]]; then
  echo "ReviewMonitor is not arm64-only." >&2
  exit 1
fi

mkdir -p "$output_base"
rm -f "$archive_path"

dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/reviewmonitor-dmg.XXXXXX")"
trap 'rm -rf "$dmg_root"' EXIT

ditto "$app_path" "$dmg_root/ReviewMonitor.app"
ln -s /Applications "$dmg_root/Applications"

hdiutil create \
  -volname "ReviewMonitor" \
  -srcfolder "$dmg_root" \
  -ov \
  -format UDZO \
  "$archive_path"

echo "Created release archive: $archive_path"
