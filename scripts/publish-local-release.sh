#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/publish-local-release.sh <tag> --signing-identity <developer-id-identity> --notary-profile <profile> [--dist-root <dir>] [--output-dir <dir>] [--remote <name>] [--release-branch <branch>] [--skip-tests] [--allow-dirty]

Builds, Developer ID signs, notarizes, and uploads the CodexReviewMonitor DMG, then pushes the release tag.
Passing --allow-dirty creates a local-only signed/notarized archive and never pushes a tag or GitHub release.
EOF
}

tag=""
dist_root="dist"
output_dir="release"
remote="origin"
release_branch="main"
signing_identity="${CODE_SIGN_IDENTITY:-}"
notary_profile="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
skip_tests=0
allow_dirty=0
app_name="CodexReviewMonitor"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --remote)
      remote="${2:-}"
      shift 2
      ;;
    --release-branch)
      release_branch="${2:-}"
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
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$tag" ]]; then
        echo "Only one release tag can be specified." >&2
        usage
        exit 1
      fi
      tag="$1"
      shift
      ;;
  esac
done

if [[ -z "$tag" || -z "$signing_identity" || -z "$notary_profile" ]]; then
  usage
  exit 1
fi

if [[ ! "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi

if [[ "$signing_identity" != Developer\ ID\ Application:* ]]; then
  echo "--signing-identity must be a Developer ID Application identity for public macOS distribution." >&2
  echo "Apple Development identities are for local development and are intentionally not accepted here." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dirty_status="$(git status --porcelain --untracked-files=all --ignore-submodules=dirty)"
if [[ -n "$dirty_status" && "$allow_dirty" -eq 0 ]]; then
  echo "Working tree has uncommitted or untracked changes. Commit them first, or pass --allow-dirty for a local-only test." >&2
  echo "$dirty_status" >&2
  exit 1
fi

if [[ "$allow_dirty" -eq 1 ]]; then
  echo "--allow-dirty enabled: creating a local-only archive without pushing a tag or GitHub release." >&2
fi

if [[ "$allow_dirty" -eq 0 ]]; then
  current_branch="$(git branch --show-current)"
  if [[ "$current_branch" != "$release_branch" ]]; then
    echo "Release tags must be created from $release_branch, not $current_branch." >&2
    exit 1
  fi

  git fetch --quiet "$remote" "refs/heads/$release_branch:refs/remotes/$remote/$release_branch" --tags
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Local or fetched tag already exists: $tag" >&2
    exit 1
  fi

  remote_tag="$(git ls-remote --tags "$remote" "refs/tags/$tag")"
  if [[ -n "$remote_tag" ]]; then
    echo "Remote tag already exists on $remote: $tag" >&2
    exit 1
  fi

  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "$remote/$release_branch")"
  if [[ "$local_head" != "$remote_head" ]]; then
    echo "Release tag target must match $remote/$release_branch before the tag is pushed." >&2
    echo "Local HEAD:  $local_head" >&2
    echo "Remote HEAD: $remote_head" >&2
    exit 1
  fi
fi

if ! security find-identity -v -p codesigning | grep -F "\"$signing_identity\"" >/dev/null; then
  echo "Signing identity not found in the login keychain: $signing_identity" >&2
  exit 1
fi

if [[ "$allow_dirty" -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI is required to create the draft GitHub Release." >&2
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "gh CLI is not authenticated." >&2
    exit 1
  fi
fi

if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
  echo "Notary keychain profile is not usable: $notary_profile" >&2
  echo "Create it with xcrun notarytool store-credentials before publishing." >&2
  exit 1
fi

if [[ "$skip_tests" -eq 0 ]]; then
  swift test --build-system swiftbuild --no-parallel
  xcodebuild test \
    -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj \
    -scheme CodexReviewMonitor \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
fi

bash scripts/build-release.sh \
  --version "$tag" \
  --dist-root "$dist_root" \
  --signing-identity "$signing_identity"

bash scripts/package-release.sh \
  --version "$tag" \
  --dist-root "$dist_root" \
  --output-dir "$output_dir" \
  --signing-identity "$signing_identity" \
  --notary-profile "$notary_profile"

if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi
archive_path="$output_base/${app_name}_${tag#v}.dmg"

if [[ ! -f "$archive_path" ]]; then
  echo "Expected release archive was not created: $archive_path" >&2
  exit 1
fi

if [[ "$allow_dirty" -eq 1 ]]; then
  echo "Created local-only release archive: $archive_path"
  echo "Skipped tag push, GitHub Release upload, and release workflow dispatch because --allow-dirty was supplied."
  exit 0
fi

git tag -a "$tag" -m "Release $tag"
git push "$remote" "$tag"

if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$archive_path" --clobber
else
  gh release create "$tag" "$archive_path" --draft --generate-notes --title "$tag" --verify-tag
fi

gh workflow run release.yml --ref "$tag" -f version="$tag"

echo "Published local release draft for $tag with asset: $archive_path"
echo "Dispatched Release Verification workflow for $tag"
