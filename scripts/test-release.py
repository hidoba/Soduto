#!/usr/bin/env python3
"""Exercise publication failures without contacting GitHub or publishing anything."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {'GITHUB_REPOSITORY': 'hidoba/Soduto',
            'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123',
            'GITHUB_REF': 'refs/heads/codex/reliability-diagnostics',
            'GITHUB_STEP_SUMMARY': str(self.root / 'summary.md')})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.app = self.root / 'Soduto.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.info = self.app / 'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '3.2.1',
            'CFBundleVersion': '37', 'SodutoSourceRevision': 'a' * 40,
            'SodutoPackagingRevision': 'a' * 40}))
        self.archive = self.root / 'Soduto-development.zip'
        self.archive.write_bytes(b'original packaged and signed bytes')
        self.archive.with_suffix('.zip.sha256').write_text(f'{release.digest(self.archive)}  {self.archive.name}\n')
        self.notes = self.root / 'notes.md'
        self.notes.write_text('# Test release\n')
        self.output = self.root / 'release'

    def prepare(self):
        release.prepare(self.app, self.archive, self.notes, self.output)
        (self.output / release.BUNDLE).write_text('mock bundle; subprocess verification is mocked')

    def test_preparation_preserves_exact_bytes_and_records_source(self):
        self.prepare()
        manifest = json.loads((self.output / 'build-info.json').read_text())
        self.assertEqual((self.output / manifest['archive']['name']).read_bytes(), self.archive.read_bytes())
        self.assertEqual(manifest['source_commit'], 'a' * 40)
        self.assertEqual(manifest['tag'], 'v3.2.1-37')
        self.assertIn('--source-digest ' + 'a' * 40, (self.output / 'release-notes.md').read_text())

    def test_wrong_binary_source_is_rejected(self):
        info = plistlib.loads(self.info.read_bytes())
        info['SodutoSourceRevision'] = 'b' * 40
        self.info.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'revisions'):
            release.prepare(self.app, self.archive, self.notes, self.output)
        self.assertFalse(self.output.exists())

    def test_changed_archive_prevents_any_publication(self):
        self.prepare()
        (self.output / 'Soduto-3.2.1-37-macos-universal.zip').write_bytes(b'replaced after build')
        with patch.object(release.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'changed'):
                release.publish(self.output)
            run.assert_not_called()

    def test_bad_attestation_prevents_creating_tag_or_release(self):
        self.prepare()
        with patch.object(release.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'verify')) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish(self.output)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:3], ['gh', 'attestation', 'verify'])

    def test_existing_tag_prevents_replacing_release(self):
        self.prepare()
        with patch.object(release.subprocess, 'run', side_effect=[None, None, subprocess.CalledProcessError(1, 'existing tag')]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish(self.output)
            self.assertEqual(run.call_count, 3)
            self.assertFalse(any(call.args[0][1:3] == ['release', 'create'] for call in run.call_args_list))

    def test_publication_verifies_source_before_creating_exact_tag(self):
        self.prepare()
        with patch.object(release.subprocess, 'run') as run:
            release.publish(self.output)
            commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 4)
        for verify in commands[:2]:
            self.assertIn('--source-digest', verify)
            self.assertIn('a' * 40, verify)
            self.assertIn('--deny-self-hosted-runners', verify)
        self.assertIn('sha=' + 'a' * 40, commands[2])
        self.assertIn('ref=refs/tags/v3.2.1-37', commands[2])
        self.assertIn('--verify-tag', commands[3])
        self.assertNotIn('--clobber', commands[3])
        self.assertIn(str(self.output / release.BUNDLE), commands[3])
        self.assertIn('Published release', (self.root / 'summary.md').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
