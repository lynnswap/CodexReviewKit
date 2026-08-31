#!/usr/bin/env python3
"""Build and install CodexReviewMonitor from the current checkout."""

from __future__ import annotations

import argparse
import os
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence, TextIO


APP_NAME = "CodexReviewMonitor"
APP_BUNDLE_NAME = f"{APP_NAME}.app"
BUNDLE_IDENTIFIER = "lynnpd.CodexReviewMonitor"
MINIMUM_MACOS_MAJOR = 26
MINIMUM_XCODE_VERSION = (26, 4)
SUPPORTED_ARCHITECTURE = "arm64"
QUARANTINE_ATTRIBUTE = "com.apple.quarantine"
RUNNING_EXECUTABLE_PATTERN = (
    rf"^(.*/)?{APP_NAME}[.]app/Contents/MacOS/{APP_NAME}([[:space:]].*)?$"
)


class InstallerError(RuntimeError):
    """A user-actionable local installation failure."""


class PreservedInstallStateError(InstallerError):
    """A failure whose recovery artifacts must not be deleted."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


@dataclass(frozen=True)
class FilesystemIdentity:
    device: int
    inode: int
    mode: int


class CommandRunner:
    def __init__(self, output: TextIO = sys.stdout) -> None:
        self.output = output

    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Optional[Path] = None,
        check: bool = True,
        capture_output: bool = False,
        environment: Optional[Mapping[str, str]] = None,
    ) -> CommandResult:
        command = [str(argument) for argument in arguments]
        print(f"+ {shlex.join(command)}", file=self.output, flush=True)
        completed = subprocess.run(
            command,
            cwd=str(cwd) if cwd is not None else None,
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None,
            env=dict(environment) if environment is not None else None,
        )
        result = CommandResult(
            returncode=completed.returncode,
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
        )
        if check and result.returncode != 0:
            details = "\n".join(
                output.strip()
                for output in (result.stdout, result.stderr)
                if output.strip()
            )
            message = (
                f"Command failed with exit status {result.returncode}: "
                f"{shlex.join(command)}"
            )
            if details:
                message += f"\n{details}"
            raise InstallerError(message)
        return result


@dataclass(frozen=True)
class HostEnvironment:
    system: str
    macos_version: str
    architecture: str

    @classmethod
    def current(cls) -> "HostEnvironment":
        return cls(
            system=platform.system(),
            macos_version=platform.mac_ver()[0],
            architecture=platform.machine(),
        )


@dataclass(frozen=True)
class Toolchain:
    xcodebuild: str = "/usr/bin/xcodebuild"
    codesign: str = "/usr/bin/codesign"
    ditto: str = "/usr/bin/ditto"
    lipo: str = "/usr/bin/lipo"
    pgrep: str = "/usr/bin/pgrep"
    sysctl: str = "/usr/sbin/sysctl"
    open: str = "/usr/bin/open"
    xattr: str = "/usr/bin/xattr"

    @property
    def required_paths(self) -> tuple[str, ...]:
        return (
            self.xcodebuild,
            self.codesign,
            self.ditto,
            self.lipo,
            self.pgrep,
            self.sysctl,
            self.open,
            self.xattr,
        )


@dataclass(frozen=True)
class InstallerConfiguration:
    repo_root: Path
    destination: Path
    signing_identity: str
    launch: bool
    architecture: str = SUPPORTED_ARCHITECTURE

    @property
    def derived_data_path(self) -> Path:
        return self.repo_root / ".build" / f"local-installer-{self.architecture}"

    @property
    def build_product_path(self) -> Path:
        return (
            self.derived_data_path
            / "Build"
            / "Products"
            / "Release"
            / APP_BUNDLE_NAME
        )

    @property
    def backup_path(self) -> Path:
        return self.destination.parent / f".{APP_NAME}.backup.app"


def _path_exists(path: Path) -> bool:
    return os.path.lexists(str(path))


def _absolute_path(path: Path) -> Path:
    expanded = path.expanduser()
    if not expanded.is_absolute():
        expanded = Path.cwd() / expanded
    return Path(os.path.abspath(str(expanded)))


def standard_installation_paths(
    home_directory: Path,
    applications_directory: Path = Path("/Applications"),
) -> tuple[Path, Path]:
    return (
        home_directory / "Applications" / APP_BUNDLE_NAME,
        applications_directory / APP_BUNDLE_NAME,
    )


def select_destination(
    requested: Optional[Path],
    *,
    home_directory: Optional[Path] = None,
) -> Path:
    home = home_directory or Path.home()
    standard_paths = tuple(
        _absolute_path(path) for path in standard_installation_paths(home)
    )
    destination = standard_paths[0] if requested is None else _absolute_path(requested)

    if destination.name != APP_BUNDLE_NAME:
        raise InstallerError(
            f"The destination must end with {APP_BUNDLE_NAME}: {destination}"
        )
    return destination


class ReviewMonitorInstaller:
    def __init__(
        self,
        configuration: InstallerConfiguration,
        *,
        runner: Optional[CommandRunner] = None,
        host: Optional[HostEnvironment] = None,
        toolchain: Optional[Toolchain] = None,
        process_checker: Optional[Callable[[], Sequence[str]]] = None,
        rename: Callable[[Path, Path], None] = os.rename,
        home_directory: Optional[Path] = None,
        applications_directory: Path = Path("/Applications"),
        output: TextIO = sys.stdout,
    ) -> None:
        self.configuration = configuration
        self.runner = runner or CommandRunner(output)
        self.host = host or HostEnvironment.current()
        self.toolchain = toolchain or Toolchain()
        self.process_checker = process_checker or self._running_process_ids
        self.rename = rename
        self.home_directory = home_directory or Path.home()
        self.applications_directory = applications_directory
        self.output = output

    def install(self) -> None:
        self._preflight()
        with self._exclusive_install_lock():
            self._install_while_locked()

    def _install_while_locked(self) -> None:
        self._ensure_app_not_running()
        self._ensure_destination_safe()
        self._recover_interrupted_backup()
        self._build()

        destination_parent = self.configuration.destination.parent
        destination_parent.mkdir(parents=True, exist_ok=True)
        stage_root = Path(
            tempfile.mkdtemp(
                prefix=f".{APP_NAME}.install-",
                dir=str(destination_parent),
            )
        )
        staged_app = stage_root / APP_BUNDLE_NAME
        try:
            ditto_environment = dict(os.environ)
            ditto_environment.pop("DITTONORSRC", None)
            self.runner.run(
                [
                    self.toolchain.ditto,
                    "--rsrc",
                    "--extattr",
                    "--acl",
                    "--qtn",
                    str(self.configuration.build_product_path),
                    str(staged_app),
                ],
                environment=ditto_environment,
            )
            self._sign(staged_app)
            self._validate_app(staged_app)
            self._ensure_app_not_running()
            destination_identity = self._ensure_destination_safe()
            self._replace_destination(
                staged_app,
                stage_root,
                expected_destination_identity=destination_identity,
            )
        except PreservedInstallStateError:
            raise
        except BaseException:
            try:
                self._remove_stage_root(stage_root)
            except OSError as cleanup_error:
                raise PreservedInstallStateError(
                    "The install failed and its staging directory could not be "
                    f"removed. Inspect it before retrying: {stage_root}"
                ) from cleanup_error
            raise
        else:
            try:
                self._remove_stage_root(stage_root)
            except OSError as cleanup_error:
                raise PreservedInstallStateError(
                    f"{APP_NAME} was installed and validated, but the staging "
                    f"directory remains at {stage_root}"
                ) from cleanup_error

        print(
            f"Installed {APP_NAME} from the current checkout at: "
            f"{self.configuration.destination}",
            file=self.output,
        )
        if self.configuration.signing_identity == "-":
            print(
                "Signature: ad-hoc with hardened runtime (local use only)",
                file=self.output,
            )
        else:
            print(
                f"Signature: {self.configuration.signing_identity}",
                file=self.output,
            )

        if self.configuration.launch:
            try:
                self.runner.run(
                    [self.toolchain.open, str(self.configuration.destination)]
                )
            except InstallerError as launch_error:
                raise InstallerError(
                    f"{APP_NAME} was installed successfully, but launch failed: "
                    f"{launch_error}"
                ) from launch_error

    def _preflight(self) -> None:
        if self.host.system != "Darwin":
            raise InstallerError("The local installer requires macOS.")
        try:
            macos_major = int(self.host.macos_version.split(".", maxsplit=1)[0])
        except (ValueError, IndexError) as error:
            raise InstallerError(
                f"Could not determine the macOS version: {self.host.macos_version!r}"
            ) from error
        if macos_major < MINIMUM_MACOS_MAJOR:
            raise InstallerError(
                f"{APP_NAME} requires macOS {MINIMUM_MACOS_MAJOR} or newer; "
                f"this Mac reports {self.host.macos_version}."
            )
        for tool_path in self.toolchain.required_paths:
            if not os.path.isfile(tool_path) or not os.access(tool_path, os.X_OK):
                raise InstallerError(f"Required tool is unavailable: {tool_path}")

        arm64_capability = self.runner.run(
            [self.toolchain.sysctl, "-in", "hw.optional.arm64"],
            capture_output=True,
        ).stdout.strip()
        if arm64_capability != "1":
            raise InstallerError(
                f"The verified local build requires an Apple silicon Mac; "
                f"this host reports arm64 capability {arm64_capability!r} "
                f"from a {self.host.architecture} Python process."
            )

        project_path = (
            self.configuration.repo_root
            / "Tools"
            / "ReviewMonitor"
            / "CodexReviewMonitor.xcodeproj"
        )
        resolved_path = (
            project_path
            / "project.xcworkspace"
            / "xcshareddata"
            / "swiftpm"
            / "Package.resolved"
        )
        for required_path in (project_path, resolved_path):
            if not required_path.exists():
                raise InstallerError(
                    "Run this installer from a complete CodexReviewKit checkout; "
                    f"missing {required_path}"
                )

        xcode_version = self.runner.run(
            [self.toolchain.xcodebuild, "-version"],
            capture_output=True,
        ).stdout
        match = re.search(r"^Xcode (\d+)(?:\.(\d+))?", xcode_version, re.MULTILINE)
        if match is None:
            raise InstallerError(
                f"Could not parse the active Xcode version:\n{xcode_version.strip()}"
            )
        version = (int(match.group(1)), int(match.group(2) or 0))
        if version < MINIMUM_XCODE_VERSION:
            required = ".".join(str(component) for component in MINIMUM_XCODE_VERSION)
            actual = ".".join(str(component) for component in version)
            raise InstallerError(
                f"The local installer requires Xcode {required} or newer; "
                f"the active developer directory provides Xcode {actual}."
            )

        self._ensure_app_not_running()
        self._ensure_destination_safe()

    def _ensure_app_not_running(self) -> None:
        running_processes = tuple(self.process_checker())
        if running_processes:
            process_list = ", ".join(running_processes)
            raise InstallerError(
                f"Quit {APP_NAME} before installing so active reviews are not "
                f"interrupted. Running process IDs: {process_list}"
            )

    def _ensure_destination_safe(self) -> Optional[FilesystemIdentity]:
        self._ensure_build_workspace_disjoint_from_destination()
        destination = self.configuration.destination
        destination_identity = self._filesystem_identity_if_exists(destination)
        if destination.is_symlink():
            raise InstallerError(
                f"Refusing to replace a symbolic-link destination: {destination}"
            )
        if _path_exists(destination):
            if not destination.is_dir():
                raise InstallerError(
                    f"The destination exists but is not an app directory: {destination}"
                )
            self._require_expected_bundle_identifier(destination)

        conflicts = []
        for standard_path in standard_installation_paths(
            self.home_directory,
            self.applications_directory,
        ):
            candidate = _absolute_path(standard_path)
            if candidate == destination or not _path_exists(candidate):
                continue
            if candidate.is_symlink() or not candidate.is_dir():
                raise InstallerError(
                    f"A conflicting standard installation path is not a regular "
                    f"app directory: {candidate}"
                )
            if self._bundle_identifier(candidate) == BUNDLE_IDENTIFIER:
                conflicts.append(candidate)
        if conflicts:
            locations = "\n".join(f"  - {path}" for path in conflicts)
            raise InstallerError(
                "Another CodexReviewMonitor installation would conflict with the "
                f"selected destination:\n{locations}"
            )
        return destination_identity

    def _ensure_build_workspace_disjoint_from_destination(self) -> None:
        try:
            destination = self.configuration.destination.resolve(strict=False)
            derived_data = self.configuration.derived_data_path.resolve(strict=False)
        except (OSError, RuntimeError) as error:
            raise InstallerError(
                "Could not resolve the installation and build workspace paths"
            ) from error

        # macOS volumes are commonly case-insensitive even though resolve() keeps
        # the caller's spelling, so compare path components conservatively.
        destination_parts = tuple(part.casefold() for part in destination.parts)
        derived_data_parts = tuple(part.casefold() for part in derived_data.parts)
        destination_contains_build = (
            destination_parts == derived_data_parts[: len(destination_parts)]
        )
        build_contains_destination = (
            derived_data_parts == destination_parts[: len(derived_data_parts)]
        )
        if destination_contains_build or build_contains_destination:
            raise InstallerError(
                "The installation destination must be outside Xcode DerivedData:"
                f"\n  destination: {destination}"
                f"\n  DerivedData: {derived_data}"
            )

    @staticmethod
    def _filesystem_identity_if_exists(
        path: Path,
    ) -> Optional[FilesystemIdentity]:
        if not _path_exists(path):
            return None
        try:
            metadata = os.stat(path, follow_symlinks=False)
        except OSError as error:
            raise InstallerError(
                f"Could not inspect filesystem identity for {path}: {error}"
            ) from error
        return FilesystemIdentity(
            device=metadata.st_dev,
            inode=metadata.st_ino,
            mode=metadata.st_mode,
        )

    def _require_expected_filesystem_app(
        self,
        path: Path,
        expected_identity: Optional[FilesystemIdentity],
    ) -> None:
        actual_identity = self._filesystem_identity_if_exists(path)
        if expected_identity is None or actual_identity != expected_identity:
            raise InstallerError(
                f"Filesystem identity changed for the app at {path}"
            )
        self._require_expected_bundle_identifier(path)

    def _running_process_ids(self) -> Sequence[str]:
        result = self.runner.run(
            [self.toolchain.pgrep, "-a", "-f", RUNNING_EXECUTABLE_PATTERN],
            check=False,
            capture_output=True,
        )
        if result.returncode == 1:
            return ()
        if result.returncode != 0:
            raise InstallerError(
                f"Could not determine whether {APP_NAME} is running: "
                f"{result.stderr.strip() or f'exit status {result.returncode}'}"
            )
        return tuple(line for line in result.stdout.splitlines() if line)

    @contextmanager
    def _exclusive_install_lock(self):
        # A created lockfile can be unlinked and replaced while its old inode is
        # locked. The system Applications directory is an existing protected inode.
        lock_anchor = self.applications_directory
        open_flags = (
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | os.O_CLOEXEC
            | os.O_EXLOCK
            | os.O_NONBLOCK
        )
        try:
            descriptor = os.open(str(lock_anchor), open_flags)
        except BlockingIOError as error:
            raise InstallerError(
                f"Another {APP_NAME} installer is already running"
            ) from error
        except OSError as error:
            raise InstallerError(
                f"Could not lock the shared installation namespace at "
                f"{lock_anchor}: {error}"
            ) from error
        try:
            yield
        finally:
            os.close(descriptor)

    def _recover_interrupted_backup(self) -> None:
        backup = self.configuration.backup_path
        destination = self.configuration.destination
        if not _path_exists(backup):
            return
        if backup.is_symlink():
            raise InstallerError(
                f"Refusing to use a symbolic-link installer backup: {backup}"
            )
        if not backup.is_dir():
            raise PreservedInstallStateError(
                f"Installer backup is not an app directory and was not modified: "
                f"{backup}"
            )
        self._require_expected_bundle_identifier(backup)
        if _path_exists(destination):
            raise PreservedInstallStateError(
                "A previous installation left both the destination and backup in "
                f"place. Inspect them before retrying:\n  destination: {destination}"
                f"\n  backup: {backup}"
            )
        try:
            self.rename(backup, destination)
        except OSError as error:
            raise PreservedInstallStateError(
                f"Could not restore the previous app from {backup} to {destination}"
            ) from error
        print(
            f"Recovered an interrupted previous installation at: {destination}",
            file=self.output,
        )

    def _build(self) -> None:
        build_product = self.configuration.build_product_path
        if _path_exists(build_product):
            shutil.rmtree(build_product)
        self.configuration.derived_data_path.mkdir(parents=True, exist_ok=True)
        self.runner.run(
            [
                self.toolchain.xcodebuild,
                "build",
                "-project",
                "Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj",
                "-scheme",
                APP_NAME,
                "-configuration",
                "Release",
                "-destination",
                "generic/platform=macOS",
                "-derivedDataPath",
                str(self.configuration.derived_data_path),
                "-disableAutomaticPackageResolution",
                "-onlyUsePackageVersionsFromResolvedFile",
                "-skipMacroValidation",
                f"ARCHS={self.configuration.architecture}",
                "ONLY_ACTIVE_ARCH=NO",
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGN_IDENTITY=",
            ],
            cwd=self.configuration.repo_root,
        )
        if not build_product.is_dir():
            raise InstallerError(
                f"Xcode completed without producing the expected app: {build_product}"
            )
        self._assert_no_quarantine(build_product)

    def _sign(self, app_path: Path) -> None:
        self.runner.run(
            [
                self.toolchain.codesign,
                "--force",
                "--options",
                "runtime",
                "--timestamp=none",
                "--sign",
                self.configuration.signing_identity,
                str(app_path),
            ]
        )

    def _validate_app(self, app_path: Path) -> None:
        if not app_path.is_dir():
            raise InstallerError(f"Expected an app bundle at: {app_path}")
        info_path = app_path / "Contents" / "Info.plist"
        try:
            with info_path.open("rb") as info_file:
                info = plistlib.load(info_file)
        except (OSError, plistlib.InvalidFileException) as error:
            raise InstallerError(f"Could not read {info_path}: {error}") from error

        self._require_expected_bundle_identifier(app_path, info=info)
        executable_name = info.get("CFBundleExecutable")
        if not isinstance(executable_name, str) or not executable_name:
            raise InstallerError(f"CFBundleExecutable is missing from {info_path}")
        executable_path = app_path / "Contents" / "MacOS" / executable_name
        if not executable_path.is_file() or not os.access(executable_path, os.X_OK):
            raise InstallerError(
                f"The app executable is missing or not executable: {executable_path}"
            )

        self.runner.run(
            [
                self.toolchain.codesign,
                "--verify",
                "--deep",
                "--strict",
                "--verbose=2",
                str(app_path),
            ]
        )
        signature_description = self.runner.run(
            [self.toolchain.codesign, "--display", "--verbose=4", str(app_path)],
            capture_output=True,
        )
        signature_output = (
            signature_description.stdout + "\n" + signature_description.stderr
        )
        code_directory_line = next(
            (
                line
                for line in signature_output.splitlines()
                if line.startswith("CodeDirectory ")
            ),
            "",
        )
        if "runtime" not in code_directory_line:
            raise InstallerError(
                f"The app signature does not enable hardened runtime: {app_path}"
            )

        architectures = self.runner.run(
            [self.toolchain.lipo, "-archs", str(executable_path)],
            capture_output=True,
        ).stdout.split()
        if architectures != [self.configuration.architecture]:
            raise InstallerError(
                f"Expected a thin {self.configuration.architecture} executable at "
                f"{executable_path}, found: {' '.join(architectures) or '(none)'}"
            )
        self._assert_no_quarantine(app_path)

    def _bundle_identifier(self, app_path: Path) -> object:
        info_path = app_path / "Contents" / "Info.plist"
        try:
            with info_path.open("rb") as info_file:
                return plistlib.load(info_file).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException) as error:
            raise InstallerError(f"Could not read {info_path}: {error}") from error

    def _require_expected_bundle_identifier(
        self,
        app_path: Path,
        *,
        info: Optional[dict] = None,
    ) -> None:
        bundle_identifier = (
            info.get("CFBundleIdentifier")
            if info is not None
            else self._bundle_identifier(app_path)
        )
        if bundle_identifier != BUNDLE_IDENTIFIER:
            raise InstallerError(
                f"Unexpected bundle identifier in {app_path}: "
                f"{bundle_identifier!r}"
            )

    def _assert_no_quarantine(self, app_path: Path) -> None:
        metadata = self.runner.run(
            [self.toolchain.xattr, "-lr", str(app_path)],
            capture_output=True,
        )
        output = metadata.stdout + "\n" + metadata.stderr
        if QUARANTINE_ATTRIBUTE in output:
            raise InstallerError(
                f"The locally built app unexpectedly has {QUARANTINE_ATTRIBUTE}. "
                "The installer will not remove security metadata automatically: "
                f"{app_path}"
            )

    def _replace_destination(
        self,
        staged_app: Path,
        stage_root: Path,
        *,
        expected_destination_identity: Optional[FilesystemIdentity],
    ) -> None:
        destination = self.configuration.destination
        backup = self.configuration.backup_path
        failed_app = stage_root / f"{APP_NAME}.failed.app"
        previous_app = stage_root / f"{APP_NAME}.previous.app"
        old_app_moved = False

        if _path_exists(backup):
            raise PreservedInstallStateError(
                f"Installer backup already exists and was not modified: {backup}"
            )

        current_destination_identity = self._filesystem_identity_if_exists(destination)
        if current_destination_identity != expected_destination_identity:
            raise InstallerError(
                "The destination changed after validation and was not modified: "
                f"{destination}"
            )

        published_app_identity = self._filesystem_identity_if_exists(staged_app)
        if published_app_identity is None:
            raise InstallerError(
                f"The validated staged app disappeared before publication: {staged_app}"
            )

        if _path_exists(destination):
            try:
                self.rename(destination, backup)
            except KeyboardInterrupt:
                if _path_exists(backup) and not _path_exists(destination):
                    raise PreservedInstallStateError(
                        "Installation was interrupted after preserving the previous "
                        f"app. Recovery state was kept:\n  backup: {backup}"
                        f"\n  staging: {stage_root}"
                    )
                raise
            except OSError as error:
                raise InstallerError(
                    f"Could not move the existing app to its backup path: {backup}"
                ) from error

            try:
                self._require_expected_filesystem_app(
                    backup,
                    expected_destination_identity,
                )
            except (InstallerError, OSError) as identity_error:
                try:
                    self.rename(backup, destination)
                except OSError as rollback_error:
                    raise PreservedInstallStateError(
                        "The destination changed during publication and could not be "
                        f"restored. Recovery state was preserved:\n  backup: {backup}"
                        f"\n  staging: {stage_root}\n  destination: {destination}"
                    ) from rollback_error
                raise InstallerError(
                    "The destination changed during publication. The moved directory "
                    f"was restored and the new app was not installed: {destination}"
                ) from identity_error
            old_app_moved = True

        try:
            self.rename(staged_app, destination)
        except (Exception, KeyboardInterrupt) as install_error:
            if old_app_moved:
                try:
                    self.rename(backup, destination)
                except OSError as rollback_error:
                    raise PreservedInstallStateError(
                        "Installing the new app and restoring the previous app both "
                        f"failed. Recovery state was preserved:\n  backup: {backup}"
                        f"\n  staging: {stage_root}"
                    ) from rollback_error
            if isinstance(install_error, KeyboardInterrupt):
                raise
            raise InstallerError(
                f"Could not move the new app into place at {destination}"
            ) from install_error

        try:
            self._require_expected_filesystem_app(
                destination,
                published_app_identity,
            )
        except InstallerError as identity_error:
            raise PreservedInstallStateError(
                "The published app identity changed before final validation. "
                f"Nothing was deleted; inspect the preserved state:\n"
                f"  backup: {backup}\n  staging: {stage_root}"
                f"\n  destination: {destination}"
            ) from identity_error

        try:
            self._validate_app(destination)
        except (Exception, KeyboardInterrupt) as validation_error:
            try:
                self._require_expected_filesystem_app(
                    destination,
                    published_app_identity,
                )
            except InstallerError as identity_error:
                raise PreservedInstallStateError(
                    "The destination changed during final validation. Nothing was "
                    f"moved or deleted; inspect the preserved state:\n"
                    f"  backup: {backup}\n  staging: {stage_root}"
                    f"\n  destination: {destination}"
                ) from identity_error
            try:
                self.rename(destination, failed_app)
                if old_app_moved:
                    self.rename(backup, destination)
            except OSError as rollback_error:
                raise PreservedInstallStateError(
                    "The installed app failed validation and rollback did not "
                    f"complete. Recovery state was preserved:\n  backup: {backup}"
                    f"\n  staging: {stage_root}\n  destination: {destination}"
                ) from rollback_error
            if isinstance(validation_error, KeyboardInterrupt):
                raise
            raise InstallerError(
                "The installed app failed final validation; the previous app was "
                "restored."
                if old_app_moved
                else "The installed app failed final validation and was removed."
            ) from validation_error

        try:
            self._require_expected_filesystem_app(
                destination,
                published_app_identity,
            )
        except InstallerError as identity_error:
            raise PreservedInstallStateError(
                "The destination changed after final validation. The previous app "
                f"was not deleted; inspect the preserved state:\n  backup: {backup}"
                f"\n  staging: {stage_root}\n  destination: {destination}"
            ) from identity_error

        if old_app_moved:
            try:
                self._require_expected_filesystem_app(
                    backup,
                    expected_destination_identity,
                )
            except InstallerError as identity_error:
                raise PreservedInstallStateError(
                    f"The new app is installed and valid, but the backup changed "
                    f"before cleanup. Recovery state was preserved:\n  backup: {backup}"
                    f"\n  staging: {stage_root}"
                ) from identity_error
            try:
                self.rename(backup, previous_app)
            except (OSError, KeyboardInterrupt) as error:
                raise PreservedInstallStateError(
                    f"The new app is installed and valid, but the previous app "
                    f"remains at {backup}. Staging was preserved at {stage_root}."
                ) from error
            try:
                self._require_expected_filesystem_app(
                    previous_app,
                    expected_destination_identity,
                )
            except InstallerError as identity_error:
                raise PreservedInstallStateError(
                    "The backup changed while moving into cleanup staging. Nothing "
                    f"was deleted; inspect the preserved state at {stage_root}."
                ) from identity_error

    @staticmethod
    def _remove_stage_root(stage_root: Path) -> None:
        if _path_exists(stage_root):
            shutil.rmtree(stage_root)


def parse_arguments(arguments: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build CodexReviewMonitor from the current checkout and install it "
            "for local use."
        )
    )
    parser.add_argument(
        "--destination",
        type=Path,
        help=(
            f"app path to replace (default: ~/Applications/{APP_BUNDLE_NAME})"
        ),
    )
    parser.add_argument(
        "--signing-identity",
        default="-",
        metavar="IDENTITY",
        help=(
            "codesign identity permitted by the local environment "
            "(default: '-' for ad-hoc signing)"
        ),
    )
    parser.add_argument(
        "--launch",
        action="store_true",
        help="launch the installed app after validation",
    )
    return parser.parse_args(arguments)


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parsed = parse_arguments(arguments)
    if not parsed.signing_identity:
        print("error: --signing-identity must not be empty", file=sys.stderr)
        return 2

    repo_root = Path(__file__).resolve().parent.parent
    try:
        destination = select_destination(parsed.destination)
        configuration = InstallerConfiguration(
            repo_root=repo_root,
            destination=destination,
            signing_identity=parsed.signing_identity,
            launch=parsed.launch,
        )
        ReviewMonitorInstaller(configuration).install()
    except InstallerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: filesystem operation failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: installation interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
