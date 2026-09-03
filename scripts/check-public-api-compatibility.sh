#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline_dir="$repo_root/scripts/compatibility-baselines/v0.6.2"
metadata_path="$baseline_dir/metadata.json"
artifact_dir="$repo_root/.build/compatibility-api"
modules=(CodexReview CodexReviewHost ReviewUI TextTransitions)

fail() {
  echo "Public API compatibility check failed: $*" >&2
  exit 1
}

for command in awk cmp diff find git mktemp python3 shasum swift tar uname xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || fail "required command '$command' is unavailable."
done

[[ -f "$metadata_path" ]] || fail "missing metadata: $metadata_path"

metadata_values="$(python3 - "$metadata_path" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    metadata = json.load(file)

required = [
    "baseline",
    "captureRevision",
    "digesterInvocation",
    "modules",
    "publishedReleaseRevision",
    "recoveryDesignRevision",
    "swiftPMBuildSystem",
    "targetTriple",
    "swiftLanguageVersion",
]
missing = [key for key in required if not metadata.get(key)]
if missing:
    raise SystemExit(f"metadata is missing required fields: {', '.join(missing)}")

expected_modules = ["CodexReview", "CodexReviewHost", "ReviewUI", "TextTransitions"]
if metadata.get("modules") != expected_modules:
    raise SystemExit(f"metadata modules must be exactly {expected_modules}")

for key in ["captureRevision", "publishedReleaseRevision", "recoveryDesignRevision"]:
    if re.fullmatch(r"[0-9a-f]{40}", str(metadata[key])) is None:
        raise SystemExit(f"metadata {key} must be a full lowercase commit SHA")

capture_revision = str(metadata["captureRevision"])

print("\t".join([
    capture_revision,
    str(metadata["swiftPMBuildSystem"]),
    str(metadata["targetTriple"]),
    str(metadata["swiftLanguageVersion"]),
]))
PY
)" || fail "could not validate $metadata_path"

IFS=$'\t' read -r capture_revision build_system target_triple swift_language_version <<<"$metadata_values"
[[ "$build_system" == "swiftbuild" ]] || fail "unsupported SwiftPM build system '$build_system'."

git -C "$repo_root" cat-file -e "${capture_revision}^{commit}" 2>/dev/null \
  || fail "capture revision $capture_revision is unavailable; check out full Git history before running this gate."
git -C "$repo_root" merge-base --is-ancestor "$capture_revision" HEAD \
  || fail "capture revision $capture_revision is not an ancestor of the current checkout."

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-public-api.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

baseline_source="$temporary_dir/baseline-source"
mkdir -p "$baseline_source"
git -C "$repo_root" archive --format=tar "$capture_revision" | tar -xf - -C "$baseline_source"

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
digester_path="$(xcrun --find swift-api-digester)"
echo "Public API comparison environment:"
swift --version
xcodebuild -version
echo "macOS SDK: $(xcrun --sdk macosx --show-sdk-version)"
echo "Architecture: $(uname -m)"
echo "swift-api-digester SHA-256: $(shasum -a 256 "$digester_path" | awk '{print $1}')"
module_args=()
for module in "${modules[@]}"; do
  module_args+=(-module "$module")
done
diagnostic_search_args=()

capture_api() {
  local label="$1"
  local source_root="$2"
  local scratch_path="$3"
  local raw_path="$4"
  local canonical_path="$5"
  local retain_search_args="$6"
  local intermediates_dir="$scratch_path/out/Intermediates.noindex"

  echo "Building public products for $label..."
  swift build \
    --package-path "$source_root" \
    --build-system "$build_system" \
    --disable-automatic-resolution \
    --scratch-path "$scratch_path"

  for module in "${modules[@]}"; do
    local module_path
    module_path="$(find "$intermediates_dir" -type f -name "$module.swiftmodule" -print -quit)"
    [[ -n "$module_path" ]] || fail "missing built module $module below $intermediates_dir."
  done

  local search_args=()
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

  echo "Capturing public API for $label with swift-api-digester..."
  xcrun swift-api-digester \
    -dump-sdk \
    "${module_args[@]}" \
    -swift-only \
    -avoid-location \
    -avoid-tool-args \
    -abort-on-module-fail \
    -sdk "$sdk_path" \
    -target "$target_triple" \
    -swift-version "$swift_language_version" \
    "${search_args[@]}" \
    -o "$raw_path"

  python3 - "$raw_path" "$canonical_path" "${modules[@]}" <<'PY'
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

  if [[ "$retain_search_args" == true ]]; then
    diagnostic_search_args=("${search_args[@]}")
  fi
}

baseline_scratch="$temporary_dir/baseline-build"
current_scratch="$artifact_dir/current-build"
baseline_raw="$temporary_dir/baseline-raw.json"
current_raw="$temporary_dir/current-raw.json"
baseline_path="$temporary_dir/baseline-public-api.json"
current_path="$temporary_dir/current-public-api.json"

capture_api \
  "approved capture $capture_revision" \
  "$baseline_source" \
  "$baseline_scratch" \
  "$baseline_raw" \
  "$baseline_path" \
  false
capture_api \
  "current checkout" \
  "$repo_root" \
  "$current_scratch" \
  "$current_raw" \
  "$current_path" \
  true

if cmp -s "$baseline_path" "$current_path"; then
  rm -f "$artifact_dir/baseline-public-api.json" "$artifact_dir/current-public-api.json"
  echo "Public API compatibility passed for: ${modules[*]}"
  exit 0
fi

mkdir -p "$artifact_dir"
cp "$baseline_path" "$artifact_dir/baseline-public-api.json"
cp "$current_path" "$artifact_dir/current-public-api.json"
echo "Public API drift detected." >&2
echo "Approved capture dump: $artifact_dir/baseline-public-api.json" >&2
echo "Current canonical dump: $artifact_dir/current-public-api.json" >&2
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
  -target "$target_triple" \
  -swift-version "$swift_language_version" \
  "${diagnostic_search_args[@]}" || true
diff -u "$baseline_path" "$current_path" | sed -n '1,240p' >&2 || true
fail "the canonical public surface differs from approved capture revision $capture_revision."
