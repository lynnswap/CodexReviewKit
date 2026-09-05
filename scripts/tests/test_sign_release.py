from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import sign_release as release  # noqa: E402


TEAM = "ABCDE12345"
FINGERPRINT = "A" * 40
SUBMISSION = "5e301e35-a541-4b57-898f-c3c0b1d4aa23"
CONFIGURATION = {
    "GITHUB_REPOSITORY": "lynnswap/CodexReviewKit", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
    "APPLE_TEAM_ID": TEAM, "NOTARY_API_KEY_ID": "KEY1234567",
    "NOTARY_API_ISSUER_ID": "65ff086e-1830-4f0c-bbf8-3ca6f1eb5c84",
}
CI_ENVIRONMENT = {**CONFIGURATION, "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                  "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "b" * 40}
TEST_SECRETS = {
    "DEVELOPER_ID_P12_BASE64": base64.b64encode(b"test-owned fake identity").decode(),
    "DEVELOPER_ID_P12_PASSWORD": "test-owned fake passphrase",
    "NOTARY_API_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\ntest-owned fake key\n-----END PRIVATE KEY-----",
}


def success(stdout=b"", stderr=b""):
    return release.NativeResult(stdout, stderr, 0)


def valid_identity():
    return success(f'  1) {FINGERPRINT} "Developer ID Application: Test Fixture ({TEAM})"\n     1 valid identities found\n'.encode())


def app_fixture(root: Path) -> Path:
    app = root / release.APP_BUNDLE
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    (contents / "Resources" / "fixture.txt").write_text("test-owned fixture\n")
    (contents / "MacOS" / release.APP_NAME).write_bytes(bytes.fromhex("cffaedfe") + b"fake Mach-O")
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": release.APP_NAME, "CFBundleIdentifier": release.APP_IDENTIFIER,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "1.2.3",
    }))
    return app


class SigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sign-release-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.input = self.root / "input.dmg"
        self.input.write_bytes(b"test-owned input")
        self.arguments = argparse.Namespace(
            input_dmg=self.input, input_sha256=release.digest(self.input), output_directory=self.root / "output",
            version="v1.2.3-beta.1", source_sha="b" * 40,
        )
        self.environment = mock.patch.dict(os.environ, {**CI_ENVIRONMENT, **TEST_SECRETS}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_preflight_rejects_mismatches_before_credentials_or_native_commands(self):
        for attribute, value in (
            ("input_sha256", "c" * 64), ("input_sha256", "not-a-hash"),
            ("version", "../../escape"), ("version", "v01.2.3"), ("source_sha", "c" * 40),
            ("source_sha", "b" * 7),
        ):
            with self.subTest(attribute=attribute, value=value), mock.patch.object(
                self.arguments, attribute, value,
            ), mock.patch.object(release, "temporary_credentials") as credentials, mock.patch.object(
                release.NativeTools, "run",
            ) as native:
                with self.assertRaises(release.ReleaseError):
                    release.prepare_release(self.arguments)
                credentials.assert_not_called()
                native.assert_not_called()
                self.assertEqual(os.environ["DEVELOPER_ID_P12_PASSWORD"], TEST_SECRETS["DEVELOPER_ID_P12_PASSWORD"])
        for name, value in (
            ("GITHUB_REF", "refs/pull/1/merge"), ("GITHUB_REF", "refs/tags/v1.2.3"),
            ("RUNNER_ENVIRONMENT", "self-hosted"), ("GITHUB_ACTIONS", "false"), ("GITHUB_SHA", "c" * 40),
        ):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: value}), mock.patch.object(
                release, "temporary_credentials",
            ) as credentials:
                with self.assertRaises(release.ReleaseError):
                    release.prepare_release(self.arguments)
                credentials.assert_not_called()

    def test_previous_output_and_output_diagnostics_are_rejected(self):
        output = self.arguments.output_directory
        output.mkdir()
        previous = output / "old.dmg"
        previous.write_bytes(b"previous artifact")
        with self.assertRaisesRegex(release.ReleaseError, "new or empty"):
            release.preflight(self.arguments)
        self.assertEqual(previous.read_bytes(), b"previous artifact")
        previous.unlink()
        with mock.patch.dict(os.environ, {"RELEASE_DIAGNOSTICS_DIRECTORY": str(output / "diagnostics")}):
            with self.assertRaisesRegex(release.ReleaseError, "outside"):
                release.preflight(self.arguments)

    def test_invalid_native_image_is_rejected_before_credentials(self):
        with mock.patch.object(release.NativeTools, "run", side_effect=release.ReleaseError("invalid image")), mock.patch.object(
            release, "temporary_credentials",
        ) as credentials:
            with self.assertRaisesRegex(release.ReleaseError, "invalid image"):
                release.prepare_release(self.arguments)
            credentials.assert_not_called()
        self.assertFalse(self.arguments.output_directory.exists())
        self.assertEqual(list(self.root.iterdir()), [self.input])

    def test_native_boundary_never_exposes_secret_arguments_or_child_environment(self):
        tools = release.NativeTools()
        sensitive = TEST_SECRETS["DEVELOPER_ID_P12_PASSWORD"]
        tools.redactions = list(TEST_SECRETS.values())
        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
            ["security", sensitive], 42, sensitive.encode(), sensitive.encode(),
        )) as run:
            with self.assertRaisesRegex(release.ReleaseError, "Import identity: failed with exit code 42") as caught:
                tools.run(["security", sensitive], "Import identity")
            self.assertNotIn(sensitive, str(caught.exception))
            self.assertIn("[REDACTED]", str(caught.exception))
            self.assertTrue(all(name not in run.call_args.kwargs["env"] for name in release.SECRET_NAMES))
            self.assertNotIn("check", run.call_args.kwargs)
        for failure in (OSError(sensitive), subprocess.TimeoutExpired(["security", sensitive], 1)):
            with self.subTest(failure=type(failure).__name__), mock.patch.object(subprocess, "run", side_effect=failure):
                with self.assertRaises(release.ReleaseError) as caught:
                    tools.run(["security", sensitive], "Import identity")
                self.assertNotIn(sensitive, str(caught.exception))
                self.assertTrue(caught.exception.__suppress_context__)

    def test_native_errors_preserve_safe_stderr_and_identify_invalid_layout_file(self):
        tools = release.NativeTools()
        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
            ["hdiutil"], 1, b"", b"hdiutil: image is corrupt\n  checksum mismatch\n",
        )):
            with self.assertRaisesRegex(release.ReleaseError, "hdiutil: image is corrupt checksum mismatch"):
                tools.run(["hdiutil"], "Validate image")
        with self.assertRaisesRegex(release.ReleaseError, r"regular \.DS_Store file"):
            release.layout_contents(self.root)
        (self.root / ".DS_Store").write_bytes(b"test metadata")
        with self.assertRaisesRegex(release.ReleaseError, r"regular \.background.png file"):
            release.layout_contents(self.root)

    def test_old_python_is_rejected_before_parsing_arguments(self):
        with mock.patch.object(sys, "version_info", (3, 9)), mock.patch.object(sys, "stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(release.main(), 1)
        self.assertIn("requires Python 3.10", stderr.getvalue())

    def credential_runner(self, failure_operation=None):
        tools = release.NativeTools()

        def run(arguments, operation, **kwargs):
            if operation == failure_operation:
                raise release.ReleaseError(f"{operation}: injected failure.")
            if operation == "Validate imported signing identity":
                return valid_identity()
            return success()

        tools.run = mock.Mock(side_effect=run)
        return tools

    def test_credentials_are_ephemeral_nonextractable_and_scoped_to_codesign(self):
        tools = self.credential_runner()
        with release.temporary_credentials(tools, self.root, CONFIGURATION) as credentials:
            credential_root = credentials.keychain.parent
            self.assertEqual(credentials.certificate_sha1, FINGERPRINT)
            self.assertEqual(credential_root.stat().st_mode & 0o777, 0o700)
            self.assertEqual(credentials.notary_key.stat().st_mode & 0o777, 0o600)
            self.assertFalse((credential_root / "identity.p12").exists())
            self.assertTrue(all(name not in os.environ for name in release.SECRET_NAMES))
            calls = [call.args[0] for call in tools.run.call_args_list]
            imported, = [arguments for arguments in calls if arguments[1] == "import"]
            self.assertIn("-x", imported)
            self.assertNotIn("-A", imported)
            self.assertEqual(imported[imported.index("-T") + 1], "/usr/bin/codesign")
            self.assertEqual(imported[imported.index("-k") + 1], str(credentials.keychain))
            self.assertFalse(any("list-keychains" in arguments or "default-keychain" in arguments for arguments in calls))
            generated_password = calls[0][calls[0].index("-p") + 1]
            self.assertNotEqual(generated_password, TEST_SECRETS["DEVELOPER_ID_P12_PASSWORD"])
            self.assertGreaterEqual(len(generated_password), 48)
        self.assertFalse(credential_root.exists())
        self.assertEqual(tools.run.call_args.args[0], ["/usr/bin/security", "delete-keychain", str(credentials.keychain)])

    def test_credential_failures_delete_keychain_and_private_files(self):
        for failure_operation in (
            "Configure temporary signing keychain", "Unlock temporary signing keychain", "Import release signing identity",
            "Validate imported signing identity", "Authorize codesign for the imported key", "Delete temporary signing keychain",
        ):
            with self.subTest(operation=failure_operation), mock.patch.dict(os.environ, TEST_SECRETS):
                tools = self.credential_runner(failure_operation)
                with self.assertRaisesRegex(release.ReleaseError, "injected failure"):
                    with release.temporary_credentials(tools, self.root, CONFIGURATION):
                        pass
                self.assertEqual(tools.run.call_args.args[0][1], "delete-keychain")
                self.assertFalse(list(self.root.glob("credentials-*")))
                self.assertTrue(all(name not in os.environ for name in release.SECRET_NAMES))

    def test_partial_keychain_creation_is_deleted(self):
        tools = self.credential_runner()

        def fail_create(arguments, operation):
            if arguments[1] == "create-keychain":
                Path(arguments[-1]).write_bytes(b"partial test keychain")
                raise release.ReleaseError("partial create failure")
            return success()

        tools.run.side_effect = fail_create
        with self.assertRaisesRegex(release.ReleaseError, "partial create failure"):
            with release.temporary_credentials(tools, self.root, CONFIGURATION):
                pass
        self.assertEqual(tools.run.call_args.args[0][1], "delete-keychain")
        self.assertFalse(list(self.root.glob("credentials-*")))

    def test_cooperative_termination_unwinds_credential_cleanup(self):
        tools = self.credential_runner()
        with self.assertRaises(SystemExit) as caught:
            with release.temporary_credentials(tools, self.root, CONFIGURATION):
                release.handle_termination(signal.SIGTERM, None)
        self.assertEqual(caught.exception.code, 143)
        self.assertEqual(tools.run.call_args.args[0][1], "delete-keychain")
        self.assertFalse(list(self.root.glob("credentials-*")))

    def test_bad_secret_encoding_never_creates_keychain(self):
        for name, value in (("DEVELOPER_ID_P12_BASE64", "not base64"), ("NOTARY_API_PRIVATE_KEY", "not PEM")):
            with self.subTest(name=name), mock.patch.dict(os.environ, {**TEST_SECRETS, name: value}):
                tools = self.credential_runner()
                with self.assertRaises(release.ReleaseError):
                    with release.temporary_credentials(tools, self.root, CONFIGURATION):
                        pass
                tools.run.assert_not_called()
                self.assertFalse(list(self.root.glob("credentials-*")))

    def test_wrong_missing_and_ambiguous_identities_are_rejected(self):
        self.assertEqual(release.signing_identity(valid_identity().stdout, TEAM), FINGERPRINT)
        for output in (
            b"0 valid identities found\n", valid_identity().stdout.replace(TEAM.encode(), b"WRONG12345"),
            valid_identity().stdout.replace(b"Developer ID Application:", b"Apple Development:"),
            valid_identity().stdout + valid_identity().stdout,
            valid_identity().stdout.replace(b"1 valid identities", b"2 valid identities"),
        ):
            with self.subTest(output=output):
                with self.assertRaises(release.ReleaseError):
                    release.signing_identity(output, TEAM)

    def test_attach_validation_failure_detaches_only_its_device(self):
        tools = release.NativeTools()
        tools.run = mock.Mock(side_effect=[success(plistlib.dumps({"system-entities": [
            {"dev-entry": "/dev/disk42"}, {"dev-entry": "/dev/disk42s1", "mount-point": "/unexpected"},
        ]})), success()])
        with self.assertRaisesRegex(release.ReleaseError, "private directory"):
            with release.mounted_image(tools, self.input, self.root / "mount", readonly=True):
                self.fail("Unexpectedly yielded the invalid mount")
        self.assertEqual(tools.run.call_args.args[0], ["/usr/bin/hdiutil", "detach", "-force", "/dev/disk42"])

    def test_signature_verification_requires_all_distribution_properties(self):
        valid = (
            f"Identifier={release.APP_IDENTIFIER}\nCodeDirectory v=20500 flags=0x10000(runtime)\n"
            f"Authority=Developer ID Application: Test Fixture ({TEAM})\nAuthority=Developer ID Certification Authority\n"
            f"Timestamp=Sep 5, 2026 at 12:00:00\nTeamIdentifier={TEAM}\n"
        )
        for removed in ("", f"Identifier={release.APP_IDENTIFIER}\n", f"TeamIdentifier={TEAM}\n",
                        "Timestamp=Sep 5, 2026 at 12:00:00\n", "CodeDirectory v=20500 flags=0x10000(runtime)\n",
                        f"Authority=Developer ID Application: Test Fixture ({TEAM})\n"):
            with self.subTest(removed=removed):
                tools = release.NativeTools()
                tools.run = mock.Mock(side_effect=[success(), success(stderr=valid.replace(removed, "").encode())])
                if removed:
                    with self.assertRaises(release.ReleaseError):
                        release.verify_developer_id(tools, self.input, TEAM, app=True)
                else:
                    release.verify_developer_id(tools, self.input, TEAM, app=True)

    def test_app_shape_rejects_nested_code_versions_and_entitlements(self):
        app = app_fixture(self.root)
        tools = release.NativeTools()
        tools.run = mock.Mock(side_effect=lambda args, operation: success(b"arm64\n") if "lipo" in args[0] else success())
        self.assertEqual(release.validate_app(tools, self.root, "v1.2.3"), app)
        nested = app / "Contents" / "Resources" / "nested"
        nested.write_bytes(bytes.fromhex("cffaedfe") + b"new nested code")
        with self.assertRaisesRegex(release.ReleaseError, "nested code"):
            release.validate_app(tools, self.root, "v1.2.3")
        nested.unlink()
        with self.assertRaisesRegex(release.ReleaseError, "CFBundleShortVersionString"):
            release.validate_app(tools, self.root, "v1.2.4")
        tools.run.side_effect = [success(b"arm64\n"), success(), success(plistlib.dumps({"com.apple.security.get-task-allow": True}))]
        with self.assertRaisesRegex(release.ReleaseError, "Nonempty app entitlements"):
            release.validate_app(tools, self.root, "v1.2.3")

    def notary_runner(self, status="Accepted", returncode=0, log_override=None):
        tools = release.NativeTools()
        tools.redactions = list(TEST_SECRETS.values())
        result = release.NativeResult(json.dumps({"id": SUBMISSION, "status": status}).encode(), b"", returncode)
        log = {"jobId": SUBMISSION, "status": status, "sha256": release.digest(self.input), "issues": None}
        if log_override:
            log.update(log_override)
        tools.run = mock.Mock(side_effect=[result, success(json.dumps(log).encode()), success(), success()])
        credentials = release.SigningCredentials(self.root / "fake.keychain", FINGERPRINT, self.root / "fake.p8")
        return tools, credentials

    def test_accepted_notarization_validates_log_and_staples(self):
        tools, credentials = self.notary_runner()
        self.assertEqual(release.notarize(tools, self.input, credentials, CONFIGURATION), SUBMISSION)
        commands = [call.args[0] for call in tools.run.call_args_list]
        self.assertEqual(commands[0][1:3], ["notarytool", "submit"])
        self.assertIn("--wait", commands[0])
        self.assertEqual(commands[0][commands[0].index("--timeout") + 1], "30m")
        self.assertNotIn("--keychain-profile", commands[0])
        self.assertEqual(commands[2][1:3], ["stapler", "staple"])
        self.assertEqual(commands[3][1:3], ["stapler", "validate"])

    def test_nonaccepted_nonzero_and_timeout_never_staple_or_resubmit(self):
        for status, code in (("Invalid", 0), ("In Progress", 75), ("In Progress", None),
                             ("Accepted", 1), ("Unexpected", 0)):
            with self.subTest(status=status, code=code), mock.patch.dict(os.environ, {
                "RELEASE_DIAGNOSTICS_DIRECTORY": str(self.root / "diagnostics"),
            }):
                tools, credentials = self.notary_runner(status, code)
                with self.assertRaisesRegex(release.ReleaseError, "not successfully Accepted"):
                    release.notarize(tools, self.input, credentials, CONFIGURATION)
                commands = [call.args[0] for call in tools.run.call_args_list]
                self.assertEqual(sum(command[1:3] == ["notarytool", "submit"] for command in commands), 1)
                self.assertFalse(any("stapler" in command for command in commands))
                saved = json.loads((self.root / "diagnostics" / "notary-submission.json").read_text())
                self.assertEqual(saved["response"]["id"], SUBMISSION)

    def test_mismatched_notary_log_is_rejected_and_diagnostics_are_redacted(self):
        with mock.patch.dict(os.environ, {"RELEASE_DIAGNOSTICS_DIRECTORY": str(self.root / "diagnostics")}):
            tools, credentials = self.notary_runner(log_override={
                "sha256": "c" * 64, "issues": [{"message": TEST_SECRETS["NOTARY_API_PRIVATE_KEY"]}],
            })
            with self.assertRaisesRegex(release.ReleaseError, "does not match"):
                release.notarize(tools, self.input, credentials, CONFIGURATION)
            saved = json.loads((self.root / "diagnostics" / "notary-log.json").read_text())
            self.assertEqual(saved["log"]["issues"][0]["message"], "[REDACTED]")
            self.assertEqual(tools.run.call_count, 2)

    def test_malformed_notary_response_is_retained_without_retry(self):
        with mock.patch.dict(os.environ, {"RELEASE_DIAGNOSTICS_DIRECTORY": str(self.root / "diagnostics")}):
            tools, credentials = self.notary_runner()
            tools.run.side_effect = [release.NativeResult(
                f"partial output with submission {SUBMISSION}".encode(),
                TEST_SECRETS["DEVELOPER_ID_P12_PASSWORD"].encode() + b": connection failed", 1,
            )]
            with self.assertRaisesRegex(release.ReleaseError, "submission ID"):
                release.notarize(tools, self.input, credentials, CONFIGURATION)
            self.assertEqual(tools.run.call_count, 1)
            saved = json.loads((self.root / "diagnostics" / "notary-submission.json").read_text())
            self.assertIn(SUBMISSION, saved["unparsed_stdout"])
            self.assertEqual(saved["stderr"], "[REDACTED]: connection failed")

    def test_ready_assets_appear_only_after_successful_cleanup(self):
        for cleanup_fails in (True, False):
            with self.subTest(cleanup_fails=cleanup_fails):
                app_root = self.root / ("failure" if cleanup_fails else "success")
                app = app_fixture(app_root)
                cleaned = []

                @contextmanager
                def mount(*args, **kwargs):
                    yield app_root

                @contextmanager
                def credentials(*args, **kwargs):
                    yield release.SigningCredentials(self.root / "fake.keychain", FINGERPRINT, self.root / "fake.p8")
                    self.assertFalse(self.arguments.output_directory.exists())
                    if cleanup_fails:
                        raise release.ReleaseError("cleanup failed")
                    cleaned.append(True)

                def compress(tools, source, target):
                    target.write_bytes(b"final stapled image fixture")

                with mock.patch.object(release.NativeTools, "run", return_value=success()), mock.patch.object(
                    release, "image_information", return_value=32 * 1024 * 1024,
                ), mock.patch.object(release, "mounted_image", mount), mock.patch.object(
                    release, "validate_app", return_value=app,
                ), mock.patch.object(release, "layout_contents", return_value={}), mock.patch.object(
                    release, "make_writable_image",
                ), mock.patch.object(release, "temporary_credentials", credentials), mock.patch.object(
                    release, "verify_developer_id",
                ), mock.patch.object(release, "compress_image", compress), mock.patch.object(
                    release, "notarize", return_value=SUBMISSION,
                ), mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(self.root / "github-output")}):
                    if cleanup_fails:
                        with self.assertRaisesRegex(release.ReleaseError, "cleanup failed"):
                            release.prepare_release(self.arguments)
                        self.assertFalse(self.arguments.output_directory.exists())
                        self.assertFalse((self.root / "github-output").exists())
                    else:
                        image = release.prepare_release(self.arguments)
                        self.assertEqual(cleaned, [True])
                        self.assertEqual(image.name, "CodexReviewMonitor_1.2.3-beta.1.dmg")
                        output = self.arguments.output_directory
                        self.assertEqual(sorted(path.name for path in output.iterdir()), [image.name, "SHA256SUMS", "release-info.json"])
                        info = json.loads((output / "release-info.json").read_text())
                        self.assertEqual(info["source_sha"], self.arguments.source_sha)
                        self.assertEqual(info["notary_submission_id"], SUBMISSION)
                        self.assertIs(info["notarized"], True)
                        for line in (output / "SHA256SUMS").read_text().splitlines():
                            sha256, name = line.split("  ")
                            self.assertEqual(sha256, release.digest(output / name))
                        self.assertIn(f"dmg-sha256={release.digest(image)}\n", (self.root / "github-output").read_text())
                self.assertFalse(list(self.root.glob(".release-*")))


