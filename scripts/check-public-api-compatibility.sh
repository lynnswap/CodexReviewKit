#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline_dir="$repo_root/scripts/compatibility-baselines/v0.6.2"
baseline_path="$baseline_dir/public-api.json"
metadata_path="$baseline_dir/metadata.json"
scratch_path="$repo_root/.build/compatibility-api"
modules=(CodexReview CodexReviewHost ReviewUI TextTransitions)

fail() {
  echo "Public API compatibility check failed: $*" >&2
  exit 1
}

for command in python3 shasum swift xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || fail "required command '$command' is unavailable."
done

[[ -f "$baseline_path" ]] || fail "missing baseline: $baseline_path"
[[ -f "$metadata_path" ]] || fail "missing metadata: $metadata_path"

metadata_values="$(python3 - "$metadata_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    metadata = json.load(file)

required = [
    "swiftVersion",
    "xcodeVersion",
    "macOSSDKVersion",
    "architecture",
    "swiftAPIDigesterSHA256",
    "baselineSHA256",
]
missing = [key for key in required if not metadata.get(key)]
if missing:
    raise SystemExit(f"metadata is missing required fields: {', '.join(missing)}")

expected_modules = ["CodexReview", "CodexReviewHost", "ReviewUI", "TextTransitions"]
if metadata.get("modules") != expected_modules:
    raise SystemExit(f"metadata modules must be exactly {expected_modules}")

print("\t".join(str(metadata[key]) for key in required))
PY
)" || fail "could not validate $metadata_path"

IFS=$'\t' read -r expected_swift expected_xcode expected_sdk expected_arch expected_digester_sha expected_baseline_sha <<<"$metadata_values"

current_swift="$(swift --version 2>&1 | paste -sd '|' -)"
current_xcode="$(xcodebuild -version | paste -sd '|' -)"
current_sdk="$(xcrun --sdk macosx --show-sdk-version)"
current_arch="$(uname -m)"
digester_path="$(xcrun --find swift-api-digester)"
current_digester_sha="$(shasum -a 256 "$digester_path" | awk '{print $1}')"
current_baseline_sha="$(shasum -a 256 "$baseline_path" | awk '{print $1}')"

[[ "$current_swift" == "$expected_swift" ]] || fail "Swift toolchain mismatch. Expected '$expected_swift'; found '$current_swift'."
[[ "$current_xcode" == "$expected_xcode" ]] || fail "Xcode mismatch. Expected '$expected_xcode'; found '$current_xcode'."
[[ "$current_sdk" == "$expected_sdk" ]] || fail "macOS SDK mismatch. Expected '$expected_sdk'; found '$current_sdk'."
[[ "$current_arch" == "$expected_arch" ]] || fail "architecture mismatch. Expected '$expected_arch'; found '$current_arch'."
[[ "$current_digester_sha" == "$expected_digester_sha" ]] || fail "swift-api-digester binary differs from the recorded toolchain."
[[ "$current_baseline_sha" == "$expected_baseline_sha" ]] || fail "tracked baseline checksum differs from metadata."

echo "Building public products for API inspection..."
swift build \
  --build-system swiftbuild \
  --disable-automatic-resolution \
  --scratch-path "$scratch_path"

intermediates_dir="$scratch_path/out/Intermediates.noindex"

for module in "${modules[@]}"; do
  module_path="$(find "$intermediates_dir" -type f -name "$module.swiftmodule" -print -quit)"
  [[ -n "$module_path" ]] || fail "missing built module $module below $intermediates_dir."
done

search_args=()
while IFS= read -r module_path; do
  search_args+=(-I "$(dirname "$module_path")")
done < <(find "$intermediates_dir" -type f -name '*.swiftmodule' | LC_ALL=C sort)
while IFS= read -r module_map; do
  search_args+=(-Xcc "-fmodule-map-file=$module_map")
