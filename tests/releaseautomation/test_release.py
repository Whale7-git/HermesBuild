import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

planner = module('release_plan', 'release-plan.py')
pub = module('publish_release', 'publish-release.py')
SHA = 'a' * 40
RUN = '123'
TAG = 'release-2.27.0-build167'


class FakeGitHub:
    def __init__(self):
        self.release = None
        self.tag = None
        self.bytes = {}
        self.writes = []
        self.corrupt = False
        self.fail_upload = False
        self.partial_upload = False
        self.downloads = 0

    def api(self, path, method='GET', data=None, missing=False):
        if method == 'POST':
            self.writes.append('create-draft')
            self.release = dict(data, id=1, assets=[], html_url='https://github.com/Whale7-git/HermesBuild/releases/tag/' + TAG)
        elif method == 'PATCH':
            self.writes.append('publish')
            self.release.update(data)
            self.tag = {'object': {'type': 'commit', 'sha': SHA}}
        elif path.startswith('git/ref/'):
            return copy.deepcopy(self.tag)
        return copy.deepcopy(self.release)

    def upload(self, tag, paths):
        self.writes.append('upload')
        if self.fail_upload:
            raise RuntimeError('simulated interrupted upload')
        for p in paths:
            i = max(self.bytes, default=-1) + 1
            self.bytes[i] = p.read_bytes()
            self.release['assets'].append(dict(id=i, name=p.name, size=p.stat().st_size))
            if self.partial_upload:
                raise RuntimeError('simulated partial upload')

    def download(self, asset, dest):
        self.downloads += 1
        dest.write_bytes(b'corrupt' if self.corrupt else self.bytes[asset['id']])


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.old = dict(version='2.26.0', build='166')
        self.new = dict(version='2.27.0', build='167')

    def test_new_main_identity_releases(self):
        self.assertEqual(planner.plan(self.new, self.old, 'push', 'refs/heads/main')['release'], 'true')

    def test_maintenance_and_note_changes_do_not_release(self):
        same = dict(self.old, _note='updated documentation')
        self.assertEqual(planner.plan(same, self.old, 'push', 'refs/heads/main')['release'], 'false')

    def test_build_only_increment_is_supported(self):
        self.assertEqual(planner.plan(dict(version='2.26.0', build='167'), self.old, 'push', 'refs/heads/main')['release'], 'true')

    def test_pull_request_manual_and_other_branch_never_publish(self):
        for event, ref in [('pull_request', 'refs/pull/2/merge'), ('workflow_dispatch', 'refs/heads/main'), ('push', 'refs/heads/topic')]:
            self.assertEqual(planner.plan(self.new, None, event, ref)['release'], 'false')

    def test_missing_base_rollback_and_output_injection_fail_closed(self):
        for current, old in [(self.new, None), (dict(version='2.25.0', build='167'), self.old),
                             (dict(version='2.27.0', build='166'), self.old),
                             (dict(version='2.27.0\nrelease=true', build='167'), self.old)]:
            with self.assertRaises(ValueError):
                planner.plan(current, old, 'push', 'refs/heads/main')

    def test_context_requires_exact_repository_event_ref(self):
        valid = dict(GITHUB_REPOSITORY='Whale7-git/HermesBuild', GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/main', GITHUB_SHA=SHA, GITHUB_RUN_ID=RUN)
        self.assertEqual(pub.context(valid), (SHA, RUN))
        for key, value in [('GITHUB_REPOSITORY', 'someone/fork'), ('GITHUB_EVENT_NAME', 'workflow_dispatch'), ('GITHUB_REF', 'refs/heads/topic'), ('GITHUB_SHA', 'main')]:
            with self.assertRaises(ValueError):
                pub.context(dict(valid, **{key: value}))


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'release.json').write_text(json.dumps(dict(version='2.27.0', build='167')))
        d = self.root / 'release'; d.mkdir()
        name = 'Hermes-2.27.0-build167-unsigned.ipa'
        (d / name).write_bytes(b'synthetic-package-for-manifest-tests')
        (d / 'build-info.json').write_text(json.dumps(dict(version='2.27.0', build='167', working_tree='clean', head_commit=SHA, source_head_commit=SHA)))
        (d / 'validation.json').write_text(json.dumps(dict(ipa=name, version='2.27.0', build='167', bundle='com.whale7.hermes', arch='arm64', unsigned=True, sha256=pub.digest(d / name))))
        self.paths = {p.name: p for p in d.iterdir()}
        self.write_checksums()
        self.paths['SHA256SUMS.txt'] = d / 'SHA256SUMS.txt'

    def write_checksums(self):
        (self.root / 'release/SHA256SUMS.txt').write_text(''.join(f'{pub.digest(p)}  {p.name}\n' for p in sorted(self.paths.values()) if p.name != 'SHA256SUMS.txt'))

    def test_manifest_and_exact_provenance_pass_to_independent_package_inspector(self):
        with patch.object(pub.subprocess, 'run') as inspect:
            version, build, tag, paths = pub.validate_bundle(self.root, SHA)
        self.assertEqual((version, build, tag), ('2.27.0', '167', TAG))
        self.assertEqual(len(paths), 4)
        self.assertIn('verify_ipa.py', str(inspect.call_args.args[0]))
        self.assertTrue(inspect.call_args.kwargs['check'])

    def test_corrupt_or_incomplete_assets_rejected(self):
        self.paths['build-info.json'].write_text('{}')
        with self.assertRaises(ValueError): pub.validate_bundle(self.root, SHA)

    def test_rehashed_foreign_provenance_is_rejected(self):
        p = self.paths['build-info.json']; info = json.loads(p.read_text()); info['source_head_commit'] = 'b' * 40; p.write_text(json.dumps(info)); self.write_checksums()
        with self.assertRaises(ValueError): pub.validate_bundle(self.root, SHA)

    def test_manifest_traversal_is_rejected(self):
        self.paths['SHA256SUMS.txt'].write_text('0' * 64 + '  ../outside.ipa\n')
        with self.assertRaises(ValueError): pub.validate_bundle(self.root, SHA)

    def test_publish_verifies_all_assets_before_and_after_publication(self):
        client = FakeGitHub()
        url = pub.publish(client, TAG, SHA, RUN, self.paths)
        self.assertTrue(url.endswith(TAG))
        self.assertEqual(client.writes, ['create-draft', 'upload', 'publish'])
        self.assertEqual(client.downloads, 8)
        self.assertFalse(client.release['draft'])

    def test_upload_failure_leaves_draft_unpublished(self):
        client = FakeGitHub(); client.fail_upload = True
        with self.assertRaises(RuntimeError): pub.publish(client, TAG, SHA, RUN, self.paths)
        self.assertTrue(client.release['draft'])
        self.assertNotIn('publish', client.writes)

    def test_remote_hash_corruption_prevents_publication(self):
        client = FakeGitHub(); client.corrupt = True
        with self.assertRaises(ValueError): pub.publish(client, TAG, SHA, RUN, self.paths)
        self.assertTrue(client.release['draft'])
        self.assertNotIn('publish', client.writes)

    def test_owned_draft_resumes_but_published_or_foreign_release_is_immutable(self):
        client = FakeGitHub(); client.fail_upload = True
        with self.assertRaises(RuntimeError): pub.publish(client, TAG, SHA, RUN, self.paths)
        client.fail_upload = False
        pub.publish(client, TAG, SHA, RUN, self.paths)
        with self.assertRaises(ValueError): pub.publish(client, TAG, SHA, RUN, self.paths)
        client.release['draft'] = True
        with self.assertRaises(ValueError): pub.preflight(client, TAG, SHA, '12')
        client.release['target_commitish'] = 'b' * 40
        with self.assertRaises(ValueError): pub.preflight(client, TAG, SHA, RUN)

    def test_partial_upload_retry_reuses_verified_assets_without_overwriting(self):
        client = FakeGitHub(); client.partial_upload = True
        with self.assertRaises(RuntimeError): pub.publish(client, TAG, SHA, RUN, self.paths)
        existing_id = client.release['assets'][0]['id']
        original = client.bytes[existing_id]
        client.partial_upload = False
        pub.publish(client, TAG, SHA, RUN, self.paths)
        self.assertEqual(client.bytes[existing_id], original)
        self.assertEqual(len(client.release['assets']), 4)
        self.assertEqual(client.writes.count('create-draft'), 1)
        self.assertEqual(client.downloads, 9)

    def test_orphan_tag_is_never_replaced(self):
        client = FakeGitHub(); client.tag = {'object': {'type': 'commit', 'sha': SHA}}
        with self.assertRaises(ValueError): pub.preflight(client, TAG, SHA, RUN)
        self.assertEqual(client.writes, [])

    def test_api_404_is_distinguished_from_authentication_failure(self):
        client = pub.GitHub('Whale7-git/HermesBuild')
        with patch.object(pub.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, 'HTTP/2.0 404 Not Found\n\n{}', '')):
            self.assertIsNone(client.api('git/ref/tags/x', missing=True))
        with patch.object(pub.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, 'HTTP/2.0 403 Forbidden\n\n{}', '')):
            with self.assertRaises(RuntimeError): client.api('git/ref/tags/x', missing=True)


if __name__ == '__main__':
    unittest.main()
