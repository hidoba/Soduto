import Foundation
import Security
import XCTest
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import X509
import _CryptoExtras
import SwiftASN1
@testable import SodutoIdentity

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

/// Never sets a default keychain or searches the user's keychains.
private final class TestKeychain {
    let directory: URL
    let keychain: SecKeychain
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.keychain-db").path
        let password = "synthetic-test-password"
        var result: SecKeychain?
        let status = path.withCString { path in
            password.withCString { password in
                SecKeychainCreate(path, UInt32(strlen(password)), password, false, nil, &result)
            }
        }
        guard status == errSecSuccess, let result else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        keychain = result
    }
    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct Fixture {
    let identity: SecIdentity
    let key: SecKey
    let certificate: NIOSSLCertificate
    let certificateData: Data

    init(in keychain: SecKeychain, legacy: Bool = false, large: Bool = false) throws {
        let rsa = try _RSA.Signing.PrivateKey(keySize: large ? .bits4096 : .bits2048)
        if legacy {
            var access: SecAccess?
            XCTAssertEqual(SecAccessCreate("Synthetic legacy identity" as CFString, nil, &access), errSecSuccess)
            let acl = try XCTUnwrap(access)
            // Export requires approval; signing has its own permission. Only this
            // disposable test identity permits signing from any application.
            for entry in try XCTUnwrap(SecAccessCopyMatchingACLList(acl, kSecACLAuthorizationExportClear) as? [SecACL]) {
                XCTAssertEqual(SecACLSetContents(entry, [] as CFArray, "Synthetic export approval" as CFString,
                                                 SecKeychainPromptSelector(rawValue: 1)), errSecSuccess)
            }
            var signing: SecACL?
            XCTAssertEqual(SecACLCreateWithSimpleContents(acl, nil, "Synthetic signing" as CFString,
                                                          SecKeychainPromptSelector(rawValue: 0), &signing), errSecSuccess)
            XCTAssertEqual(SecACLUpdateAuthorizations(try XCTUnwrap(signing), [kSecACLAuthorizationSign] as CFArray), errSecSuccess)
            var parameters = SecItemImportExportKeyParameters()
            parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
            parameters.accessRef = .passUnretained(acl)
            let attributes = [kSecAttrIsPermanent, kSecAttrIsExtractable] as CFArray
            parameters.keyAttributes = .passUnretained(attributes)
            var format = SecExternalFormat.formatOpenSSL
            var kind = SecExternalItemType.itemTypePrivateKey
            var items: CFArray?
            let status = withExtendedLifetime((acl, attributes)) {
                SecItemImport(Data(rsa.pemRepresentation.utf8) as CFData, nil, &format, &kind, [],
                              &parameters, keychain, &items)
            }
            XCTAssertEqual(status, errSecSuccess)
            key = try XCTUnwrap((items as? [SecKey])?.first)
        } else {
            key = try CertificateUtils.storePrivateKey(Data(rsa.pemRepresentation.utf8), keychain: keychain)
        }
        let x509 = try CertificateUtils.createSelfSignedCertificate(commonName: UUID().uuidString,
                                                                   privateKey: rsa, expirationInterval: 86400)
        var serializer = DER.Serializer()
        try x509.serialize(into: &serializer)
        certificateData = Data(serializer.serializedBytes)
        certificate = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
        let secCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
        XCTAssertEqual(SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCertificate,
                                  kSecUseKeychain: keychain] as CFDictionary, nil), errSecSuccess)
        var found: SecIdentity?
        XCTAssertEqual(SecIdentityCreateWithCertificate(keychain, secCertificate, &found), errSecSuccess)
        identity = try XCTUnwrap(found)
    }
}

