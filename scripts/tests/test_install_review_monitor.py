from __future__ import annotations

import contextlib
import io
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Mapping, Optional, Sequence


SCRIPTS_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))

import install_review_monitor as installer  # noqa: E402


def create_app(
    path: Path,
    *,
    bundle_identifier: str = installer.BUNDLE_IDENTIFIER,
    marker: str = "new",
) -> None:
    executable_directory = path / "Contents" / "MacOS"
    resources_directory = path / "Contents" / "Resources"
    executable_directory.mkdir(parents=True)
    resources_directory.mkdir(parents=True)
    info = {
        "CFBundleExecutable": installer.APP_NAME,
        "CFBundleIdentifier": bundle_identifier,
        "CFBundlePackageType": "APPL",
    }
    with (path / "Contents" / "Info.plist").open("wb") as info_file:
        plistlib.dump(info, info_file)
    executable = executable_directory / installer.APP_NAME
    executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    executable.chmod(0o755)
    (resources_directory / "build-marker.txt").write_text(
        marker,
        encoding="utf-8",
    )


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[list[str], Optional[dict[str, str]]]] = []
        self.xcode_version = "Xcode 27.0\nBuild version 27A5252f\n"
        self.architectures = "arm64\n"
        self.runtime_signature = True
        self.fail_build = False
        self.fail_verify_at: Optional[int] = None
        self.interrupt_verify_at: Optional[int] = None
        self.verify_count = 0
        self.xattr_count = 0
        self.quarantine_at_xattr_call: Optional[int] = None
        self.fail_xattr_at: Optional[int] = None
        self.pgrep_returncode = 1
        self.pgrep_stdout = ""
        self.open_failure = False

    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Optional[Path] = None,
        check: bool = True,
        capture_output: bool = False,
        environment: Optional[Mapping[str, str]] = None,
    ) -> installer.CommandResult:
        del cwd, capture_output
        command = [str(argument) for argument in arguments]
        recorded_environment = dict(environment) if environment is not None else None
        self.calls.append((command, recorded_environment))
        executable = Path(command[0]).name

        if executable == "xcodebuild" and command[1:] == ["-version"]:
            return installer.CommandResult(0, stdout=self.xcode_version)
        if executable == "xcodebuild" and command[1] == "build":
            if self.fail_build:
                raise installer.InstallerError("simulated build failure")
            derived_data = Path(command[command.index("-derivedDataPath") + 1])
            create_app(
                derived_data
                / "Build"
                / "Products"
                / "Release"
                / installer.APP_BUNDLE_NAME
            )
            return installer.CommandResult(0)
        if executable == "ditto":
            source = Path(command[-2])
            destination = Path(command[-1])
            shutil.copytree(source, destination, symlinks=True)
            return installer.CommandResult(0)
        if executable == "codesign" and "--verify" in command:
            self.verify_count += 1
            if self.interrupt_verify_at == self.verify_count:
                raise KeyboardInterrupt()
            if self.fail_verify_at == self.verify_count:
                raise installer.InstallerError("simulated verification failure")
            return installer.CommandResult(0)
        if executable == "codesign" and "--display" in command:
            flags = "adhoc,runtime" if self.runtime_signature else "adhoc"
            return installer.CommandResult(
                0,
                stderr=f"CodeDirectory v=20500 flags=0x10002({flags})\n",
            )
        if executable == "codesign":
            return installer.CommandResult(0)
        if executable == "lipo":
            return installer.CommandResult(0, stdout=self.architectures)
        if executable == "xattr":
            self.xattr_count += 1
            if self.fail_xattr_at == self.xattr_count:
                raise installer.InstallerError("simulated xattr inspection failure")
            if self.quarantine_at_xattr_call == self.xattr_count:
                return installer.CommandResult(
                    0,
                    stdout=(
                        f"{command[-1]}/Contents/MacOS/{installer.APP_NAME}: "
                        f"{installer.QUARANTINE_ATTRIBUTE}: 0081;...\n"
                    ),
                )
            return installer.CommandResult(0)
        if executable == "pgrep":
            result = installer.CommandResult(
                self.pgrep_returncode,
                stdout=self.pgrep_stdout,
                stderr="pgrep failed\n" if self.pgrep_returncode > 1 else "",
            )
            if check and result.returncode != 0:
                raise installer.InstallerError("simulated pgrep failure")
            return result
        if executable == "open":
            if self.open_failure:
                raise installer.InstallerError("simulated launch failure")
            return installer.CommandResult(0)
        raise AssertionError(f"Unexpected command: {command}")

    def commands_named(self, executable_name: str) -> list[list[str]]:
        return [
            command
            for command, _ in self.calls
            if Path(command[0]).name == executable_name
        ]


class InstallerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.repo_root = self.root / "CodexReviewKit"
        project = (
            self.repo_root
            / "Tools"
            / "ReviewMonitor"
            / "CodexReviewMonitor.xcodeproj"
        )
        resolved = (
            project
            / "project.xcworkspace"
            / "xcshareddata"
            / "swiftpm"
            / "Package.resolved"
        )
        resolved.parent.mkdir(parents=True)
        resolved.write_text("{}\n", encoding="utf-8")

        self.home = self.root / "Home With Spaces"
        self.applications_directory = self.root / "System Applications"
        self.destination = (
            self.home / "Applications" / installer.APP_BUNDLE_NAME
        )
        self.lock_directory = self.root / "locks"
        self.toolchain = self._create_fake_toolchain()
        self.host = installer.HostEnvironment(
            system="Darwin",
            macos_version="26.6.2",
            architecture="arm64",
        )
        self.runner = FakeRunner()
        self.output = io.StringIO()

    def _create_fake_toolchain(self) -> installer.Toolchain:
        tools_directory = self.root / "tools"
        tools_directory.mkdir()
        tool_paths = {}
        for name in (
            "xcodebuild",
            "codesign",
            "ditto",
            "lipo",
            "pgrep",
            "open",
            "xattr",
        ):
            path = tools_directory / name
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            path.chmod(0o755)
            tool_paths[name] = str(path)
        return installer.Toolchain(**tool_paths)

    def make_installer(
        self,
        *,
        destination: Optional[Path] = None,
        signing_identity: str = "-",
        launch: bool = False,
        process_checker=lambda: (),
        rename=os.rename,
    ) -> installer.ReviewMonitorInstaller:
        configuration = installer.InstallerConfiguration(
            repo_root=self.repo_root,
            destination=destination or self.destination,
            signing_identity=signing_identity,
            launch=launch,
        )
        return installer.ReviewMonitorInstaller(
            configuration,
            runner=self.runner,
            host=self.host,
            toolchain=self.toolchain,
            process_checker=process_checker,
            rename=rename,
            home_directory=self.home,
            applications_directory=self.applications_directory,
            lock_directory=self.lock_directory,
            output=self.output,
        )

    def marker(self, app_path: Path) -> str:
        return (
            app_path
            / "Contents"
            / "Resources"
            / "build-marker.txt"
        ).read_text(encoding="utf-8")

    def staging_paths(self) -> list[Path]:
        if not self.destination.parent.exists():
            return []
        return list(
            self.destination.parent.glob(f".{installer.APP_NAME}.install-*")
        )

    def test_destination_defaults_to_user_applications(self) -> None:
        selected = installer.select_destination(None, home_directory=self.home)

        self.assertEqual(selected, self.destination)

    def test_destination_requires_expected_bundle_name(self) -> None:
        with self.assertRaisesRegex(installer.InstallerError, "must end with"):
            installer.select_destination(
                self.root / "Other.app",
                home_directory=self.home,
            )

    def test_new_install_builds_signs_and_validates_before_publish(self) -> None:
        self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "new")
        self.assertFalse(self.make_installer().configuration.backup_path.exists())
        self.assertEqual(self.staging_paths(), [])

        build_command = self.runner.commands_named("xcodebuild")[1]
        self.assertIn("-configuration", build_command)
        self.assertIn("Release", build_command)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", build_command)
        self.assertIn("ARCHS=arm64", build_command)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", build_command)

        sign_command = next(
            command
            for command in self.runner.commands_named("codesign")
            if "--sign" in command
        )
        self.assertIn("runtime", sign_command)
        self.assertIn("--timestamp=none", sign_command)
        self.assertEqual(sign_command[sign_command.index("--sign") + 1], "-")
        self.assertNotIn("--deep", sign_command)

        ditto_call = next(
            call for call in self.runner.calls if Path(call[0][0]).name == "ditto"
        )
        ditto_command, ditto_environment = ditto_call
        self.assertTrue({"--rsrc", "--extattr", "--acl", "--qtn"}.issubset(ditto_command))
        self.assertIsNotNone(ditto_environment)
        self.assertNotIn("DITTONORSRC", ditto_environment)
        self.assertEqual(self.runner.commands_named("open"), [])

    def test_existing_app_is_replaced_only_after_new_app_validates(self) -> None:
        create_app(self.destination, marker="old")

        self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "new")
        self.assertFalse(self.make_installer().configuration.backup_path.exists())

    def test_build_failure_preserves_existing_app(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.fail_build = True

        with self.assertRaisesRegex(installer.InstallerError, "build failure"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertFalse(self.make_installer().configuration.backup_path.exists())

    def test_running_app_fails_before_build(self) -> None:
        with self.assertRaisesRegex(installer.InstallerError, "active reviews"):
            self.make_installer(process_checker=lambda: ("123",)).install()

        build_commands = [
            command
            for command in self.runner.commands_named("xcodebuild")
            if len(command) > 1 and command[1] == "build"
        ]
        self.assertEqual(build_commands, [])

    def test_pgrep_inspection_failure_is_not_treated_as_not_running(self) -> None:
        self.runner.pgrep_returncode = 2
        local_installer = self.make_installer(process_checker=None)
        local_installer.process_checker = local_installer._running_process_ids

        with self.assertRaisesRegex(installer.InstallerError, "Could not determine"):
            local_installer.install()

    def test_conflicting_system_installation_fails_before_build(self) -> None:
        system_app = self.applications_directory / installer.APP_BUNDLE_NAME
        create_app(system_app)

        with self.assertRaisesRegex(installer.InstallerError, "would conflict"):
            self.make_installer().install()

        self.assertFalse(self.destination.exists())

    def test_different_bundle_at_standard_path_does_not_conflict(self) -> None:
        system_app = self.applications_directory / installer.APP_BUNDLE_NAME
        create_app(system_app, bundle_identifier="example.Unrelated")

        self.make_installer().install()

        self.assertTrue(self.destination.exists())
        self.assertEqual(
            self.make_installer()._bundle_identifier(system_app),
            "example.Unrelated",
        )

    def test_wrong_bundle_at_destination_is_never_replaced(self) -> None:
        create_app(self.destination, bundle_identifier="example.Unrelated", marker="old")

        with self.assertRaisesRegex(installer.InstallerError, "Unexpected bundle"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")

    def test_symbolic_link_destination_is_never_replaced(self) -> None:
        actual_app = self.root / "Actual.app"
        create_app(actual_app)
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to(actual_app, target_is_directory=True)

        with self.assertRaisesRegex(installer.InstallerError, "symbolic-link"):
            self.make_installer().install()

        self.assertTrue(actual_app.exists())

    def test_quarantine_in_nested_content_stops_before_replacement(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.quarantine_at_xattr_call = 2

        with self.assertRaisesRegex(installer.InstallerError, "quarantine"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.staging_paths(), [])

    def test_quarantine_inspection_failure_stops_before_replacement(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.fail_xattr_at = 2

        with self.assertRaisesRegex(installer.InstallerError, "xattr inspection"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")

    def test_architecture_mismatch_stops_before_replacement(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.architectures = "x86_64\n"

        with self.assertRaisesRegex(installer.InstallerError, "thin arm64"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")

    def test_missing_runtime_flag_stops_before_replacement(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.runtime_signature = False

        with self.assertRaisesRegex(installer.InstallerError, "hardened runtime"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")

    def test_final_validation_failure_restores_previous_app(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.fail_verify_at = 2

        with self.assertRaisesRegex(installer.InstallerError, "previous app was restored"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertFalse(self.make_installer().configuration.backup_path.exists())
        self.assertEqual(self.staging_paths(), [])

    def test_final_validation_failure_removes_invalid_new_install(self) -> None:
        self.runner.fail_verify_at = 2

        with self.assertRaisesRegex(installer.InstallerError, "was removed"):
            self.make_installer().install()

        self.assertFalse(self.destination.exists())
        self.assertEqual(self.staging_paths(), [])

    def test_existing_app_backup_failure_leaves_destination_unchanged(self) -> None:
        create_app(self.destination, marker="old")

        def fail_backup(source: Path, destination: Path) -> None:
            del source, destination
            raise OSError("simulated backup failure")

        with self.assertRaisesRegex(installer.InstallerError, "backup path"):
            self.make_installer(rename=fail_backup).install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.staging_paths(), [])

    def test_unrelated_stale_backup_is_not_moved(self) -> None:
        backup = self.make_installer().configuration.backup_path
        create_app(backup, bundle_identifier="example.Unrelated", marker="unrelated")

        with self.assertRaisesRegex(installer.InstallerError, "Unexpected bundle"):
            self.make_installer().install()

        self.assertEqual(self.marker(backup), "unrelated")
        self.assertFalse(self.destination.exists())

    def test_new_app_move_failure_restores_previous_app(self) -> None:
        create_app(self.destination, marker="old")
        rename_count = 0

        def fail_new_app_move(source: Path, destination: Path) -> None:
            nonlocal rename_count
            rename_count += 1
            if rename_count == 2:
                raise OSError("simulated new app move failure")
            os.rename(source, destination)

        with self.assertRaisesRegex(installer.InstallerError, "new app into place"):
            self.make_installer(rename=fail_new_app_move).install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertFalse(self.make_installer().configuration.backup_path.exists())
        self.assertEqual(self.staging_paths(), [])

    def test_destination_swap_during_backup_is_restored_and_never_deleted(self) -> None:
        create_app(self.destination, marker="old")
        displaced_app = self.root / "Externally Displaced.app"
        rename_count = 0

        def swap_before_backup(source: Path, destination: Path) -> None:
            nonlocal rename_count
            rename_count += 1
            if rename_count == 1:
                os.rename(source, displaced_app)
                create_app(source, marker="external replacement")
            os.rename(source, destination)

        with self.assertRaisesRegex(installer.InstallerError, "changed during"):
            self.make_installer(rename=swap_before_backup).install()

        self.assertEqual(self.marker(self.destination), "external replacement")
        self.assertEqual(self.marker(displaced_app), "old")
        self.assertFalse(self.make_installer().configuration.backup_path.exists())
        self.assertEqual(self.staging_paths(), [])

    def test_rollback_failure_preserves_backup_and_failed_stage(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.fail_verify_at = 2
        rename_count = 0

        def fail_restore(source: Path, destination: Path) -> None:
            nonlocal rename_count
            rename_count += 1
            if rename_count == 4:
                raise OSError("simulated rollback failure")
            os.rename(source, destination)

        with self.assertRaisesRegex(
            installer.PreservedInstallStateError,
            "Recovery state was preserved",
        ):
            self.make_installer(rename=fail_restore).install()

        backup = self.make_installer().configuration.backup_path
        self.assertEqual(self.marker(backup), "old")
        staging_paths = self.staging_paths()
        self.assertEqual(len(staging_paths), 1)
        self.assertEqual(
            self.marker(staging_paths[0] / f"{installer.APP_NAME}.failed.app"),
            "new",
        )

    def test_keyboard_interrupt_rolls_back_previous_app(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.interrupt_verify_at = 2

        with self.assertRaises(KeyboardInterrupt):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.staging_paths(), [])

    def test_app_started_during_build_stops_before_publish(self) -> None:
        create_app(self.destination, marker="old")
        checks = 0

        def process_checker():
            nonlocal checks
            checks += 1
            return () if checks < 3 else ("456",)

        with self.assertRaisesRegex(installer.InstallerError, "active reviews"):
            self.make_installer(process_checker=process_checker).install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.staging_paths(), [])

    def test_explicit_identity_is_one_argument_and_launches_after_install(self) -> None:
        identity = "Apple Development: Local Developer (ABCDE12345)"

        self.make_installer(signing_identity=identity, launch=True).install()

        sign_command = next(
            command
            for command in self.runner.commands_named("codesign")
            if "--sign" in command
        )
        self.assertEqual(sign_command[sign_command.index("--sign") + 1], identity)
        open_command = self.runner.commands_named("open")[-1]
        self.assertEqual(open_command[-1], str(self.destination))

    def test_launch_failure_does_not_remove_installed_app(self) -> None:
        self.runner.open_failure = True

        with self.assertRaisesRegex(installer.InstallerError, "installed successfully"):
            self.make_installer(launch=True).install()

        self.assertEqual(self.marker(self.destination), "new")

    def test_lock_contention_fails_before_build(self) -> None:
        first = self.make_installer()
        second_destination = (
            self.root / "Alternate Applications" / installer.APP_BUNDLE_NAME
        )
        second = self.make_installer(destination=second_destination)

        with first._exclusive_install_lock():
            with self.assertRaisesRegex(installer.InstallerError, "already targeting"):
                second.install()

        build_commands = [
            command
            for command in self.runner.commands_named("xcodebuild")
            if len(command) > 1 and command[1] == "build"
        ]
        self.assertEqual(build_commands, [])

    def test_help_is_available_without_running_installer(self) -> None:
        help_output = io.StringIO()
        with contextlib.redirect_stdout(help_output):
            with self.assertRaises(SystemExit) as exit_context:
                installer.parse_arguments(["--help"])

        self.assertEqual(exit_context.exception.code, 0)
        self.assertIn("--signing-identity", help_output.getvalue())


@unittest.skipUnless(
    os.environ.get("RUN_INSTALLER_INTEGRATION") == "1",
    "set RUN_INSTALLER_INTEGRATION=1 to build and install into a temporary root",
)
class InstallerIntegrationTests(unittest.TestCase):
    def test_real_build_sign_and_temporary_install(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            destination = root / "Applications" / installer.APP_BUNDLE_NAME
            configuration = installer.InstallerConfiguration(
                repo_root=repo_root,
                destination=destination,
                signing_identity="-",
                launch=False,
            )
            local_installer = installer.ReviewMonitorInstaller(
                configuration,
                process_checker=lambda: (),
                home_directory=root / "Home",
                applications_directory=root / "System Applications",
                lock_directory=root / "locks",
            )

            local_installer.install()

            self.assertTrue(destination.is_dir())
            self.assertEqual(
                local_installer._bundle_identifier(destination),
                installer.BUNDLE_IDENTIFIER,
            )


if __name__ == "__main__":
    unittest.main()
