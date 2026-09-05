"""Validate a release request and create a verified, unpublished GitHub draft."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


VERSION_PATTERN = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


class ReleaseError(Exception):
    pass


def run(arguments: list[str]) -> str:
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise ReleaseError(f"{arguments[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def api(endpoint: str, *, paginate: bool = False):
    arguments = ["gh", "api", "--method", "GET"]
    if paginate:
        arguments += ["--paginate", "--slurp"]
    return json.loads(run([*arguments, endpoint]))


def validate_request(version: str, source_sha: str) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError("Version must look like v1.2.3 or v1.2.3-beta.1.")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ReleaseError("The release source must be a full commit SHA.")
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ReleaseError("Prepare Release must run on the main branch in GitHub Actions.")
    if source_sha != os.environ.get("GITHUB_SHA") or run(["git", "rev-parse", "HEAD"]).strip() != source_sha:
        raise ReleaseError("The release source does not match the workflow checkout.")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ReleaseError("GITHUB_REPOSITORY must identify the release repository.")
    return repository


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def validate_artifacts(directory: Path, version: str, source_sha: str, repository: str, dmg_sha256: str) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{64}", dmg_sha256):
        raise ReleaseError("Missing or malformed digest from the signing job.")
    dmg_name = f"CodexReviewMonitor_{version[1:]}.dmg"
    expected_names = {dmg_name, "release-info.json", "SHA256SUMS"}
    if {path.name for path in directory.iterdir()} != expected_names:
        raise ReleaseError("The signing artifact does not contain the exact release file set.")
    for name in expected_names:
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ReleaseError(f"Release asset must be a regular file: {name}")
    if digest(directory / dmg_name) != dmg_sha256:
        raise ReleaseError("DMG checksum differs from the signing job's output.")
    info = json.loads((directory / "release-info.json").read_text())
    expected = {
        "version": version,
        "source_sha": source_sha,
        "repository": repository,
        "run_id": os.environ["GITHUB_RUN_ID"],
        "build_number": os.environ["GITHUB_RUN_NUMBER"],
        "developer_id_signed": True,
        "notarized": True,
    }
    for key, value in expected.items():
        if info.get(key) != value or type(info.get(key)) is not type(value):
            raise ReleaseError(f"Release metadata mismatch: {key}")
    for key in ("apple_team_id", "signing_certificate_sha1", "notary_submission_id"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ReleaseError(f"Missing signing metadata: {key}")
    expected_checksums = {dmg_name: dmg_sha256, "release-info.json": digest(directory / "release-info.json")}
    actual_checksums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in actual_checksums:
            raise ReleaseError("Malformed or duplicate SHA256SUMS entry.")
        actual_checksums[match[2]] = match[1]
    if actual_checksums != expected_checksums:
        raise ReleaseError("Release checksums do not match the signed artifact.")
    return {**expected_checksums, "SHA256SUMS": digest(directory / "SHA256SUMS")}


def matching_releases(repository: str, version: str) -> list[dict]:
    # Drafts are visible only with push access; this runs in the contents:write job.
    pages = api(f"repos/{repository}/releases?per_page=100", paginate=True)
    return [release for page in pages for release in page if release["tag_name"] == version]


def require_absent_tag(repository: str, version: str) -> None:
    refs = api(f"repos/{repository}/git/matching-refs/tags/{version}")
    if any(ref["ref"] == f"refs/tags/{version}" for ref in refs):
        raise ReleaseError(f"Tag {version} already exists; it will not be moved or reused.")


def create_draft(directory: Path, version: str, source_sha: str, dmg_sha256: str, prerelease: bool) -> str:
    repository = validate_request(version, source_sha)
    checksums = validate_artifacts(directory, version, source_sha, repository, dmg_sha256)
    if matching_releases(repository, version):
        raise ReleaseError(f"A draft or published release for {version} already exists; no assets or notes were replaced.")
    require_absent_tag(repository, version)
    # Leave the tag absent until manual publication. The full SHA pins the draft
    # without exposing a SwiftPM version before its release notes are approved.
    run([
        "gh", "release", "create", version,
        *[str(directory / name) for name in checksums],
        "--repo", repository, "--draft", "--target", source_sha,
        "--title", version, "--generate-notes", f"--prerelease={'true' if prerelease else 'false'}",
    ])
    releases = matching_releases(repository, version)
    if len(releases) != 1:
        raise ReleaseError("The newly created draft could not be identified uniquely; inspect Releases before retrying.")
    release = releases[0]
    if release["draft"] is not True or release["prerelease"] is not prerelease or release["target_commitish"] != source_sha:
        raise ReleaseError("The created release does not match its draft/commit/prerelease contract; inspect Releases.")
    assets = release["assets"]
    if {asset["name"] for asset in assets} != set(checksums) or len(assets) != len(checksums):
        raise ReleaseError("Draft asset set is incomplete; inspect Releases before retrying.")
    for asset in assets:
        if asset["state"] != "uploaded" or asset.get("digest") != f"sha256:{checksums[asset['name']]}":
            raise ReleaseError(f"Draft asset upload/digest mismatch: {asset['name']}")
    require_absent_tag(repository, version)
    url = release["html_url"]
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with Path(summary_path).open("a") as summary:
            summary.write(f"## Release draft ready\n\n[{version}]({url}) targets `{source_sha}`.\n\n")
            summary.write("Edit the release notes and review the attached DMG, then publish the draft in GitHub.\n")
    return url


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "draft"):
        command = commands.add_parser(name)
        command.add_argument("--version", required=True)
        command.add_argument("--source-sha", required=True)
        if name == "draft":
            command.add_argument("--directory", type=Path, required=True)
            command.add_argument("--dmg-sha256", required=True)
            command.add_argument("--prerelease", choices=("true", "false"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            validate_request(args.version, args.source_sha)
            print(f"Release request validated: {args.version} at {args.source_sha}")
        else:
            print(create_draft(args.directory, args.version, args.source_sha, args.dmg_sha256, args.prerelease == "true"))
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
