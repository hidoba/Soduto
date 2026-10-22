#!/usr/bin/env python3
"""Reproduce legacy Keychain export prompts with a synthetic temporary key.

The optional --prove-old-prompt control starts the old high-level signing API,
expects it to block on export approval, samples it, and terminates it. No password
is entered. The fixed path must sign/verify 600 challenges without a dialog.
Only the temporary keychain created by this script is accessed or deleted.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--prove-old-prompt', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = root / '.build' / 'keychain-legacy'
build.mkdir(parents=True, exist_ok=True)
production = (root / 'Soduto/Core/Network/KeychainTLSIdentity.swift').read_text()
encoder = production[production.index('enum KeychainRSASignature {'):]
source = (root / 'Tests/KeychainLegacy/main.swift').read_text() + '\n' + encoder
source_file = build / 'main.swift'
source_file.write_text(source)
executable = build / 'SodutoKeychainRegression'
subprocess.run(['swiftc', str(source_file), '-o', str(executable)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'com.hidoba.Soduto.KeychainRegression', str(executable)], check=True)
with tempfile.TemporaryDirectory(prefix='soduto-legacy-regression-') as temporary:
    subprocess.run([str(executable), 'create', temporary], check=True)
    try:
        if args.prove_old_prompt:
            control = subprocess.Popen([str(executable), 'old', temporary], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                output, _ = control.communicate(timeout=3)
                raise RuntimeError('The old-path control did not block; UI reproduction is inconclusive: ' + output)
            except subprocess.TimeoutExpired:
                subprocess.run(['sample', str(control.pid), '1', '1', '-file', str(build / 'old-path-sample.txt')], check=True)
                trace = (build / 'old-path-sample.txt').read_text()
                if 'SecCDSAKeyCopyExternalRepresentation' not in trace:
                    raise RuntimeError('Control blocked outside the legacy export path')
                print('PASS: old high-level signing reproduced the legacy export-approval block', flush=True)
            finally:
                if control.poll() is None:
                    control.kill()
                control.communicate()
        fixed = subprocess.Popen([str(executable), 'raw', temporary], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            output, _ = fixed.communicate(timeout=60)
            print(output, end='', flush=True)
            if fixed.returncode:
                raise RuntimeError('Fixed signing failed')
        except subprocess.TimeoutExpired:
            subprocess.run(['sample', str(fixed.pid), '1', '1', '-file', str(build / 'raw-path-sample.txt')], check=True)
            raise RuntimeError('Fixed signing blocked; captured stack')
        finally:
            if fixed.poll() is None:
                fixed.kill()
            fixed.communicate()
    finally:
        subprocess.run([str(executable), 'delete', temporary], check=True, timeout=10)
