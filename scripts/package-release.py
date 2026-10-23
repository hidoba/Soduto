#!/usr/bin/env python3
"""Seal the complete app for Keychain trust, then package a local development build.

Ad-hoc signing is not Developer ID signing or notarization. It binds Info.plist,
resources and nested code so macOS can resolve the app's static code identity.
No Keychain items or permissions are accessed or modified.
"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--build-number', help='Packaging build number for the verified input binary')
parser.add_argument('--packaging-revision', help='Commit containing this packaging procedure')
args = parser.parse_args()
app = args.app.resolve()
assert app.suffix == '.app' and (app / 'Contents/Info.plist').is_file()
if args.build_number:
    assert args.build_number.isdigit()
    # Own bundles share the release build number; vendor frameworks retain theirs.
    for info in app.rglob('Info.plist'):
        if info.is_symlink():
            continue
        data = plistlib.loads(info.read_bytes())
        if str(data.get('CFBundleIdentifier', '')).startswith('com.hidoba.'):
            data['CFBundleVersion'] = args.build_number
            info.write_bytes(plistlib.dumps(data))
if args.packaging_revision:
    info = app / 'Contents/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['SodutoPackagingRevision'] = args.packaging_revision
    info.write_bytes(plistlib.dumps(data))

bundles = {app}
code = set()
magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
for path in app.rglob('*'):
    if path.is_symlink():
        continue
    if path.is_dir() and path.suffix in {'.app', '.appex', '.xpc', '.framework'}:
        bundles.add(path)
    elif path.is_file():
        with path.open('rb') as file:
            if file.read(4) in magic:
                code.add(path)
# Sign from the inside out. Preserve valid vendor signatures and entitlements.
for path in sorted(bundles | code, key=lambda p: len(p.parts), reverse=True):
    valid = subprocess.run(['codesign', '--verify', '--strict', '--all-architectures', str(path)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not valid:
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
                        '--preserve-metadata=entitlements', str(path)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
args.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(args.output)], check=True)
checksum = hashlib.sha256(args.output.read_bytes()).hexdigest()
args.output.with_suffix(args.output.suffix + '.sha256').write_text(f'{checksum}  {args.output.name}\n')
print(f'PASS: complete bundle signature verified; SHA-256 {checksum}')