@unittest.skipUnless(sys.platform == "darwin", "Requires native macOS image and code signing tools")
class NativeImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="sign-release-native-tests-")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name).resolve()
        source = cls.root / "source"
        cls.app = app_fixture(source)
        executable = cls.app / "Contents" / "MacOS" / release.APP_NAME
        # This executable is compiled and signed by the test alone. The release
        # entry point never compiles code or accepts an ad-hoc signing identity.
        subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-x", "c", "-", "-o", str(executable)],
                       input=b"int main(void) { return 0; }\n", capture_output=True, check=True)
        cls.tools = release.NativeTools()
        cls.tools.run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(cls.app)], "Sign test fixture")
        cls.image = cls.root / "input.dmg"
        import build_dmg
        build_dmg.build_image(cls.app, cls.image)
        with release.mounted_image(cls.tools, cls.image, cls.root / "layout-mount", readonly=True) as mount:
            cls.layout = release.layout_contents(mount)

    def test_native_conversion_resize_adhoc_resign_and_finalization(self):
        original_digest = release.digest(self.image)
        capacity = release.image_information(self.tools, self.image, "UDZO")
        with release.mounted_image(self.tools, self.image, self.root / "input-mount", readonly=True) as mount:
            app = release.validate_app(self.tools, mount, "v1.2.3-beta.1")
            self.assertEqual(release.layout_contents(mount), self.layout)
            executable_size = (app / "Contents" / "MacOS" / release.APP_NAME).stat().st_size
        writable = self.root / "writable.dmg"
        release.make_writable_image(self.tools, self.image, writable, capacity, executable_size)
        self.assertGreaterEqual(release.image_information(self.tools, writable, "UDRW"), capacity * 2)
        with release.mounted_image(self.tools, writable, self.root / "writable-mount", readonly=False) as mount:
            app = release.validate_app(self.tools, mount, "v1.2.3")
            self.assertGreater(shutil.disk_usage(mount).free, executable_size + 64 * 1024 * 1024)
            self.tools.run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(app)], "Resign test fixture")
            release.validate_app(self.tools, mount, "v1.2.3")
            self.assertEqual(release.layout_contents(mount), self.layout)
        final = self.root / "final.dmg"
        release.compress_image(self.tools, writable, final)
        with release.mounted_image(self.tools, final, self.root / "final-mount", readonly=True) as mount:
            release.validate_app(self.tools, mount, "v1.2.3")
            self.assertEqual(release.layout_contents(mount), self.layout)
        self.assertEqual(release.digest(self.image), original_digest)
        attached = plistlib.loads(self.tools.run(["/usr/bin/hdiutil", "info", "-plist"], "Inspect test mounts").stdout)
        self.assertFalse(any(Path(image["image-path"]).is_relative_to(self.root) for image in attached["images"]))


if __name__ == "__main__":
    unittest.main()
