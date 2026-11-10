#!/usr/bin/env python3
"""Test production identity storage and real TLS without touching login Keychain.

Uses memory-only keys and an isolated temporary keychain (never made default).
No installed app, host identity, pairing, clipboard or app settings are accessed.
"""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / '.build' / 'keychain-tls-tests'
sources = build / 'Sources' / 'SodutoIdentity'
tests = build / 'Tests' / 'KeychainTLSTests'
sources.mkdir(parents=True, exist_ok=True)
tests.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'Tests/KeychainTLS/Package.swift', build / 'Package.swift')
for source in ['Soduto/Core/CertificateUtils.swift', 'Soduto/Core/Network/KeychainTLSIdentity.swift',
               'Soduto/Core/Utils/Logger+Categories.swift', 'Soduto/Core/UploadTask.swift',
               'Soduto/Core/PayloadPortRegistry.swift', 'Soduto/Core/Network/TLSTrustHandler.swift',
               'Soduto/Core/Network/ChannelOptions+Keepalive.swift']:
    shutil.copy2(root / source, sources / Path(source).name)
# Only the diagnostics sink and the packet are stubbed; Security, crypto, NIO and TLS are real.
(sources / 'Diagnostics.swift').write_text('''
enum Diagnostics {
    enum Level { case debug, info, warning, error }
    static func record(_ event: String, level: Level? = nil, fields: [String: String] = [:]) {}
    static func errorFields(_ error: Error) -> [String: String] { [:] }
}
''')
(sources / 'DataPacket.swift').write_text('''
import Foundation
public struct DataPacket {
    public typealias PayloadInfo = Dictionary<String, AnyObject>
    var payload: InputStream?
    var payloadSize: Int64?
    public init(payload: InputStream?, payloadSize: Int64?) {
        self.payload = payload
        self.payloadSize = payloadSize
    }
    public func hasPayload() -> Bool { payload != nil }
}
''')
for source in (root / 'Tests/KeychainTLS').glob('*Tests.swift'):
    shutil.copy2(source, tests / source.name)
subprocess.run(['swift', 'test', '--package-path', str(build)], cwd=root, check=True)