done < <(python3 - "$intermediates_dir/GeneratedModuleMaps" "$scratch_path/checkouts" <<'PY'
import os
import re
import sys

module_maps = {}
for root in sys.argv[1:]:
    for directory, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".modulemap"):
                continue
            path = os.path.abspath(os.path.join(directory, name))
            with open(path, encoding="utf-8") as file:
                contents = file.read()
            if "-Swift.h" in contents:
                continue
            match = re.search(
                r"^(?:framework\s+)?module\s+([A-Za-z_][A-Za-z0-9_]*)",
                contents,
                re.MULTILINE,
            )
            if not match:
                continue
            module = match.group(1)
            priority = (0 if "GeneratedModuleMaps" in path else 1, path)
            previous = module_maps.get(module)
            if previous is None or priority < previous[0]:
                module_maps[module] = (priority, path)

for module in sorted(module_maps):
    print(module_maps[module][1])
PY
)

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-public-api.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
raw_path="$temporary_dir/raw.json"
current_path="$temporary_dir/public-api.json"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
module_args=()
for module in "${modules[@]}"; do
  module_args+=(-module "$module")
done

echo "Capturing public API with swift-api-digester..."
xcrun swift-api-digester \
  -dump-sdk \
  "${module_args[@]}" \
  -swift-only \
  -avoid-location \
  -avoid-tool-args \
  -abort-on-module-fail \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -swift-version 6 \
  "${search_args[@]}" \
  -o "$raw_path"

python3 - "$raw_path" "$current_path" "${modules[@]}" <<'PY'
import json
import sys

raw_path, output_path, *module_names = sys.argv[1:]
modules = set(module_names)

with open(raw_path, encoding="utf-8") as file:
    document = json.load(file)

def prune(value):
    if isinstance(value, list):
        return [candidate for item in value if (candidate := prune(item)) is not None]
    if not isinstance(value, dict):
        return value
    if value.get("isInternal") is True or value.get("kind") == "Import":
        return None

    result = {}
    for key, item in value.items():
        if key == "isExternal":
            continue
        candidate = prune(item)
        if candidate is not None:
            result[key] = candidate
    return result

def declared_modules(value):
    found = set()
    if isinstance(value, list):
        for item in value:
            found.update(declared_modules(item))
    elif isinstance(value, dict):
        module_name = value.get("moduleName")
        if module_name in modules:
            found.add(module_name)
        for item in value.values():
            found.update(declared_modules(item))
    return found

root = document.get("ABIRoot")
if not isinstance(root, dict) or not isinstance(root.get("children"), list):
    raise SystemExit("swift-api-digester output does not contain ABIRoot.children")

canonical_root = prune(root)
canonical_children = []
for child in canonical_root.get("children", []):
    if child.get("moduleName") in modules or declared_modules(child):
        canonical_children.append(child)
canonical_root["children"] = canonical_children

seen_modules = declared_modules(canonical_root)
if seen_modules != modules:
    missing = sorted(modules - seen_modules)
    unexpected = sorted(seen_modules - modules)
    raise SystemExit(f"public module inventory mismatch; missing={missing}, unexpected={unexpected}")

with open(output_path, "w", encoding="utf-8") as file:
    json.dump({"ABIRoot": canonical_root}, file, indent=2, sort_keys=True)
    file.write("\n")
PY

if cmp -s "$baseline_path" "$current_path"; then
  rm -f "$scratch_path/current-public-api.json"
  echo "Public API compatibility passed for: ${modules[*]}"
  exit 0
fi

cp "$current_path" "$scratch_path/current-public-api.json"
echo "Public API drift detected. Current canonical dump: $scratch_path/current-public-api.json" >&2
echo "swift-api-digester diagnostics:" >&2
xcrun swift-api-digester \
  -diagnose-sdk \
  -baseline-path "$baseline_path" \
  "${module_args[@]}" \
  -swift-only \
  -avoid-location \
  -avoid-tool-args \
  -abort-on-module-fail \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -swift-version 6 \
  "${search_args[@]}" || true
diff -u "$baseline_path" "$current_path" | sed -n '1,240p' >&2 || true
fail "the canonical v0.6.2 public surface changed. An accepted change requires an explicit recovery-design entry and baseline update."
