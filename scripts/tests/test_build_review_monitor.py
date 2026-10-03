from __future__ import annotations

import contextlib
import io
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import build_review_monitor as builder  # noqa: E402


def create_app(path: Path, marker: str = "new") -> None:
    executable_directory = path / "Contents" / "MacOS"
    executable_directory.mkdir(parents=True, exist_ok=True)
    (executable_directory / builder.APP_NAME).write_text("#!/bin/sh\nexit 0\n")
    with (path / "Contents" / "Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "lynnpd.CodexReviewMonitor"}, file)
    (path / "Contents" / "marker").write_text(marker)


class FakeCommands:
    def __init__(self) -> None:
        self.calls = []
        self.failure = None

    def __call__(self, arguments, **kwargs):
        command = [str(argument) for argument in arguments]
        self.calls.append((command, kwargs))
        executable = Path(command[0]).name
        if "venv" in command:
            python = Path(command[-1]) / "bin" / "python3"
            python.parent.mkdir(parents=True)
            python.touch()
        elif "pip" in command:
            if self.failure == "dependencies":
                raise subprocess.CalledProcessError(1, command)
        elif executable == "xcodebuild":
            if self.failure == "build":
                raise subprocess.CalledProcessError(1, command)
            derived_data = Path(command[command.index("-derivedDataPath") + 1])
            create_app(derived_data / "Build/Products/Release" / builder.APP_BUNDLE_NAME)
        elif executable == "ditto":
            shutil.copytree(command[-2], command[-1], symlinks=True)
        elif executable == "codesign":
            if self.failure == "sign" and "--sign" in command:
                raise subprocess.CalledProcessError(1, command)
        elif command[1].endswith("build_dmg.py"):
            archive = Path(command[-1])
            archive.write_bytes(b"validated image")
            if self.failure == "package":
                raise subprocess.CalledProcessError(1, command)
        else:
            raise AssertionError(f"Unexpected command: {command}")
        return subprocess.CompletedProcess(command, 0)


class LocalBuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "Checkout With Spaces"
        self.dist = self.repo / "dist"
        self.dist.mkdir(parents=True)
        self.archive = self.dist / "CodexReviewMonitor_261003_1430.dmg"
        self.commands = FakeCommands()
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(builder.subprocess, "run", side_effect=self.commands).start()
        mock.patch.object(builder, "datetime").start().now.return_value = datetime(2026, 10, 3, 14, 30)
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def test_build_creates_timestamped_dmg_without_changing_installed_app(self):
        installed_app = self.root / "Applications" / builder.APP_BUNDLE_NAME
        create_app(installed_app, marker="installed")
        older_archive = self.dist / "CodexReviewMonitor_261002_1000.dmg"
        older_archive.write_bytes(b"older image")

        archive = builder.build(self.repo, self.dist)

        self.assertEqual(archive, self.archive)
        self.assertEqual(archive.read_bytes(), b"validated image")
        self.assertEqual(older_archive.read_bytes(), b"older image")
        self.assertEqual((installed_app / "Contents/marker").read_text(), "installed")
        self.assertEqual((self.dist / "arm64" / builder.APP_BUNDLE_NAME / "Contents/marker").read_text(), "new")
        commands = [command for command, _ in self.commands.calls]
        self.assertFalse(any(Path(command[0]).name in {"pgrep", "open", "killall"} for command in commands))
        self.assertFalse(list(self.dist.glob(".build-review-monitor-*")))

    def test_rebuild_keeps_caches_and_reuses_packaging_environment(self):
        builder.build(self.repo, self.dist)
        cache = self.repo / ".build/local-dmg-arm64/cache-marker"
        cache.write_text("cached")
        self.commands.calls.clear()

        builder.build(self.repo, self.dist)

        self.assertEqual(cache.read_text(), "cached")
        self.assertFalse(any("venv" in command for command, _ in self.commands.calls))
        self.assertEqual(self.archive.read_bytes(), b"validated image")

    def test_failures_preserve_previous_outputs(self):
        previous_app = self.dist / "arm64" / builder.APP_BUNDLE_NAME
        create_app(previous_app, marker="previous")
        for failure in ("dependencies", "build", "sign", "package"):
            with self.subTest(failure=failure):
                self.archive.write_bytes(b"previous image")
                self.commands.failure = failure
                with self.assertRaises(subprocess.CalledProcessError):
                    builder.build(self.repo, self.dist)
                self.assertEqual(self.archive.read_bytes(), b"previous image")
                self.assertEqual((previous_app / "Contents/marker").read_text(), "previous")
                self.assertFalse(list(self.dist.glob(".build-review-monitor-*")))

    def test_explicit_signing_identity_is_one_argument(self):
        identity = "Apple Development: Developer Name (TEAMID)"
        builder.build(self.repo, self.dist, identity)
        command = next(command for command, _ in self.commands.calls if "--sign" in command)
        self.assertEqual(command[command.index("--sign") + 1], identity)
        self.assertEqual(command[command.index("--options") + 1], "runtime")
        self.assertIn("--timestamp=none", command)

    def test_copy_preserves_metadata_even_when_dittonorsrc_is_set(self):
        with mock.patch.dict(os.environ, {"DITTONORSRC": "1"}):
            builder.build(self.repo, self.dist)
        command, kwargs = next(call for call in self.commands.calls if Path(call[0][0]).name == "ditto")
        self.assertTrue({"--rsrc", "--extattr", "--acl", "--qtn"}.issubset(command))
        self.assertNotIn("DITTONORSRC", kwargs["env"])

    def test_help_does_not_build_or_prepare_dependencies(self):
        with self.assertRaises(SystemExit) as result:
            builder.main(["--help"])
        self.assertEqual(result.exception.code, 0)
        self.assertEqual(self.commands.calls, [])


@unittest.skipUnless(
    os.environ.get("RUN_LOCAL_BUILD_INTEGRATION") == "1",
    "set RUN_LOCAL_BUILD_INTEGRATION=1 to build and validate a real local DMG",
)
class LocalBuildIntegrationTests(unittest.TestCase):
    def test_real_build_sign_and_dmg(self):
        repo_root = SCRIPTS.parent
        with tempfile.TemporaryDirectory(prefix="local-build-integration-") as directory:
            root = Path(directory)
            archive = builder.build(repo_root, root / "dist")
            self.assertRegex(archive.name, r"^CodexReviewMonitor_\d{6}_\d{4}\.dmg$")
            mount = root / "mount"
            mount.mkdir()
            try:
                subprocess.run(
                    ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(archive)],
                    check=True,
                )
                app = mount / builder.APP_BUNDLE_NAME
                with (app / "Contents/Info.plist").open("rb") as file:
                    self.assertEqual(plistlib.load(file)["CFBundleIdentifier"], "lynnpd.CodexReviewMonitor")
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
                signature = subprocess.run(
                    ["codesign", "--display", "--verbose=4", str(app)],
                    capture_output=True, text=True, check=True,
                )
                self.assertIn("runtime", signature.stderr)
                self.assertTrue((mount / "\u200b").is_symlink())
                self.assertEqual(os.readlink(mount / "\u200b"), "/Applications")
            finally:
                if os.path.ismount(mount):
                    subprocess.run(["hdiutil", "detach", "-force", str(mount)], check=True)


if __name__ == "__main__":
    unittest.main()
