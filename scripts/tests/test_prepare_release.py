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
        self.tag = {"ref": f"refs/tags/{self.version}", "object": {"type": "commit", "sha": self.sha}}
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

        def run(arguments, **kwargs):
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
            "id": 42, "body": "Approved release notes", "name": "Release title",
            "tag_name": self.version, "draft": True, "prerelease": True,
            "target_commitish": self.sha, "html_url": "https://example.invalid/draft",
            "assets": [{"name": name, "state": "uploaded", "digest": f"sha256:{value}"} for name, value in self.hashes.items()],
        }
        return {**result, **changes}

    def create(self):
        return release.publish_draft(self.directory, self.version, self.sha, self.dmg_hash, 42, True)

    def test_success_uploads_and_publishes_without_replacing_notes(self):
        draft = self.created_draft(assets=[])
        uploaded = self.created_draft(body="Notes edited while CI ran")
        published = {**uploaded, "draft": False}
        with mock.patch.object(release, "api", side_effect=[draft, [self.tag], uploaded, [self.tag], {
            "object": {"type": "commit", "sha": self.sha}
        }]), mock.patch.object(release, "patch_release", return_value=published) as patch:
            self.assertEqual(self.create(), "https://example.invalid/draft")
        commands = [args for args in self.calls if args[0] == "gh"]
        self.assertEqual(len(commands), 3)
        self.assertTrue(all(command[:4] == ["gh", "release", "upload", self.version] for command in commands))
        self.assertTrue(all("--clobber" not in command for command in commands))
        patch.assert_called_once_with(self.repository, 42, {
            "tag_name": self.version, "target_commitish": self.sha,
            "prerelease": True, "draft": False,
        })

    def test_unrecognized_remote_assets_prevent_publication(self):
        complete = self.created_draft()
        extra = {"name": "old-installer.dmg", "state": "uploaded", "digest": "sha256:" + "f" * 64}
        for initially_present in (True, False):
            with self.subTest(initially_present=initially_present):
                with_extra = self.created_draft(assets=[*complete["assets"], extra])
                initial = with_extra if initially_present else self.created_draft(assets=[])
                with mock.patch.object(release, "api", side_effect=[initial, [self.tag], with_extra]), \
                        mock.patch.object(release, "patch_release") as patch:
                    with self.assertRaisesRegex(release.ReleaseError, "asset set"):
                        self.create()
                    patch.assert_not_called()

    def test_publication_reasserts_fields_changed_after_final_read(self):
        complete = self.created_draft()
        remote = {**complete, "tag_name": "v9.9.9", "target_commitish": "b" * 40,
                  "prerelease": False, "body": "Updated notes", "name": "Updated title"}

        def publish(repository, release_id, fields):
            self.assertEqual((repository, release_id), (self.repository, 42))
            remote.update(fields)
            return remote

        def read_tag():
            self.assertEqual(remote["target_commitish"], self.sha)
            return {"object": {"type": "commit", "sha": remote["target_commitish"]}}

        responses = iter([complete, [self.tag], complete, [self.tag], read_tag])

        def api(*args, **kwargs):
            response = next(responses)
            return response() if callable(response) else response

        with mock.patch.object(release, "api", side_effect=api), \
                mock.patch.object(release, "patch_release", side_effect=publish):
            self.create()
        self.assertEqual(remote["tag_name"], self.version)
        self.assertTrue(remote["prerelease"])
        self.assertFalse(remote["draft"])
        self.assertEqual(remote["body"], "Updated notes")
        self.assertEqual(remote["name"], "Updated title")

    def test_partial_upload_retry_only_uploads_missing_files(self):
        complete = self.created_draft()
        partial = self.created_draft(assets=complete["assets"][:1])
        with mock.patch.object(release, "api", side_effect=[partial, [self.tag], complete, [self.tag], {
            "object": {"type": "commit", "sha": self.sha}
        }]), mock.patch.object(release, "patch_release", return_value={**complete, "draft": False}):
            self.create()
        uploads = [args for args in self.calls if args[:3] == ["gh", "release", "upload"]]
        self.assertEqual(len(uploads), 2)
        self.assertNotIn(str(self.directory / self.dmg_name), [args[4] for args in uploads])

    def test_upload_failure_leaves_draft_unpublished(self):
        def fail_upload(arguments, **kwargs):
            if arguments[0] == "git":
                return self.sha
            raise release.ReleaseError("Upload failed")
        with mock.patch.object(release, "api", side_effect=[self.created_draft(assets=[]), [self.tag]]), \
                mock.patch.object(release, "run", side_effect=fail_upload), \
                mock.patch.object(release, "patch_release") as patch:
            with self.assertRaisesRegex(release.ReleaseError, "Upload failed"):
                self.create()
        patch.assert_not_called()

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

    def test_prepare_finds_draft_on_later_page_without_replacing_notes(self):
        draft = self.created_draft()
        with mock.patch.object(release, "api", side_effect=[[ [{"tag_name": "v0.1.0"}], [draft] ], [self.tag]]):
            self.assertEqual(release.prepare_draft(self.version, self.sha), draft)
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_prepare_pins_main_without_editing_user_notes(self):
        draft = self.created_draft(target_commitish="main")
        with mock.patch.object(release, "api", side_effect=[[[draft]], [self.tag]]), \
                mock.patch.object(release, "patch_release", return_value=self.created_draft()) as patch:
            release.prepare_draft(self.version, self.sha)
        patch.assert_called_once_with(self.repository, 42, {"target_commitish": self.sha})

    def test_prepare_creates_tag_before_checks(self):
        draft = self.created_draft()
        with mock.patch.object(release, "api", side_effect=[[[draft]], [], [self.tag]]):
            release.prepare_draft(self.version, self.sha)
        command = self.calls[-1]
        self.assertEqual(command[:4], ["gh", "api", "--method", "POST"])
        self.assertEqual(command[4], f"repos/{self.repository}/git/refs")

    def test_prepare_reuses_annotated_tag_and_rejects_conflict(self):
        annotated = {**self.tag, "object": {"type": "tag", "sha": "c" * 40}}
        for tag, target in ((annotated, self.sha), (self.tag, "b" * 40)):
            with self.subTest(target=target):
                responses = [[[self.created_draft(target_commitish="main" if target != self.sha else self.sha)]], [tag]]
                if tag is annotated:
                    responses.append({"object": {"type": "commit", "sha": target}})
                    with mock.patch.object(release, "api", side_effect=responses):
                        release.prepare_draft(self.version, self.sha)
                else:
                    responses[1] = [{**tag, "object": {"type": "commit", "sha": target}}]
                    with mock.patch.object(release, "api", side_effect=responses), mock.patch.object(release, "patch_release") as update:
                        with self.assertRaisesRegex(release.ReleaseError, "differs"):
                            release.prepare_draft(self.version, self.sha)
                        update.assert_not_called()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_missing_or_moved_tag_prevents_upload_and_publication(self):
        draft = self.created_draft()
        for tag in ([], [{**self.tag, "object": {"type": "commit", "sha": "b" * 40}}]):
            with self.subTest(tag=tag), mock.patch.object(release, "patch_release") as patch:
                with mock.patch.object(release, "api", side_effect=[draft, tag]):
                    with self.assertRaisesRegex(release.ReleaseError, "missing or differs"):
                        self.create()
                with mock.patch.object(release, "api", side_effect=[draft, [self.tag], draft, tag]):
                    with self.assertRaisesRegex(release.ReleaseError, "missing or differs"):
                        self.create()
                patch.assert_not_called()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_prepare_rejects_missing_notes_published_release_and_different_commit(self):
        for changes in ({"body": " "}, {"draft": False}, {"target_commitish": "b" * 40}):
            with self.subTest(changes=changes):
                with mock.patch.object(release, "api", return_value=[[self.created_draft(**changes)]]), \
                        mock.patch.object(release, "patch_release") as patch:
                    with self.assertRaises(release.ReleaseError):
                        release.prepare_draft(self.version, self.sha)
                    patch.assert_not_called()

    def test_changed_draft_identity_is_rejected_before_upload(self):
        for changes in ({"draft": False, "assets": []}, {"target_commitish": "main"}, {"tag_name": "v9.9.9"}, {"prerelease": False}):
            with self.subTest(changes=changes):
                with mock.patch.object(release, "api", return_value=self.created_draft(**changes)):
                    with self.assertRaises(release.ReleaseError):
                        self.create()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_remote_changes_during_upload_prevent_publication(self):
        initial = self.created_draft(assets=[])
        for changes in ({"target_commitish": "b" * 40}, {"prerelease": False}, {"body": ""}, {"assets": []}):
            with self.subTest(changes=changes):
                with mock.patch.object(release, "api", side_effect=[initial, [self.tag], self.created_draft(**changes)]), \
                        mock.patch.object(release, "patch_release") as patch:
                    with self.assertRaises(release.ReleaseError):
                        self.create()
                    patch.assert_not_called()

    def test_uploaded_asset_digest_is_verified(self):
        draft = self.created_draft()
        draft["assets"][0]["digest"] = "sha256:" + "0" * 64
        with mock.patch.object(release, "api", side_effect=[draft, [self.tag]]), \
                mock.patch.object(release, "patch_release") as patch:
            with self.assertRaisesRegex(release.ReleaseError, "upload/digest mismatch"):
                self.create()
            patch.assert_not_called()

    def test_published_tag_is_verified(self):
        draft = self.created_draft()
        with mock.patch.object(release, "api", side_effect=[draft, [self.tag], draft, [self.tag], {
            "object": {"type": "commit", "sha": "b" * 40}
        }]), mock.patch.object(release, "patch_release", return_value={**draft, "draft": False}):
            with self.assertRaisesRegex(release.ReleaseError, "published tag"):
                self.create()

    def test_retry_after_publication_only_confirms_existing_release(self):
        published = self.created_draft(draft=False)
        commit = {"object": {"type": "commit", "sha": self.sha}}
        for tag_responses in ([commit], [{"object": {"type": "tag", "sha": "c" * 40}}, commit]):
            with self.subTest(tag_responses=tag_responses):
                with mock.patch.object(release, "api", side_effect=[published, *tag_responses]), \
                        mock.patch.object(release, "patch_release") as patch:
                    self.assertEqual(self.create(), published["html_url"])
                patch.assert_not_called()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_start_creates_tag_before_dispatch_and_reuses_matching_draft(self):
        notes = self.directory / "notes.md"
        notes.write_text("Approved release notes\n")
        for existing in (False, True):
            self.calls.clear()
            responses = [{"object": {"sha": self.sha}}, [[self.created_draft(assets=[])]] if existing else [[]]]
            responses += [[self.tag]] if existing else [[], [], [self.tag]]
            with mock.patch.object(release, "api", side_effect=responses):
                result = release.start_release(self.repository, self.version, notes, True)
            self.assertIn("No local wait", result)
            dispatch = self.calls[-1]
            self.assertEqual(dispatch, ["gh", "workflow", "run", "release.yml", "--repo", self.repository,
                                       "--ref", "main", "-f", f"version={self.version}"])
            if existing:
                self.assertEqual(len(self.calls), 1)
            else:
                create, tag, _ = self.calls
                self.assertEqual(create[:4], ["gh", "release", "create", self.version])
                self.assertIn("--draft", create)
                self.assertEqual(create[create.index("--notes-file") + 1], str(notes))
                self.assertEqual(create[create.index("--target") + 1], self.sha)
                self.assertEqual(tag[:4], ["gh", "api", "--method", "POST"])

    def test_dispatch_failure_reports_retained_draft_and_tag(self):
        notes = self.directory / "notes.md"
        notes.write_text("Approved release notes")
        with mock.patch.object(release, "api", side_effect=[{"object": {"sha": self.sha}}, [[self.created_draft(assets=[])]], [self.tag]]), \
                mock.patch.object(release, "run", side_effect=release.ReleaseError("Offline")):
            with self.assertRaisesRegex(release.ReleaseError, "Tag .* and draft saved.*dispatch was not confirmed"):
                release.start_release(self.repository, self.version, notes, True)

    def test_start_rejects_changed_approval_without_mutation(self):
        notes = self.directory / "notes.md"
        notes.write_text("Approved release notes")
        for changes in ({"body": "Other notes"}, {"prerelease": False}, {"draft": False}, {"target_commitish": "b" * 40}, {"assets": [{"name": "previous.dmg"}]}):
            with self.subTest(changes=changes), mock.patch.object(release, "api", side_effect=[
                {"object": {"sha": self.sha}}, [[self.created_draft(**changes)]]
            ]):
                with self.assertRaises(release.ReleaseError):
                    release.start_release(self.repository, self.version, notes, True)
        self.assertFalse(self.calls)

    def test_github_failure_does_not_trigger_recovery_mutations(self):
        with mock.patch.object(release, "api", side_effect=release.ReleaseError("GitHub unavailable")):
            with self.assertRaisesRegex(release.ReleaseError, "GitHub unavailable"):
                self.create()
        self.assertFalse(any(args[0] == "gh" for args in self.calls))


if __name__ == "__main__":
    unittest.main()
