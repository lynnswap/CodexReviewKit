from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_release as release


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.version = "v1.2.3-beta.1"
        self.sha = "a" * 40
        self.repository = "lynnswap/CodexReviewKit"
        self.dmg_name = "CodexReviewMonitor_1.2.3-beta.1.dmg"
        (self.directory / self.dmg_name).write_bytes(b"signed-dmg-fixture")
        self.dmg_hash = release.digest(self.directory / self.dmg_name)
        self.info = {
            "version": self.version,
            "source_sha": self.sha,
            "repository": self.repository,
            "run_id": "123",
            "build_number": "23",
            "run_attempt": "1",
            "developer_id_signed": True,
            "notarized": True,
            "apple_team_id": "TEAM123456",
            "signing_certificate_sha1": "b" * 40,
            "notary_submission_id": "00000000-0000-0000-0000-000000000001",
        }
        self.write_metadata()
        self.environment = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": self.sha,
            "GITHUB_REPOSITORY": self.repository,
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_NUMBER": "23",
            "GITHUB_RUN_ATTEMPT": "2",
        }
        self.environment_patch = mock.patch.dict(os.environ, self.environment, clear=True)
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        self.calls = []

        def run(arguments):
            self.calls.append(arguments)
            if arguments == ["git", "rev-parse", "HEAD"]:
                return self.sha + "\n"
            return "https://example.invalid/draft\n"

        self.run_patch = mock.patch.object(release, "run", side_effect=run)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)

    def write_metadata(self):
        (self.directory / "release-info.json").write_text(json.dumps(self.info))
        self.hashes = {
            self.dmg_name: self.dmg_hash,
            "release-info.json": release.digest(self.directory / "release-info.json"),
        }
        (self.directory / "SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name, value in self.hashes.items()))
        self.hashes["SHA256SUMS"] = release.digest(self.directory / "SHA256SUMS")

    def created_draft(self, **changes):
        result = {
            "tag_name": self.version, "draft": True, "prerelease": True,
            "target_commitish": self.sha, "html_url": "https://example.invalid/draft",
            "assets": [{"name": name, "state": "uploaded", "digest": f"sha256:{value}"} for name, value in self.hashes.items()],
        }
        return {**result, **changes}

    def create(self):
        return release.create_draft(self.directory, self.version, self.sha, self.dmg_hash, True)

    def test_success_creates_only_a_draft_pinned_to_commit(self):
        # A previously successful signing job remains valid when only the draft job is rerun.
        with mock.patch.object(release, "api", side_effect=[[[]], [], [[self.created_draft()]], []]):
            self.assertEqual(self.create(), "https://example.invalid/draft")
        commands = [args for args in self.calls if args[0] == "gh"]
        self.assertEqual(len(commands), 1)
        command = commands[0]
        self.assertEqual(command[:4], ["gh", "release", "create", self.version])
        self.assertIn("--draft", command)
        self.assertEqual(command[command.index("--target") + 1], self.sha)
        self.assertIn("--prerelease=true", command)
        self.assertNotIn("--clobber", command)
        self.assertNotIn("--verify-tag", command)

    def test_non_main_and_checkout_mismatch_are_rejected(self):
        with mock.patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v1.2.3"}):
            with self.assertRaisesRegex(release.ReleaseError, "main branch"):
                self.create()
        with mock.patch.object(release, "run", return_value="c" * 40):
            with self.assertRaisesRegex(release.ReleaseError, "workflow checkout"):
                self.create()

    def test_invalid_version_and_missing_digest_are_rejected(self):
        for value in ("../../v1.2.3", "v1.2.3\n--draft=false", "v01.2.3", "main"):
            with self.assertRaises(release.ReleaseError):
                release.validate_request(value, self.sha)
        with self.assertRaisesRegex(release.ReleaseError, "Missing or malformed digest"):
            release.validate_artifacts(self.directory, self.version, self.sha, self.repository, "")

    def test_tampering_is_rejected_before_any_github_request(self):
        (self.directory / self.dmg_name).write_bytes(b"changed")
        with mock.patch.object(release, "api") as api:
            with self.assertRaisesRegex(release.ReleaseError, "checksum differs"):
                self.create()
            api.assert_not_called()

    def test_metadata_must_match_run_source_and_notarization(self):
        for key, value in (("source_sha", "c" * 40), ("run_id", "another-run"), ("build_number", "22"), ("notarized", False), ("developer_id_signed", 1)):
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_metadata()
                with self.assertRaisesRegex(release.ReleaseError, key):
                    self.create()
                self.info[key] = original

    def test_checksums_reject_extra_or_duplicate_paths(self):
        checksum_file = self.directory / "SHA256SUMS"
        original = checksum_file.read_text()
        for line in (f"{'d' * 64}  ../other\n", original.splitlines()[0] + "\n"):
            checksum_file.write_text(original + line)
            with self.assertRaises(release.ReleaseError):
                self.create()

    def test_symlink_and_unexpected_asset_are_rejected(self):
        extra = self.directory / "private.p12"
        extra.write_bytes(b"must-not-upload")
        with self.assertRaisesRegex(release.ReleaseError, "exact release file set"):
            self.create()
        extra.unlink()
        dmg = self.directory / self.dmg_name
        dmg.unlink()
        dmg.symlink_to("release-info.json")
        with self.assertRaisesRegex(release.ReleaseError, "regular file"):
            self.create()

    def test_existing_draft_on_later_page_is_not_overwritten(self):
        with mock.patch.object(release, "api", return_value=[[{"tag_name": "v0.1.0"}], [self.created_draft()]]):
            with self.assertRaisesRegex(release.ReleaseError, "already exists"):
                self.create()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_existing_tag_is_not_reused(self):
        with mock.patch.object(release, "api", side_effect=[[[]], [{"ref": f"refs/tags/{self.version}"}]]):
            with self.assertRaisesRegex(release.ReleaseError, "Tag .* already exists"):
                self.create()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_created_draft_is_verified(self):
        for changes in ({"draft": False}, {"target_commitish": "main"}, {"assets": []}):
            with self.subTest(changes=changes):
                with mock.patch.object(release, "api", side_effect=[[[]], [], [[self.created_draft(**changes)]]]):
                    with self.assertRaises(release.ReleaseError):
                        self.create()

    def test_uploaded_asset_digest_is_verified(self):
        draft = self.created_draft()
        draft["assets"][0]["digest"] = "sha256:" + "0" * 64
        with mock.patch.object(release, "api", side_effect=[[[]], [], [[draft]]]):
            with self.assertRaisesRegex(release.ReleaseError, "upload/digest mismatch"):
                self.create()

    def test_github_failure_does_not_trigger_recovery_mutations(self):
        with mock.patch.object(release, "api", side_effect=release.ReleaseError("GitHub unavailable")):
            with self.assertRaisesRegex(release.ReleaseError, "GitHub unavailable"):
                self.create()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))


if __name__ == "__main__":
    unittest.main()
