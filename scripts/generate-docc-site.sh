#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s <absolute-output-directory> <hosting-base-path>\n' "$0" >&2
  exit 64
fi

output_directory="$1"
hosting_base_path="${2%/}"

if [[ "$output_directory" != /* ]]; then
  printf 'output directory must be absolute: %s\n' "$output_directory" >&2
  exit 64
fi

if [[ -z "$hosting_base_path" ]]; then
  printf 'hosting base path must not be empty\n' >&2
  exit 64
fi

if [[ -e "$output_directory" ]]; then
  printf 'output directory already exists: %s\n' "$output_directory" >&2
  exit 1
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

targets=(
  CodexAppServerKit
  CodexAppServerKitTesting
  CodexDataKit
  CodexReviewKit
  CodexReviewHost
  ReviewUI
  ReviewUIPreviewSupport
  TextTransitions
)

mkdir -p "$output_directory"
cp Docs/DocCSite/index.html "$output_directory/index.html"

for target in "${targets[@]}"; do
  target_output="$output_directory/$target"
  swift package \
    --allow-writing-to-directory "$target_output" \
    generate-documentation \
    --target "$target" \
    --output-path "$target_output" \
    --disable-indexing \
    --transform-for-static-hosting \
    --hosting-base-path "$hosting_base_path/$target" \
    --warnings-as-errors
done
