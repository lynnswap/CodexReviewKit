#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--dist-root <dir>] [--output-dir <dir>] [--signing-identity <identity>] [--notary-profile <profile>]
EOF
}

version=""
dist_root="dist"
output_dir="release"
signing_identity="${CODE_SIGN_IDENTITY:-}"
notary_profile="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
app_name="CodexReviewMonitor"

detach_volume() {
  local mount_path="$1"
  hdiutil detach "$mount_path" >/dev/null 2>&1 || hdiutil detach -force "$mount_path" >/dev/null 2>&1
}

detach_mounted_release_volumes() {
  local mounted_volume
  while IFS= read -r mounted_volume; do
    [[ -d "$mounted_volume" ]] || continue
    if [[ -e "$mounted_volume/${app_name}.app" || -e "$mounted_volume/.background/background.png" ]]; then
      echo "Detaching existing ${app_name} mount: $mounted_volume" >&2
      detach_volume "$mounted_volume"
    fi
  done < <(find /Volumes -maxdepth 1 \( -name "$app_name" -o -name "$app_name [0-9]*" \) -print 2>/dev/null)
}

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
    --signing-identity)
      signing_identity="${2:-}"
      shift 2
      ;;
    --notary-profile)
      notary_profile="${2:-}"
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
if [[ -n "$notary_profile" && -z "$signing_identity" ]]; then
  echo "--notary-profile requires --signing-identity so the DMG can be signed before notarization." >&2
  usage
  exit 1
fi
if [[ -n "$notary_profile" && "$signing_identity" != Developer\ ID\ Application:* ]]; then
  echo "--notary-profile requires a Developer ID Application signing identity." >&2
  echo "Apple Development identities are only valid for local development builds." >&2
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

app_path="$dist_base/arm64/${app_name}.app"
binary_path="$app_path/Contents/MacOS/${app_name}"
asset_version="${version#v}"
archive_path="$output_base/${app_name}_${asset_version}.dmg"
rw_archive_path="$output_base/${app_name}_${asset_version}.rw.dmg"

for path in "$app_path" "$binary_path"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing staged artifact: $path" >&2
    exit 1
  fi
done

if [[ "$(lipo -archs "$binary_path")" != "arm64" ]]; then
  echo "${app_name} is not arm64-only." >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
  echo "${app_name}.app has an invalid code signature." >&2
  exit 1
fi
app_signature="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
if ! grep -q '^Authority=Developer ID Application:' <<<"$app_signature"; then
  if [[ -n "$notary_profile" ]]; then
    echo "${app_name}.app must be Developer ID signed before packaging for notarization." >&2
    exit 1
  fi
  echo "Warning: ${app_name}.app is not Developer ID signed. Downloaded release archives will be blocked by Gatekeeper." >&2
fi

detach_mounted_release_volumes

mkdir -p "$output_base"
rm -f "$archive_path" "$rw_archive_path"

dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/reviewmonitor-dmg.XXXXXX")"
mount_point=""
cleanup() {
  if [[ -n "$mount_point" && -d "$mount_point" ]]; then
    detach_volume "$mount_point" || true
    rmdir "$mount_point" >/dev/null 2>&1 || true
  fi
  rm -rf "$dmg_root" "$rw_archive_path"
}
trap cleanup EXIT

generate_dmg_background() {
  local output_path="$1"
  python3 - "$output_path" <<'PY'
import struct
import sys
import zlib

output_path = sys.argv[1]
width, height = 480, 540
white = (255, 255, 255)
panel = (220, 228, 250)

def inside_rounded_rect(x, y, left, top, right, bottom, radius):
    if x < left or x >= right or y < top or y >= bottom:
        return False
    cx = left + radius if x < left + radius else right - radius - 1 if x >= right - radius else x
    cy = top + radius if y < top + radius else bottom - radius - 1 if y >= bottom - radius else y
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= radius * radius

def inside_triangle(x, y, points):
    (x1, y1), (x2, y2), (x3, y3) = points
    denominator = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
    a = ((y2 - y3) * (x - x3) + (x3 - x2) * (y - y3)) / denominator
    b = ((y3 - y1) * (x - x3) + (x1 - x3) * (y - y3)) / denominator
    c = 1 - a - b
    return a >= 0 and b >= 0 and c >= 0

def inside_arrow_cutout(x, y):
    shaft = 229 <= x <= 251 and 285 <= y <= 306
    head = inside_triangle(x, y, ((215, 307), (265, 307), (240, 332)))
    return shaft or head

rows = []
for y in range(height):
    row = bytearray()
    for x in range(width):
        color = white
        if inside_rounded_rect(x, y, 90, 285, 390, 485, 4):
            color = panel
        if inside_arrow_cutout(x, y):
            color = white
        row.extend(color)
    rows.append(b"\x00" + bytes(row))

def chunk(kind, payload):
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
with open(output_path, "wb") as file:
    file.write(png)
PY
}

