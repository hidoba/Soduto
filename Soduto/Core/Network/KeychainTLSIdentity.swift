import Foundation
import Security
import NIOCore
import NIOSSL
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
        let sslKey = NIOSSLPrivateKey(customPrivateKey: KeychainTLSPrivateKey(key: key, identityID: certificateData))
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
    private let signer: @Sendable (SecKeyAlgorithm, Data) throws -> Data

    init(key: SecKey, identityID: Data,
         signer: (@Sendable (SecKeyAlgorithm, Data) throws -> Data)? = nil) {
        self.key = key
        self.identityID = identityID
        self.signer = signer ?? { algorithm, message in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, algorithm, message as CFData, &error) else {
                throw error?.takeRetainedValue() as Error?
                    ?? NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInternalError))
            }
            return signature as Data
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

    private func securityAlgorithm(_ algorithm: SignatureAlgorithm) -> SecKeyAlgorithm? {
        switch algorithm {
        case .rsaPssRsaeSha256: return .rsaSignatureMessagePSSSHA256
        case .rsaPssRsaeSha384: return .rsaSignatureMessagePSSSHA384
        case .rsaPssRsaeSha512: return .rsaSignatureMessagePSSSHA512
        case .rsaPkcs1Sha256: return .rsaSignatureMessagePKCS1v15SHA256
        case .rsaPkcs1Sha384: return .rsaSignatureMessagePKCS1v15SHA384
        case .rsaPkcs1Sha512: return .rsaSignatureMessagePKCS1v15SHA512
        default: return nil
        }
    }

    func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        guard let securityAlgorithm = securityAlgorithm(algorithm),
              SecKeyIsAlgorithmSupported(key, .sign, securityAlgorithm) else {
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
                let signature = try signer(securityAlgorithm, message)
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
