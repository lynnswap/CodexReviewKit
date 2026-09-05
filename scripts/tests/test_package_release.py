from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import build_dmg  # noqa: E402
from ds_store import DSStore  # noqa: E402


class PackageReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary_directory = tempfile.TemporaryDirectory(prefix="package-release-tests-")
        cls.addClassCleanup(cls.temporary_directory.cleanup)
        cls.root = Path(cls.temporary_directory.name)
        cls.dist = cls.root / "dist with spaces"
        cls.app = cls.dist / "arm64" / build_dmg.APP_BUNDLE
        contents = cls.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources" / "empty").mkdir(parents=True)
        (contents / "Resources" / "fixture.txt").write_text("release fixture\n")
        (contents / "Resources" / "link").symlink_to("fixture.txt")
        with (contents / "Info.plist").open("wb") as output:
            plistlib.dump(
                {
                    "CFBundleExecutable": build_dmg.APP_NAME,
                    "CFBundleIdentifier": "com.example.codex-review-release-fixture",
                    "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1",
                },
                output,
            )
        subprocess.run(
            ["xcrun", "clang", "-arch", "arm64", "-x", "c", "-", "-o", str(contents / "MacOS" / build_dmg.APP_NAME)],
            input="int main(void) { return 0; }\n",
            text=True,
            check=True,
        )
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", str(cls.app)], check=True)
        cls.original_app = build_dmg.app_manifest(cls.app)
        cls.environment = os.environ.copy()
        cls.environment.pop("CODE_SIGN_IDENTITY", None)
        cls.environment.pop("NOTARYTOOL_KEYCHAIN_PROFILE", None)
        cls.environment["PATH"] = f"{Path(sys.executable).parent}:{cls.environment['PATH']}"

    def run_package(self, *arguments, environment=None):
        return subprocess.run(
            [str(SCRIPTS / "package-release.sh"), *arguments],
            env=environment or self.environment,
            capture_output=True,
            text=True,
        )

    def test_invalid_arguments_are_rejected(self):
        for arguments, message in (
            ([], "--version is required"),
            (["--version"], "Missing value for --version"),
            (["--version", "--output-dir"], "Missing value for --version"),
            (["--version", "v1.2.3", "--dist-root", ""], "Missing value for --dist-root"),
            (["--version", "../../other"], "--version must be a release version"),
            (["--version", "v1.2.3", "--notary-profile", "profile"], "requires --signing-identity"),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_package(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_missing_app_is_rejected(self):
        result = self.run_package("--version", "v1.2.3", "--dist-root", str(self.root / "missing"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing staged artifact", result.stderr)

    def test_invalid_signature_is_rejected(self):
        dist = self.root / "invalid-dist"
        app = dist / "arm64" / build_dmg.APP_BUNDLE
        subprocess.run(["ditto", str(self.app), str(app)], check=True)
        (app / "Contents" / "Resources" / "fixture.txt").write_text("tampered\n")
        output = self.root / "invalid-release"
        result = self.run_package("--version", "v1.2.3", "--dist-root", str(dist), "--output-dir", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid code signature", result.stderr)
        self.assertFalse(output.exists())

    def test_wrong_architecture_is_rejected(self):
        dist = self.root / "intel-dist"
        app = dist / "arm64" / build_dmg.APP_BUNDLE
        subprocess.run(["ditto", str(self.app), str(app)], check=True)
        subprocess.run(
            ["xcrun", "clang", "-arch", "x86_64", "-x", "c", "-", "-o", str(app / "Contents" / "MacOS" / build_dmg.APP_NAME)],
            input="int main(void) { return 0; }\n",
            text=True,
            check=True,
        )
        result = self.run_package("--version", "v1.2.3", "--dist-root", str(dist))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not arm64-only", result.stderr)

    def test_source_app_cannot_be_used_as_output_directory(self):
        result = self.run_package(
            "--version", "v1.2.3", "--dist-root", str(self.dist), "--output-dir", str(self.app / "new-output")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the source app", result.stderr)
        self.assertEqual(build_dmg.app_manifest(self.app), self.original_app)

    def test_missing_dependencies_are_rejected(self):
        environment_path = self.root / "empty-venv"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(environment_path)], check=True)
        environment = self.environment.copy()
        environment["PATH"] = f"{environment_path / 'bin'}:{environment['PATH']}"
        result = self.run_package("--version", "v1.2.3", "--dist-root", str(self.dist), environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing DMG packaging dependency", result.stderr)

    def test_headless_image_preserves_app_and_layout(self):
        output = self.root / "release with spaces"
        result = self.run_package(
            "--version", "v1.2.3-beta.1", "--dist-root", str(self.dist), "--output-dir", str(output)
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("for validation only", result.stderr)
        archive = output / "CodexReviewMonitor_1.2.3-beta.1.dmg"
        self.assertEqual(list(output.iterdir()), [archive])
        self.assertEqual(build_dmg.app_manifest(self.app), self.original_app)
        information = plistlib.loads(subprocess.check_output(["hdiutil", "imageinfo", "-plist", str(archive)]))
        self.assertEqual(information["Format"], "UDZO")
        mount = self.root / "inspection-mount"
        mount.mkdir()
        try:
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(archive)], check=True)
            self.assertEqual(build_dmg.app_manifest(mount / build_dmg.APP_BUNDLE), self.original_app)
            self.assertEqual(os.readlink(mount / build_dmg.APPLICATIONS_LINK), "/Applications")
            self.assertTrue((mount / ".background.png").is_file())
            with DSStore.open(str(mount / ".DS_Store"), "r") as layout:
                self.assertEqual(layout["."]["bwsp"]["WindowBounds"], "{{120, 100}, {480, 540}}")
                self.assertEqual(layout["."]["icvp"]["iconSize"], 128)
                self.assertEqual(layout[build_dmg.APP_BUNDLE]["Iloc"], (240, 122))
                self.assertEqual(layout[build_dmg.APPLICATIONS_LINK]["Iloc"], (240, 387))
        finally:
            if os.path.ismount(mount):
                subprocess.run(["hdiutil", "detach", "-force", str(mount)], check=True)

    def test_validation_failure_unmounts_and_preserves_previous_archive(self):
        output = self.root / "failed-release"
        output.mkdir()
        archive = output / "CodexReviewMonitor_1.2.3.dmg"
        archive.write_bytes(b"previous archive")
        tools = self.root / "failure-tools"
        tools.mkdir()
        codesign = tools / "codesign"
        codesign.write_text(
            '#!/bin/bash\n'
            'for argument in "$@"; do\n'
            '  if [[ "$argument" == *reviewmonitor-verify-* ]]; then\n'
            '    echo "injected mounted signature verification failure" >&2\n'
            '    exit 42\n'
            '  fi\n'
            'done\n'
            'exec /usr/bin/codesign "$@"\n'
        )
        codesign.chmod(0o755)
        environment = self.environment.copy()
        environment["PATH"] = f"{tools}:{environment['PATH']}"
        result = self.run_package(
            "--version", "v1.2.3", "--dist-root", str(self.dist), "--output-dir", str(output), environment=environment
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected mounted signature verification failure", result.stderr)
        self.assertEqual(archive.read_bytes(), b"previous archive")
        self.assertEqual(list(output.iterdir()), [archive])
        self.assertEqual(build_dmg.app_manifest(self.app), self.original_app)
        attached = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"]))
        self.assertFalse(any(str(output.resolve()) in image["image-path"] for image in attached["images"]))

    def test_partial_copy_with_valid_signature_is_rejected(self):
        output = self.root / "partial-copy"
        output.mkdir()
        archive = output / "partial.dmg"
        original_call = subprocess.call

        def incomplete_copy(arguments, *args, **kwargs):
            result = original_call(arguments, *args, **kwargs)
            if arguments[0] == "/usr/bin/ditto":
                app = Path(arguments[-1])
                (app / "Contents" / "Resources" / "empty").rmdir()
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
                return 1
            return result

        with mock.patch("dmgbuild.core.subprocess.call", side_effect=incomplete_copy):
            with self.assertRaisesRegex(ValueError, "packaged app contents differ"):
                build_dmg.build_image(self.app, archive)
        self.assertEqual(build_dmg.app_manifest(self.app), self.original_app)
        attached = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"]))
        self.assertFalse(any(str(output.resolve()) in image["image-path"] for image in attached["images"]))

    def test_creation_failure_after_attach_unmounts_build_image(self):
        output = self.root / "sync-failure"
        output.mkdir()
        archive = output / "failed.dmg"
        original_check_call = subprocess.check_call

        def fail_sync(arguments, *args, **kwargs):
            if arguments[0] == "sync":
                raise subprocess.CalledProcessError(42, arguments)
            return original_check_call(arguments, *args, **kwargs)

        with mock.patch("dmgbuild.core.subprocess.check_call", side_effect=fail_sync):
            with self.assertRaises(subprocess.CalledProcessError):
                build_dmg.build_image(self.app, archive)
        self.assertFalse(archive.exists())
        self.assertEqual(build_dmg.app_manifest(self.app), self.original_app)
        attached = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"]))
        self.assertFalse(any(str(output.resolve()) in image["image-path"] for image in attached["images"]))


if __name__ == "__main__":
    unittest.main()
