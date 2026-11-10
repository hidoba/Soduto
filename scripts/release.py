#!/usr/bin/env python3
"""Prepare unchanged CI bytes, then verify provenance before creating a release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

WORKFLOW = '.github/workflows/build.yml'
BUNDLE = 'release-attestation.sigstore.json'


def context():
    repo, sha, run = (os.environ[key] for key in
                      ('GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID'))
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repo) or not re.fullmatch(r'[a-f0-9]{40}', sha) or not run.isdigit():
        raise ValueError('Invalid GitHub build context')
    return {'repository': repo, 'source_commit': sha, 'source_ref': os.environ['GITHUB_REF'],
            'run_id': run, 'run_url': f'https://github.com/{repo}/actions/runs/{run}',
            'workflow': WORKFLOW}


def identity(version, build):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('Release version and build number must be resolved bundle values')
    return f'v{version}-{build}', f'Soduto-{version}-{build}-macos-universal.zip'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(app, archive, notes, output):
    ctx = context()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(info.get(key) != ctx['source_commit'] for key in ('SodutoSourceRevision', 'SodutoPackagingRevision')):
        raise ValueError('Built app and packaging revisions must match this workflow commit')
    version, build = str(info['CFBundleShortVersionString']), str(info['CFBundleVersion'])
    tag, filename = identity(version, build)
    checksum = digest(archive)
    if archive.with_suffix(archive.suffix + '.sha256').read_text().split() != [checksum, archive.name]:
        raise ValueError('Packaged ZIP checksum does not match')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(archive, output / filename)
    (output / (filename + '.sha256')).write_text(f'{checksum}  {filename}\n')
    manifest = {**ctx, 'version': version, 'build': build, 'tag': tag,
                'archive': {'name': filename, 'sha256': checksum, 'size': archive.stat().st_size}}
    (output / 'build-info.json').write_text(json.dumps(manifest, indent=2) + '\n')
    repo, sha = ctx['repository'], ctx['source_commit']
    verification = f'''

## Build verification

Built, tested, and published by GitHub Actions. The release ZIP is the unchanged, attested build output.

- [Source commit `{sha[:7]}`](https://github.com/{repo}/commit/{sha})
- [Build, tests, and publication]({ctx['run_url']})
- [Workflow source](https://github.com/{repo}/blob/{sha}/{WORKFLOW})
- [Verification instructions](https://github.com/{repo}/blob/{sha}/docs/release-verification.md)

ZIP SHA-256: `{checksum}`

```sh
gh attestation verify {filename} --repo {repo} \\
  --signer-workflow {repo}/{WORKFLOW} \\
  --source-digest {sha} --deny-self-hosted-runners
```

The checksum, build manifest, and signed attestation bundle are attached to this release.
'''
    (output / 'release-notes.md').write_text(notes.read_text().rstrip() + verification)
    print(f'Prepared {tag}: {filename} (SHA-256 {checksum})')


def publish(directory):
    ctx = context()
    manifest = json.loads((directory / 'build-info.json').read_text())
    if any(manifest.get(key) != value for key, value in ctx.items()):
        raise ValueError('Release manifest belongs to a different workflow run or source commit')
    tag, filename = identity(manifest['version'], manifest['build'])
    archive = directory / filename
    checksum = digest(archive)
    if manifest['tag'] != tag or manifest['archive'] != {
            'name': filename, 'sha256': checksum, 'size': archive.stat().st_size}:
        raise ValueError('Release ZIP or metadata changed after packaging')
    sidecar = directory / (filename + '.sha256')
    if sidecar.read_text().split() != [checksum, filename]:
        raise ValueError('Release checksum sidecar does not match')
    bundle = directory / BUNDLE
    for subject in (archive, directory / 'build-info.json'):
        subprocess.run(['gh', 'attestation', 'verify', str(subject), '--repo', ctx['repository'],
                        '--bundle', str(bundle), '--signer-workflow', f"{ctx['repository']}/{WORKFLOW}",
                        '--source-digest', ctx['source_commit'], '--source-ref', ctx['source_ref'],
                        '--deny-self-hosted-runners'], check=True)
    # Atomically create a new tag at the built commit. Existing tags are never moved.
    # A duplicate tag fails before publication, rather than replacing an older release.
    subprocess.run(['gh', 'api', '--method', 'POST', f"repos/{ctx['repository']}/git/refs",
                    '-f', f'ref=refs/tags/{tag}', '-f', f"sha={ctx['source_commit']}"], check=True)
    subprocess.run(['gh', 'release', 'create', tag, '--repo', ctx['repository'], '--verify-tag',
                    '--title', f"Soduto {manifest['version']} ({manifest['build']})",
                    '--notes-file', str(directory / 'release-notes.md'), '--latest',
                    str(archive), str(sidecar), str(directory / 'build-info.json'), str(bundle)], check=True)
    url = f"https://github.com/{ctx['repository']}/releases/tag/{tag}"
    summary = f'## Published release\n\n[{tag}]({url})\n\nBuilt from `{ctx["source_commit"]}`. Both test jobs passed; ZIP and manifest attestations verified before publication.\n'
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(summary)
    print(summary)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    for flag in ('app', 'archive', 'notes', 'output'):
        prep.add_argument('--' + flag, type=Path, required=True)
    commands.add_parser('publish').add_argument('--directory', type=Path, required=True)
    args = vars(parser.parse_args())
    command = args.pop('command')
    (prepare if command == 'prepare' else publish)(**args)