private final class HandshakeCapture: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<Void>
    init(_ promise: EventLoopPromise<Void>) { self.promise = promise }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent { promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

final class KeychainTLSTests: XCTestCase {
    override func setUp() { KeychainTLSPrivateKey.resetAuthorizationFailures() }

    private func memoryKey(bits: Int = 2048) throws -> SecKey {
        var error: Unmanaged<CFError>?
        return try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits,
            kSecAttrIsPermanent: false
        ] as CFDictionary, &error))
    }

    private func withChannel(_ body: (Channel) throws -> Void) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { try! server.close().wait() }
        let client = try ClientBootstrap(group: group).connect(to: try XCTUnwrap(server.localAddress)).wait()
        defer { try! client.close().wait() }
        try body(client)
    }

    func testAllSixTLSAlgorithmsProduceValidSignatures() throws {
        let key = try memoryKey()
        let signer = KeychainTLSPrivateKey(key: key, identityID: Data(UUID().uuidString.utf8))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let algorithms: [SecKeyAlgorithm] = [.rsaSignatureMessagePSSSHA256, .rsaSignatureMessagePSSSHA384,
            .rsaSignatureMessagePSSSHA512, .rsaSignatureMessagePKCS1v15SHA256,
            .rsaSignatureMessagePKCS1v15SHA384, .rsaSignatureMessagePKCS1v15SHA512]
        try withChannel { channel in
            var message = channel.allocator.buffer(capacity: 40)
            message.writeString("synthetic TLS certificate verification")
            for (tls, security) in zip(signer.signatureAlgorithms, algorithms) {
                let signature = try signer.sign(channel: channel, algorithm: tls, data: message).wait()
                var error: Unmanaged<CFError>?
                XCTAssertTrue(SecKeyVerifySignature(publicKey, security, Data(message.readableBytesView) as CFData,
                                                    Data(signature.readableBytesView) as CFData, &error))
            }
        }
    }

    func testDeniedAccessIsSuppressedAcrossReconnectsAndExplicitRetryWorks() throws {
        let key = try memoryKey()
        let identifier = Data(UUID().uuidString.utf8)
        let attempts = Counter()
        let deny: @Sendable (SecKeyAlgorithm, Data) throws -> Data = { _, _ in
            attempts.increment()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled))
        }
        let first = KeychainTLSPrivateKey(key: key, identityID: identifier, signer: deny)
        let reconnected = KeychainTLSPrivateKey(key: key, identityID: identifier, signer: deny)
        try withChannel { channel in
            let data = channel.allocator.buffer(capacity: 0)
            let attemptsInFlight = (0..<12).map { _ in first.sign(channel: channel, algorithm: .rsaPssRsaeSha256, data: data) }
            for result in attemptsInFlight { XCTAssertThrowsError(try result.wait()) }
            XCTAssertThrowsError(try reconnected.sign(channel: channel, algorithm: .rsaPssRsaeSha256, data: data).wait())
            XCTAssertEqual(attempts.value, 1)
            KeychainTLSPrivateKey.resetAuthorizationFailures()
            XCTAssertThrowsError(try reconnected.sign(channel: channel, algorithm: .rsaPssRsaeSha256, data: data).wait())
            XCTAssertEqual(attempts.value, 2)
        }
    }

    func testTemporaryKeychainFailureCanRecoverWithoutExplicitRetry() throws {
        let key = try memoryKey()
        let attempts = Counter()
        let signer = KeychainTLSPrivateKey(key: key, identityID: Data(UUID().uuidString.utf8)) { algorithm, data in
            attempts.increment()
            if attempts.value == 1 {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecNotAvailable))
            }
            var error: Unmanaged<CFError>?
            guard let result = SecKeyCreateSignature(key, algorithm, data as CFData, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return result as Data
        }
        try withChannel { channel in
            var message = channel.allocator.buffer(capacity: 20)
            message.writeString("synthetic wake retry")
            XCTAssertThrowsError(try signer.sign(channel: channel, algorithm: .rsaPssRsaeSha256, data: message).wait())
            let signature = try signer.sign(channel: channel, algorithm: .rsaPssRsaeSha256, data: message).wait()
            XCTAssertEqual(attempts.value, 2)
            var error: Unmanaged<CFError>?
            XCTAssertTrue(SecKeyVerifySignature(try XCTUnwrap(SecKeyCopyPublicKey(key)), .rsaSignatureMessagePSSSHA256,
                                                Data(message.readableBytesView) as CFData,
                                                Data(signature.readableBytesView) as CFData, &error))
        }
    }

    func testUnsupportedAlgorithmsFailWithoutUsingKeychain() throws {
        let attempts = Counter()
        let signer = KeychainTLSPrivateKey(key: try memoryKey(), identityID: Data(UUID().uuidString.utf8)) { _, _ in
            attempts.increment(); return Data()
        }
        try withChannel { channel in
            let data = channel.allocator.buffer(capacity: 0)
            XCTAssertThrowsError(try signer.sign(channel: channel, algorithm: .rsaPkcs1Sha1, data: data).wait())
            XCTAssertThrowsError(try signer.decrypt(channel: channel, data: data).wait())
            XCTAssertEqual(attempts.value, 0)
        }
    }

    func testSigningUsesOnlyRawRSAWithPubliclySizedPadding() throws {
        let key = try memoryKey(bits: 4096)
        let signer = KeychainTLSPrivateKey(key: key, identityID: Data(UUID().uuidString.utf8), modulusBitCount: 4096) { algorithm, encoded in
            XCTAssertEqual(algorithm, .rsaSignatureRaw)
            XCTAssertEqual(encoded.count, 512)
            return try KeychainRSASignature.signEncoded(encoded, using: key)
        }
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        try withChannel { channel in
            var message = channel.allocator.buffer(capacity: 20)
            message.writeString("synthetic raw signing")
            let signature = try signer.sign(channel: channel, algorithm: .rsaPssRsaeSha512, data: message).wait()
            var error: Unmanaged<CFError>?
            XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePSSSHA512,
                                                Data(message.readableBytesView) as CFData,
                                                Data(signature.readableBytesView) as CFData, &error))
        }
    }

    func testEncodingRejectsInvalidSizesAndUnsupportedAlgorithms() throws {
        for bits in [0, 512, 16385, Int.max] {
            XCTAssertThrowsError(try KeychainRSASignature.encode(Data(), algorithm: .rsaPssRsaeSha256, modulusBitCount: bits))
        }
        XCTAssertThrowsError(try KeychainRSASignature.encode(Data(), algorithm: .rsaPssRsaeSha512, modulusBitCount: 1024))
        XCTAssertThrowsError(try KeychainRSASignature.encode(Data(), algorithm: .rsaPkcs1Sha1, modulusBitCount: 2048))
    }

    func testPSSUsesFreshSaltAndPKCS1IsDeterministic() throws {
        let message = Data("synthetic padding challenge".utf8)
        XCTAssertNotEqual(try KeychainRSASignature.encode(message, algorithm: .rsaPssRsaeSha256, modulusBitCount: 2048),
                          try KeychainRSASignature.encode(message, algorithm: .rsaPssRsaeSha256, modulusBitCount: 2048))
        XCTAssertEqual(try KeychainRSASignature.encode(message, algorithm: .rsaPkcs1Sha256, modulusBitCount: 2048),
                       try KeychainRSASignature.encode(message, algorithm: .rsaPkcs1Sha256, modulusBitCount: 2048))
    }

    func testNonExportablePrivateKeyCanStillSignTLSChallenges() throws {
        let keychain = try TestKeychain()
        let fixture = try Fixture(in: keychain.keychain)
        let key = fixture.key
        var error: Unmanaged<CFError>?
        XCTAssertNil(SecKeyCopyExternalRepresentation(key, &error))
        let signer = KeychainTLSPrivateKey(key: key, identityID: Data(UUID().uuidString.utf8))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        try withChannel { channel in
            var message = channel.allocator.buffer(capacity: 16)
            message.writeString("synthetic input")
            let signature = try signer.sign(channel: channel, algorithm: .rsaPssRsaeSha256, data: message).wait()
            var error: Unmanaged<CFError>?
            XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePSSSHA256,
                                                Data(message.readableBytesView) as CFData,
                                                Data(signature.readableBytesView) as CFData, &error))
        }
    }

    func testPermanentIdentityHasReadableLabelAndRetainsCertificate() throws {
        let keychain = try TestKeychain()
        let fixture = try Fixture(in: keychain.keychain)
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass: kSecClassKey, kSecMatchItemList: [fixture.key],
            kSecMatchSearchList: [keychain.keychain], kSecReturnAttributes: true
        ] as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrLabel as String] as? String, "Soduto Device Identity")
        var access: SecAccess?
        let item = unsafeBitCast(fixture.key, to: SecKeychainItem.self)
        XCTAssertEqual(SecKeychainItemCopyAccess(item, &access), errSecSuccess)
        let signingACLs = try XCTUnwrap(SecAccessCopyMatchingACLList(try XCTUnwrap(access),
                                                                  kSecACLAuthorizationSign) as? [SecACL])
        XCTAssertFalse(signingACLs.isEmpty)
        for acl in signingACLs {
            var applications: CFArray?
            var description: CFString?
            var flags = SecKeychainPromptSelector()
            XCTAssertEqual(SecACLCopyContents(acl, &applications, &description, &flags), errSecSuccess)
            XCTAssertEqual(description as String?, "Soduto Device Identity")
            XCTAssertFalse((applications as? [SecTrustedApplication] ?? []).isEmpty)
        }
        _ = try KeychainTLSIdentity.configuration(for: fixture.identity, server: false)
        _ = try KeychainTLSIdentity.configuration(for: fixture.identity, server: true)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(fixture.identity, &certificate), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(certificate)) as Data, fixture.certificateData)
    }

    private func handshake(version: TLSVersion, algorithm: SignatureAlgorithm? = nil, repetitions: Int = 1,
                           legacy: Bool = false, large: Bool = false) throws {
        let keychain = try TestKeychain()
        let serverIdentity = try Fixture(in: keychain.keychain, legacy: legacy, large: large)
        let clientIdentity = try Fixture(in: keychain.keychain, legacy: legacy, large: large)
        var serverConfiguration = try KeychainTLSIdentity.configuration(for: serverIdentity.identity, server: true)
        var clientConfiguration = try KeychainTLSIdentity.configuration(for: clientIdentity.identity, server: false)
        serverConfiguration.maximumTLSVersion = version
        serverConfiguration.minimumTLSVersion = version
        clientConfiguration.maximumTLSVersion = version
        clientConfiguration.minimumTLSVersion = version
        if let algorithm {
            serverConfiguration.signingSignatureAlgorithms = [algorithm]
            clientConfiguration.signingSignatureAlgorithms = [algorithm]
        }
        let serverContext = try NIOSSLContext(configuration: serverConfiguration)
        let clientContext = try NIOSSLContext(configuration: clientConfiguration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }
        for _ in 0..<repetitions {
            let serverComplete = group.next().makePromise(of: Void.self)
            let clientComplete = group.next().makePromise(of: Void.self)
            let timeout = group.next().scheduleTask(in: .seconds(10)) {
                serverComplete.fail(NIOSSLError.failedToLoadPrivateKey)
                clientComplete.fail(NIOSSLError.failedToLoadPrivateKey)
            }
            defer { timeout.cancel() }
            let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
                let tls = NIOSSLServerHandler(context: serverContext, customVerificationCallback: { certs, promise in
                    promise.succeed(certs.first == clientIdentity.certificate ? .certificateVerified : .failed)
                })
                return channel.pipeline.addHandlers(tls, HandshakeCapture(serverComplete))
            }.bind(host: "127.0.0.1", port: 0).wait()
            defer { try! server.close().wait() }
            let client = try ClientBootstrap(group: group).channelInitializer { channel in
                do {
                    let tls = try NIOSSLClientHandler(context: clientContext, serverHostname: nil,
                                                     customVerificationCallback: { certs, promise in
                        promise.succeed(certs.first == serverIdentity.certificate ? .certificateVerified : .failed)
                    })
                    return channel.pipeline.addHandlers(tls, HandshakeCapture(clientComplete))
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(to: try XCTUnwrap(server.localAddress)).wait()
            defer { try! client.close().wait() }
            try clientComplete.futureResult.wait()
            try serverComplete.futureResult.wait()
        }
    }

    func testMutualTLS12WithRSAPSS() throws { try handshake(version: .tlsv12, algorithm: .rsaPssRsaeSha256) }
    func testMutualTLS12WithRSAPKCS1() throws { try handshake(version: .tlsv12, algorithm: .rsaPkcs1Sha256) }
    func testMutualTLS13() throws { try handshake(version: .tlsv13) }
    func testRepeatedReconnectsWithSameIdentity() throws { try handshake(version: .tlsv13, repetitions: 5) }
    func testLegacyExportProtectedIdentityWithTLS12() throws { try handshake(version: .tlsv12, legacy: true) }
    func testLegacyExportProtectedIdentityWithTLS13() throws { try handshake(version: .tlsv13, repetitions: 5, legacy: true) }
    func test4096BitIdentityWithTLS13() throws { try handshake(version: .tlsv13, large: true) }
}