ditto "$app_path" "$dmg_root/${app_name}.app"
mkdir -p "$dmg_root/.background"
generate_dmg_background "$dmg_root/.background/background.png"
applications_alias_name="$(python3 - <<'PY'
print("\u200b", end="")
PY
)"
ln -s /Applications "$dmg_root/$applications_alias_name"

hdiutil create \
  -volname "$app_name" \
  -srcfolder "$dmg_root" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$rw_archive_path"

mount_point="$(mktemp -d "${TMPDIR:-/tmp}/reviewmonitor-mount.XXXXXX")"
hdiutil attach \
  -nobrowse \
  -readwrite \
  -mountpoint "$mount_point" \
  "$rw_archive_path"

SetFile -a V "$mount_point/.background" 2>/dev/null || true

if osascript - "$mount_point" "$applications_alias_name" <<'OSA'
on run argv
  set mountPoint to item 1 of argv
  set applicationsAliasName to item 2 of argv
  set volumeFolder to POSIX file mountPoint as alias
  set backgroundFile to POSIX file (mountPoint & "/.background/background.png") as alias

  tell application "Finder"
    open volumeFolder
    delay 0.2

    set containerWindow to container window of volumeFolder
    set current view of containerWindow to icon view
    try
      set toolbar visible of containerWindow to false
    end try
    try
      set statusbar visible of containerWindow to false
    end try
    set bounds of containerWindow to {120, 100, 600, 662}

    set viewOptions to icon view options of containerWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to backgroundFile

    set position of item "CodexReviewMonitor.app" of volumeFolder to {240, 122}
    set position of item applicationsAliasName of volumeFolder to {240, 387}
    set selection to {}

    update volumeFolder without registering applications
    delay 1
    try
      close containerWindow
    end try
  end tell
end run
OSA
then
  :
else
  echo "Finder automation failed while writing the DMG window layout." >&2
  echo "Run the release shell from a logged-in local macOS session and grant Automation permission to the invoking terminal." >&2
  exit 1
fi

bless --folder "$mount_point" --openfolder "$mount_point" 2>/dev/null || true
sync
if [[ ! -f "$mount_point/.DS_Store" ]]; then
  echo "Finder did not persist the DMG layout metadata." >&2
  exit 1
fi

detach_volume "$mount_point"
rmdir "$mount_point" 2>/dev/null || true
mount_point=""

hdiutil convert \
  "$rw_archive_path" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$archive_path"

if [[ -n "$signing_identity" ]]; then
  codesign \
    --force \
    --timestamp \
    --sign "$signing_identity" \
    "$archive_path"
  codesign --verify --verbose=2 "$archive_path"
else
  echo "Warning: ${app_name} DMG was not signed. Downloaded release archives will be blocked by Gatekeeper." >&2
fi

if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$archive_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$archive_path"
  xcrun stapler validate "$archive_path"
  spctl -a -vv -t open --context context:primary-signature "$archive_path"
else
  # Unsigned/unnotarized archives are only for local layout checks. Public downloads need notarization,
  # otherwise macOS may report the app as damaged instead of showing a normal Gatekeeper prompt.
  echo "Warning: ${app_name} DMG was not notarized. Public downloads may be reported as damaged by Gatekeeper." >&2
fi

echo "Created release archive: $archive_path"
