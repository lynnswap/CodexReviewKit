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
from unittest import mock


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
        self.xattr_count = 0
        self.quarantine_at_xattr_call: Optional[int] = None
        self.fail_xattr_at: Optional[int] = None
        self.pgrep_returncode = 1
        self.pgrep_stdout = ""
        self.arm64_capability = "1\n"
        self.open_failure = False
        self.app_to_create_after_build: Optional[Path] = None

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
            if self.app_to_create_after_build is not None:
                create_app(
                    self.app_to_create_after_build,
                    marker="external installation",
                )
            return installer.CommandResult(0)
        if executable == "ditto":
            source = Path(command[-2])
            destination = Path(command[-1])
            shutil.copytree(source, destination, symlinks=True)
            return installer.CommandResult(0)
        if executable == "codesign" and "--verify" in command:
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
        if executable == "sysctl":
            return installer.CommandResult(0, stdout=self.arm64_capability)
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
        self.applications_directory.mkdir()
        self.destination = (
            self.home / "Applications" / installer.APP_BUNDLE_NAME
        )
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
            "sysctl",
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
        exclusive_rename=installer.rename_exclusive,
        swap_rename=installer.rename_swap,
        applications_directory: Optional[Path] = None,
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
            exclusive_rename=exclusive_rename,
            swap_rename=swap_rename,
            home_directory=self.home,
            applications_directory=(
                applications_directory or self.applications_directory
            ),
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

    def test_destination_defaults_to_system_applications(self) -> None:
        selected = installer.select_destination(
            None,
            home_directory=self.home,
            applications_directory=self.applications_directory,
        )

        self.assertEqual(
            selected,
            self.applications_directory / installer.APP_BUNDLE_NAME,
        )

    def test_default_destination_is_deployed_to_system_applications(self) -> None:
        selected = installer.select_destination(
            None,
            home_directory=self.home,
            applications_directory=self.applications_directory,
        )

        self.make_installer(destination=selected).install()

        self.assertEqual(self.marker(selected), "new")

    def test_standard_destination_case_alias_is_canonicalized(self) -> None:
        selected = installer.select_destination(
            self.home / "applications" / installer.APP_BUNDLE_NAME,
            home_directory=self.home,
            applications_directory=self.applications_directory,
        )
        create_app(self.destination, marker="old")

        self.make_installer(destination=selected).install()

        self.assertEqual(selected, self.destination)
        self.assertEqual(self.marker(self.destination), "new")

    def test_destination_requires_expected_bundle_name(self) -> None:
        with self.assertRaisesRegex(installer.InstallerError, "must end with"):
            installer.select_destination(
                self.root / "Other.app",
                home_directory=self.home,
                applications_directory=self.applications_directory,
            )

    def test_new_install_builds_signs_and_validates_before_publish(self) -> None:
        self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "new")
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

    def test_build_failure_preserves_existing_app(self) -> None:
        create_app(self.destination, marker="old")
        self.runner.fail_build = True

        with self.assertRaisesRegex(installer.InstallerError, "build failure"):
            self.make_installer().install()

        self.assertEqual(self.marker(self.destination), "old")

    def test_build_product_destination_is_rejected_before_cleanup(self) -> None:
        build_product = self.make_installer().configuration.build_product_path
        create_app(build_product, marker="existing destination")

        with self.assertRaisesRegex(installer.InstallerError, "outside Xcode"):
            self.make_installer(destination=build_product).install()

        self.assertEqual(self.marker(build_product), "existing destination")
        self.assertEqual(
            [
                command
                for command in self.runner.commands_named("xcodebuild")
                if len(command) > 1 and command[1] == "build"
            ],
            [],
        )
        self.assertEqual(self.runner.commands_named("ditto"), [])

    def test_nested_build_product_destination_is_rejected_before_cleanup(self) -> None:
        build_product = self.make_installer().configuration.build_product_path
        destination = build_product / "Nested" / installer.APP_BUNDLE_NAME
        create_app(destination, marker="nested destination")

        with self.assertRaisesRegex(installer.InstallerError, "outside Xcode"):
            self.make_installer(destination=destination).install()

        self.assertEqual(self.marker(destination), "nested destination")
        self.assertEqual(
            [
                command
                for command in self.runner.commands_named("xcodebuild")
                if len(command) > 1 and command[1] == "build"
            ],
            [],
        )

    def test_build_product_destination_via_parent_symlink_is_rejected(self) -> None:
        build_product = self.make_installer().configuration.build_product_path
        destination = build_product / "Nested" / installer.APP_BUNDLE_NAME
        create_app(destination, marker="aliased destination")
        alias = self.root / "Build Product Alias"
        alias.symlink_to(build_product, target_is_directory=True)
        aliased_destination = alias / "Nested" / installer.APP_BUNDLE_NAME

        with self.assertRaisesRegex(installer.InstallerError, "outside Xcode"):
            self.make_installer(destination=aliased_destination).install()

        self.assertEqual(self.marker(destination), "aliased destination")
        self.assertEqual(
            [
                command
                for command in self.runner.commands_named("xcodebuild")
                if len(command) > 1 and command[1] == "build"
            ],
            [],
        )
        self.assertEqual(self.runner.commands_named("ditto"), [])

    def test_derived_data_name_prefix_does_not_overlap(self) -> None:
        derived_data = self.make_installer().configuration.derived_data_path
        destination = (
            derived_data.parent
            / f"{derived_data.name}-copy"
            / installer.APP_BUNDLE_NAME
        )

        self.make_installer(destination=destination).install()

        self.assertEqual(self.marker(destination), "new")

    def test_destination_containing_derived_data_is_rejected(self) -> None:
        destination = self.root / "Workspace" / installer.APP_BUNDLE_NAME
        configuration = installer.InstallerConfiguration(
            repo_root=destination / "Checkout",
            destination=destination,
            signing_identity="-",
            launch=False,
        )
        local_installer = installer.ReviewMonitorInstaller(
            configuration,
            runner=self.runner,
            host=self.host,
            toolchain=self.toolchain,
            process_checker=lambda: (),
            home_directory=self.home,
            applications_directory=self.applications_directory,
            output=self.output,
        )

        with self.assertRaisesRegex(installer.InstallerError, "outside Xcode"):
            local_installer._ensure_destination_safe()

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

    def test_running_process_check_matches_the_full_app_executable_path(self) -> None:
        local_installer = self.make_installer(process_checker=None)
        local_installer.process_checker = local_installer._running_process_ids

        self.assertEqual(local_installer._running_process_ids(), ())

        pgrep_command = self.runner.commands_named("pgrep")[-1]
        self.assertEqual(pgrep_command[1:3], ["-a", "-f"])
        self.assertEqual(pgrep_command[3], installer.RUNNING_EXECUTABLE_PATTERN)
        self.assertTrue(pgrep_command[3].startswith("^"))
        self.assertIn("Contents/MacOS/CodexReviewMonitor", pgrep_command[3])

    def test_rosetta_process_is_allowed_on_an_apple_silicon_host(self) -> None:
        self.host = installer.HostEnvironment(
            system="Darwin",
            macos_version="26.6.2",
            architecture="x86_64",
        )

        self.make_installer().install()

        self.assertTrue(self.destination.exists())

    def test_physical_host_without_arm64_capability_is_rejected(self) -> None:
        self.host = installer.HostEnvironment(
            system="Darwin",
            macos_version="26.6.2",
            architecture="x86_64",
        )
        self.runner.arm64_capability = "0\n"

        with self.assertRaisesRegex(installer.InstallerError, "Apple silicon"):
            self.make_installer().install()

        self.assertFalse(self.destination.exists())

    def test_conflicting_system_installation_fails_before_build(self) -> None:
        system_app = self.applications_directory / installer.APP_BUNDLE_NAME
        create_app(system_app)

        with self.assertRaisesRegex(installer.InstallerError, "would conflict"):
            self.make_installer().install()

        self.assertFalse(self.destination.exists())

    def test_existing_system_destination_requires_manual_removal(self) -> None:
        system_app = self.applications_directory / installer.APP_BUNDLE_NAME
        create_app(system_app, marker="system app")
        default_destination = installer.select_destination(
            None,
            home_directory=self.home,
            applications_directory=self.applications_directory,
        )

        with self.assertRaisesRegex(installer.InstallerError, "Remove it manually"):
            self.make_installer(destination=default_destination).install()

        self.assertEqual(self.marker(system_app), "system app")
        self.assertEqual(
            [
                command
                for command in self.runner.commands_named("xcodebuild")
                if len(command) > 1 and command[1] == "build"
            ],
            [],
        )

    def test_system_destination_is_rechecked_after_build(self) -> None:
        system_app = self.applications_directory / installer.APP_BUNDLE_NAME
        default_destination = installer.select_destination(
            None,
            home_directory=self.home,
            applications_directory=self.applications_directory,
        )
        self.runner.app_to_create_after_build = system_app

        with self.assertRaisesRegex(installer.InstallerError, "Remove it manually"):
            self.make_installer(destination=default_destination).install()

        self.assertEqual(self.marker(system_app), "external installation")
        build_commands = [
            command
            for command in self.runner.commands_named("xcodebuild")
            if len(command) > 1 and command[1] == "build"
        ]
        self.assertEqual(len(build_commands), 1)
        self.assertEqual(
            list(
                self.applications_directory.glob(
                    f".{installer.APP_NAME}.install-*"
                )
            ),
            [],
        )

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

    def test_atomic_swap_failure_leaves_existing_app_unchanged(self) -> None:
        create_app(self.destination, marker="old")

        def fail_swap(first: Path, second: Path) -> None:
            del first, second
            raise OSError("simulated atomic swap failure")

        with self.assertRaisesRegex(installer.InstallerError, "atomically replace"):
            self.make_installer(swap_rename=fail_swap).install()

        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.staging_paths(), [])

    def test_exclusive_move_interrupt_after_syscall_preserves_the_app(self) -> None:
        source = self.root / "Exclusive Source.app"
        destination = self.root / "Exclusive Destination.app"
        create_app(source, marker="source")
        local_installer = self.make_installer()
        source_identity = local_installer._filesystem_identity_if_exists(source)
        require_app = local_installer._require_expected_filesystem_app
        checks = 0

        def interrupt_after_move(path: Path, expected_identity) -> None:
            nonlocal checks
            checks += 1
            if checks == 2:
                raise KeyboardInterrupt()
            require_app(path, expected_identity)

        local_installer._require_expected_filesystem_app = interrupt_after_move

        with self.assertRaisesRegex(
            installer.PreservedInstallStateError,
            "interrupted during an app move",
        ):
            local_installer._move_expected_app_exclusively(
                source,
                destination,
                source_identity,
            )

        self.assertFalse(source.exists())
        self.assertEqual(self.marker(destination), "source")

    def test_swap_interrupt_after_syscall_preserves_both_apps(self) -> None:
        first = self.root / "First.app"
        second = self.root / "Second.app"
        create_app(first, marker="first")
        create_app(second, marker="second")
        local_installer = self.make_installer()
        first_identity = local_installer._filesystem_identity_if_exists(first)
        second_identity = local_installer._filesystem_identity_if_exists(second)
        require_app = local_installer._require_expected_filesystem_app
        checks = 0

        def interrupt_after_swap(path: Path, expected_identity) -> None:
            nonlocal checks
            checks += 1
            if checks == 3:
                raise KeyboardInterrupt()
            require_app(path, expected_identity)

        local_installer._require_expected_filesystem_app = interrupt_after_swap

        with self.assertRaisesRegex(
            installer.PreservedInstallStateError,
            "interrupted during an atomic app swap",
        ):
            local_installer._swap_expected_apps(
                first,
                first_identity,
                second,
                second_identity,
            )

        self.assertEqual(self.marker(first), "second")
        self.assertEqual(self.marker(second), "first")

    def test_new_destination_collision_is_not_replaced(self) -> None:
        def occupy_destination_before_publish(
            source: Path,
            destination: Path,
        ) -> None:
            create_app(self.destination, marker="external destination")
            installer.rename_exclusive(source, destination)

        with self.assertRaisesRegex(installer.InstallerError, "Could not install"):
            self.make_installer(
                exclusive_rename=occupy_destination_before_publish
            ).install()

        self.assertEqual(self.marker(self.destination), "external destination")
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

    def test_staged_app_swap_after_validation_is_preserved(self) -> None:
        displaced_staged_app = self.root / "Displaced Validated Staged.app"
        checks = 0

        def process_checker():
            nonlocal checks
            checks += 1
            if checks == 3:
                stage_root = self.staging_paths()[0]
                staged_app = stage_root / installer.APP_BUNDLE_NAME
                os.rename(staged_app, displaced_staged_app)
                create_app(staged_app, marker="external staged app")
            return ()

        with self.assertRaisesRegex(
            installer.PreservedInstallStateError,
            "identity changed while it was being moved",
        ):
            self.make_installer(process_checker=process_checker).install()

        self.assertFalse(self.destination.exists())
        self.assertEqual(self.marker(displaced_staged_app), "new")
        staging_paths = self.staging_paths()
        self.assertEqual(len(staging_paths), 1)
        self.assertEqual(
            self.marker(staging_paths[0] / installer.APP_BUNDLE_NAME),
            "external staged app",
        )

    def test_staged_app_swap_during_validation_is_preserved(self) -> None:
        displaced_staged_app = self.root / "Displaced During Validation.app"
        local_installer = self.make_installer()
        validate_app = local_installer._validate_app

        def swap_after_validation(staged_app: Path) -> None:
            validate_app(staged_app)
            os.rename(staged_app, displaced_staged_app)
            create_app(staged_app, marker="external unvalidated app")

        local_installer._validate_app = swap_after_validation

        with self.assertRaisesRegex(
            installer.PreservedInstallStateError,
            "changed during validation",
        ):
            local_installer.install()

        self.assertFalse(self.destination.exists())
        self.assertEqual(self.marker(displaced_staged_app), "new")
        staging_paths = self.staging_paths()
        self.assertEqual(len(staging_paths), 1)
        self.assertEqual(
            self.marker(staging_paths[0] / installer.APP_BUNDLE_NAME),
            "external unvalidated app",
        )

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
        second_destination = self.applications_directory / installer.APP_BUNDLE_NAME
        second = self.make_installer(destination=second_destination)

        with first._exclusive_install_lock():
            with self.assertRaisesRegex(installer.InstallerError, "already running"):
                second.install()

        build_commands = [
            command
            for command in self.runner.commands_named("xcodebuild")
            if len(command) > 1 and command[1] == "build"
        ]
        self.assertEqual(build_commands, [])

    def test_lock_uses_the_existing_system_applications_directory(self) -> None:
        local_installer = self.make_installer()
        entries_before_lock = list(self.applications_directory.iterdir())

        with mock.patch.object(installer.os, "open", wraps=os.open) as open_lock:
            with local_installer._exclusive_install_lock():
                self.assertEqual(
                    list(self.applications_directory.iterdir()),
                    entries_before_lock,
                )

        lock_path, open_flags = open_lock.call_args.args
        self.assertEqual(Path(lock_path), self.applications_directory)
        for required_flag in (
            os.O_DIRECTORY,
            os.O_NOFOLLOW,
            os.O_CLOEXEC,
            os.O_EXLOCK,
            os.O_NONBLOCK,
        ):
            self.assertTrue(open_flags & required_flag)
        self.assertFalse(open_flags & os.O_CREAT)

    def test_invalid_shared_lock_anchors_are_rejected(self) -> None:
        real_directory = self.root / "Real Applications"
        real_directory.mkdir()
        invalid_anchors = {
            "missing": self.root / "Missing Applications",
            "file": self.root / "Applications File",
            "symlink": self.root / "Applications Link",
        }
        invalid_anchors["file"].write_text("not a directory", encoding="utf-8")
        invalid_anchors["symlink"].symlink_to(
            real_directory,
            target_is_directory=True,
        )

        for name, anchor in invalid_anchors.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(
                    installer.InstallerError,
                    "shared installation namespace",
                ):
                    with self.make_installer(
                        applications_directory=anchor
                    )._exclusive_install_lock():
                        self.fail("an invalid lock anchor must not be acquired")

    def test_help_is_available_without_running_installer(self) -> None:
        help_output = io.StringIO()
        with contextlib.redirect_stdout(help_output):
            with self.assertRaises(SystemExit) as exit_context:
                installer.parse_arguments(["--help"])

        self.assertEqual(exit_context.exception.code, 0)
        self.assertIn("--signing-identity", help_output.getvalue())
        self.assertIn(
            f"/Applications/{installer.APP_BUNDLE_NAME}",
            help_output.getvalue(),
        )


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
            applications_directory = root / "System Applications"
            applications_directory.mkdir()
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
                applications_directory=applications_directory,
            )
            create_app(destination, marker="old")

            local_installer.install()

            self.assertTrue(destination.is_dir())
            self.assertFalse(
                (destination / "Contents" / "Resources" / "build-marker.txt").exists()
            )
            self.assertEqual(
                local_installer._bundle_identifier(destination),
                installer.BUNDLE_IDENTIFIER,
            )


if __name__ == "__main__":
    unittest.main()
