#!/usr/bin/env python3
"""Build a local CodexReviewMonitor DMG without changing installed apps."""

from __future__ import annotations

import argparse
import fcntl
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path


APP_NAME = "CodexReviewMonitor"
APP_BUNDLE_NAME = f"{APP_NAME}.app"


def run(arguments: list[str], *, cwd: Path | None = None, **kwargs) -> None:
    print(f"+ {shlex.join(arguments)}", flush=True)
    subprocess.run(arguments, cwd=cwd, check=True, **kwargs)


def packaging_python(repo_root: Path) -> Path:
    environment = repo_root / ".build" / "release-tools"
    python = environment / "bin" / "python3"
    if not python.exists():
        run([sys.executable, "-m", "venv", str(environment)])
    run(
        [
            str(python), "-m", "pip", "install", "--disable-pip-version-check",
            "--require-hashes", "--only-binary=:all:",
            "-r", str(repo_root / "scripts" / "release-requirements.txt"),
        ]
    )
    return python


def build(repo_root: Path, output_dir: Path, signing_identity: str = "-") -> Path:
    build_root = repo_root / ".build"
    build_root.mkdir(parents=True, exist_ok=True)
    with (build_root / "local-dmg.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        timestamp = datetime.now().strftime("%y%m%d_%H%M")
        archive_name = f"{APP_NAME}_{timestamp}.dmg"
        python = packaging_python(repo_root)
        derived_data = build_root / "local-dmg-arm64"
        run(
            [
                "/usr/bin/xcodebuild", "build",
                "-project", "Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj",
                "-scheme", APP_NAME,
                "-configuration", "Release",
                "-destination", "generic/platform=macOS",
                "-derivedDataPath", str(derived_data),
                "-disableAutomaticPackageResolution",
                "-onlyUsePackageVersionsFromResolvedFile",
                "-skipMacroValidation",
                "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
                "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGN_IDENTITY=",
            ],
            cwd=repo_root,
        )

        output_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=".build-review-monitor-", dir=output_dir
        ) as directory:
            stage_root = Path(directory)
            app = stage_root / APP_BUNDLE_NAME
            product = derived_data / "Build" / "Products" / "Release" / APP_BUNDLE_NAME
            environment = dict(os.environ)
            environment.pop("DITTONORSRC", None)
            run(
                [
                    "/usr/bin/ditto", "--rsrc", "--extattr", "--acl", "--qtn",
                    str(product), str(app),
                ],
                env=environment,
            )
            run(
                [
                    "/usr/bin/codesign", "--force", "--options", "runtime",
                    "--timestamp=none", "--sign", signing_identity, str(app),
                ]
            )
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
            pending_archive = stage_root / archive_name
            run(
                [str(python), str(repo_root / "scripts" / "build_dmg.py"),
                 str(app), str(pending_archive)]
            )

            staged_app = output_dir / "arm64" / APP_BUNDLE_NAME
            staged_app.parent.mkdir(parents=True, exist_ok=True)
            if staged_app.exists():
                shutil.rmtree(staged_app)
            app.replace(staged_app)
            archive = output_dir / archive_name
            pending_archive.replace(archive)

    print(f"Created local DMG: {archive}")
    print("When reviews have finished, quit CodexReviewMonitor, open the DMG, "
          "and drag the app to Applications to replace it.")
    return archive


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--signing-identity", default="-", metavar="IDENTITY",
        help="local codesign identity (default: '-' for ad-hoc signing)",
    )
    parsed = parser.parse_args(arguments)
    if sys.version_info < (3, 10):
        parser.error("DMG packaging requires Python 3.10 or newer.")
    if not parsed.signing_identity:
        parser.error("--signing-identity must not be empty.")
    repo_root = Path(__file__).resolve().parent.parent
    try:
        build(repo_root, repo_root / "dist", parsed.signing_identity)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
