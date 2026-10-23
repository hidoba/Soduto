import Foundation
import Security
import NIOCore
import NIOSSL
import Crypto
import os

/// All control and payload connections use the same Keychain-backed TLS identity.
/// Only the public certificate leaves Keychain; TLS asks Security to sign in place.
enum KeychainTLSIdentity {
    static func configuration(for identity: SecIdentity, server: Bool) throws -> TLSConfiguration {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { throw NIOSSLError.failedToLoadCertificate }
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              let key else { throw NIOSSLError.failedToLoadPrivateKey }

        let certificateData = SecCertificateCopyData(certificate) as Data
        let sslCertificate = try NIOSSLCertificate(bytes: Array(certificateData), format: .der)
        // Reading attributes of an old private key can itself request an export.
        // The certificate's public key supplies the modulus size without accessing it.
        guard let publicKey = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let bitCount = attributes[kSecAttrKeySizeInBits as String] as? Int,
              let keyType = attributes[kSecAttrKeyType as String],
              CFEqual(keyType as CFTypeRef, kSecAttrKeyTypeRSA) else {
            throw NIOSSLError.failedToLoadCertificate
        }
        let sslKey = NIOSSLPrivateKey(customPrivateKey: KeychainTLSPrivateKey(
            key: key, identityID: certificateData, modulusBitCount: bitCount))
        var config = server
            ? TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(sslCertificate)],
                                                       privateKey: .privateKey(sslKey))
            : TLSConfiguration.makeClientConfiguration()
        config.certificateChain = [.certificate(sslCertificate)]
        config.privateKey = .privateKey(sslKey)
        config.certificateVerification = .noHostnameVerification
        config.minimumTLSVersion = .tlsv12
        // Signing-only RSA credentials require ephemeral key exchange in TLS 1.2.
        // TLS 1.3 always uses ephemeral exchange and has its own cipher suite list.
        config.cipherSuites = "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305"
        return config
    }
}

final class KeychainTLSPrivateKey: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    // Keychain can present a dialog. Never block a NIO event loop or the UI thread.
    // Serializing also prevents simultaneous reconnects from presenting many dialogs.
    private static let worker = DispatchQueue(label: "com.hidoba.Soduto.keychain-signing")
    // Accessed only on worker. Denied access stays suspended until an explicit
    // retry. Temporary Keychain errors must remain recoverable after wake/unlock.
    private static var failures: [Data: NSError] = [:]
    private let key: SecKey
    private let identityID: Data
    private let modulusBitCount: Int
    private let signer: @Sendable (SecKeyAlgorithm, Data) throws -> Data

    init(key: SecKey, identityID: Data, modulusBitCount: Int = 2048,
         signer: (@Sendable (SecKeyAlgorithm, Data) throws -> Data)? = nil) {
        self.key = key
        self.identityID = identityID
        self.modulusBitCount = modulusBitCount
        self.signer = signer ?? { _, encoded in
            try KeychainRSASignature.signEncoded(encoded, using: key)
        }
    }

    static func resetAuthorizationFailures() {
        worker.async { failures.removeAll() }
    }

    static func == (lhs: KeychainTLSPrivateKey, rhs: KeychainTLSPrivateKey) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var signatureAlgorithms: [SignatureAlgorithm] {
        [.rsaPssRsaeSha256, .rsaPssRsaeSha384, .rsaPssRsaeSha512,
         .rsaPkcs1Sha256, .rsaPkcs1Sha384, .rsaPkcs1Sha512]
    }

    func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        guard signatureAlgorithms.contains(algorithm) else {
            return channel.eventLoop.makeFailedFuture(NIOSSLError.failedToLoadPrivateKey)
        }
        let message = Data(data.readableBytesView)
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        Self.worker.async { [self] in
            guard channel.isActive else {
                promise.fail(ChannelError.ioOnClosedChannel)
                return
            }
            if let failure = Self.failures[identityID] {
                promise.fail(failure)
                return
            }
            do {
                // High-level RSA/PSS operations call SecKeyCopyAttributes, which
                // tries to export legacy keys on macOS. Encode RFC 8017 padding
                // using public metadata and ask Keychain only for raw RSA signing.
                let encoded = try KeychainRSASignature.encode(message, algorithm: algorithm,
                                                             modulusBitCount: modulusBitCount)
                let signature = try signer(.rsaSignatureRaw, encoded)
                var buffer = ByteBufferAllocator().buffer(capacity: signature.count)
                buffer.writeBytes(signature)
                Diagnostics.record("keychain.signature_completed", fields: ["algorithm": String(algorithm.rawValue)])
                promise.succeed(buffer)
            } catch {
                let failure = error as NSError
                let denied = Self.isAccessDenied(failure)
                if denied { Self.failures[identityID] = failure }
                Diagnostics.record(denied ? "keychain.signing_suspended" : "keychain.signing_failed", level: .error,
                                   fields: ["error_domain": failure.domain, "error_code": String(failure.code)])
                if denied {
                    Logger.config.error("Keychain access denied (\(failure.code)); use Reconnect All Devices to retry access.")
                } else {
                    Logger.config.error("Keychain signing failed (\(failure.code)); a later connection can retry.")
                }
                promise.fail(failure)
            }
        }
        return promise.futureResult
    }

    private static func isAccessDenied(_ error: NSError) -> Bool {
        let deniedCodes = [Int(errSecUserCanceled), Int(errSecAuthFailed), Int(CSSMERR_CSP_OPERATION_AUTH_DENIED)]
        if error.domain == NSOSStatusErrorDomain, deniedCodes.contains(error.code) { return true }
        // Security sometimes wraps a legacy Keychain status in an underlying error.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSOSStatusErrorDomain && deniedCodes.contains(underlying.code)
        }
        return false
    }

    func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        // Static RSA key exchange is disabled in configuration(for:server:).
        channel.eventLoop.makeFailedFuture(NIOSSLError.failedToLoadPrivateKey)
    }
}

/// RFC 8017 EMSA-PSS / EMSA-PKCS1-v1_5 encoding. Private RSA stays in Keychain.
enum KeychainRSASignature {
    static func signEncoded(_ encoded: Data, using key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureRaw, encoded as CFData, &error) else {
            throw error?.takeRetainedValue() as Error?
                ?? NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInternalError))
        }
        return signature as Data
    }

    private enum Hash {
        case sha256, sha384, sha512
        func digest(_ data: Data) -> [UInt8] {
            switch self {
            case .sha256: return Array(SHA256.hash(data: data))
            case .sha384: return Array(SHA384.hash(data: data))
            case .sha512: return Array(SHA512.hash(data: data))
            }
        }
        var digestInfoPrefix: [UInt8] {
            switch self {
            case .sha256: return [0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20]
            case .sha384: return [0x30,0x41,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x02,0x05,0x00,0x04,0x30]
            case .sha512: return [0x30,0x51,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x03,0x05,0x00,0x04,0x40]
            }
        }
    }

    static func encode(_ message: Data, algorithm: SignatureAlgorithm, modulusBitCount: Int) throws -> Data {
        let hash: Hash
        let pss: Bool
        switch algorithm {
        case .rsaPssRsaeSha256: hash = .sha256; pss = true
        case .rsaPssRsaeSha384: hash = .sha384; pss = true
        case .rsaPssRsaeSha512: hash = .sha512; pss = true
        case .rsaPkcs1Sha256: hash = .sha256; pss = false
        case .rsaPkcs1Sha384: hash = .sha384; pss = false
        case .rsaPkcs1Sha512: hash = .sha512; pss = false
        default: throw NIOSSLError.failedToLoadPrivateKey
        }
        guard (1024...16384).contains(modulusBitCount) else { throw NIOSSLError.failedToLoadPrivateKey }
        let blockLength = (modulusBitCount + 7) / 8
        let digest = hash.digest(message)
        if !pss {
            let digestInfo = hash.digestInfoPrefix + digest
            guard blockLength >= digestInfo.count + 11 else { throw NIOSSLError.failedToLoadPrivateKey }
            return Data([0, 1] + Array(repeating: 0xff, count: blockLength - digestInfo.count - 3)
                        + [0] + digestInfo)
        }

        let encodedLength = (modulusBitCount - 1 + 7) / 8
        guard encodedLength >= 2 * digest.count + 2 else { throw NIOSSLError.failedToLoadPrivateKey }
        var salt = [UInt8](repeating: 0, count: digest.count)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let h = hash.digest(Data(Array(repeating: 0, count: 8) + digest + salt))
        var db = Array(repeating: UInt8(0), count: encodedLength - 2 * digest.count - 2) + [1] + salt
        var mask: [UInt8] = []
        var counter: UInt32 = 0
        while mask.count < db.count {
            let c = [UInt8(truncatingIfNeeded: counter >> 24), UInt8(truncatingIfNeeded: counter >> 16),
                     UInt8(truncatingIfNeeded: counter >> 8), UInt8(truncatingIfNeeded: counter)]
            mask += hash.digest(Data(h + c))
            counter += 1
        }
        for i in db.indices { db[i] ^= mask[i] }
        db[0] &= UInt8(0xff >> (8 * encodedLength - (modulusBitCount - 1)))
        return Data(Array(repeating: 0, count: blockLength - encodedLength) + db + h + [0xbc])
    }
}
