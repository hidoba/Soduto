import Foundation
import Security
import CryptoKit

// Only NIOSSL's wire-value/error types are supplied locally. The encoder and
// Security signing operation below are copied verbatim from production by the runner.
struct SignatureAlgorithm: Equatable {
    let rawValue: UInt16
    static let rsaPssRsaeSha256 = Self(rawValue: 0x0804)
    static let rsaPssRsaeSha384 = Self(rawValue: 0x0805)
    static let rsaPssRsaeSha512 = Self(rawValue: 0x0806)
    static let rsaPkcs1Sha256 = Self(rawValue: 0x0401)
    static let rsaPkcs1Sha384 = Self(rawValue: 0x0501)
    static let rsaPkcs1Sha512 = Self(rawValue: 0x0601)
}
enum NIOSSLError: Error { case failedToLoadPrivateKey }

func require(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}
func run() throws {
    let args = CommandLine.arguments
    if args.count == 3, args[1] == "create" {
        let directory = URL(fileURLWithPath: args[2])
        let path = directory.appendingPathComponent("temporary.keychain-db").path
        let password = "synthetic-regression-password"
        var keychain: SecKeychain?
        try require(path.withCString { path in password.withCString { secret in
            SecKeychainCreate(path, UInt32(strlen(secret)), secret, false, nil, &keychain)
        } })
        guard let keychain else { throw NIOSSLError.failedToLoadPrivateKey }
        var failure: Unmanaged<CFError>?
        guard let memoryKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false
        ] as CFDictionary, &failure), let publicKey = SecKeyCopyPublicKey(memoryKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, &failure) as Data?,
              let privateDER = SecKeyCopyExternalRepresentation(memoryKey, &failure) as Data? else {
            throw NIOSSLError.failedToLoadPrivateKey
        }
        try publicDER.write(to: directory.appendingPathComponent("public.der"))
        // Only a newly generated in-memory key is serialized, before storage.
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + privateDER.base64EncodedString()
            + "\n-----END RSA PRIVATE KEY-----\n"
        var access: SecAccess?
        try require(SecAccessCreate("Soduto temporary regression key" as CFString, nil, &access))
        guard let access else { throw NIOSSLError.failedToLoadPrivateKey }
        // This disposable fixture permits signing from the separate consumer
        // process. Export remains gated below; no real Keychain ACL is changed.
        guard let exportACLs = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationExportClear) as? [SecACL],
              !exportACLs.isEmpty else { throw NIOSSLError.failedToLoadPrivateKey }
        for acl in exportACLs {
            try require(SecACLSetContents(acl, [] as CFArray, "Soduto temporary regression key" as CFString,
                                         SecKeychainPromptSelector(rawValue: 1)))
        }
        // Default ACL entries can cover both signing and export. Add a distinct
        // signing-only rule so export approval cannot accidentally gate signing.
        var signingACL: SecACL?
        try require(SecACLCreateWithSimpleContents(access, nil, "Synthetic signing only" as CFString,
                                                   SecKeychainPromptSelector(rawValue: 0), &signingACL))
        guard let signingACL else { throw NIOSSLError.failedToLoadPrivateKey }
        try require(SecACLUpdateAuthorizations(signingACL, [kSecACLAuthorizationSign] as CFArray))
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.accessRef = .passUnretained(access)
        let attributes = [kSecAttrIsPermanent, kSecAttrIsExtractable] as CFArray
        parameters.keyAttributes = .passUnretained(attributes)
        var format = SecExternalFormat.formatOpenSSL
        var kind = SecExternalItemType.itemTypePrivateKey
        let status = withExtendedLifetime((access, attributes)) {
            SecItemImport(Data(pem.utf8) as CFData, nil, &format, &kind, [], &parameters, keychain, nil)
        }
        try require(status)
        print("CREATED temporary legacy exportable key; signing trusted, export requires approval")
        return
    }
    guard args.count == 3 else { throw NIOSSLError.failedToLoadPrivateKey }
    let directory = URL(fileURLWithPath: args[2])
    var keychain: SecKeychain?
    try require(directory.appendingPathComponent("temporary.keychain-db").path.withCString { SecKeychainOpen($0, &keychain) })
    guard let keychain else { throw NIOSSLError.failedToLoadPrivateKey }
    if args[1] == "delete" { try require(SecKeychainDelete(keychain)); return }
    let syntheticPassword = "synthetic-regression-password"
    try require(syntheticPassword.withCString { SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true) })
    var result: CFTypeRef?
    try require(SecItemCopyMatching([
        kSecClass: kSecClassKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecMatchSearchList: [keychain], kSecReturnRef: true
    ] as CFDictionary, &result))
    guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else { throw NIOSSLError.failedToLoadPrivateKey }
    let key = result as! SecKey
    let message = Data("synthetic legacy-key TLS challenge".utf8)
    if args[1] == "old" {
        print("CONTROL high-level RSA/PSS metadata lookup")
        _ = SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePSSSHA256)
        var error: Unmanaged<CFError>?
        guard SecKeyCreateSignature(key, .rsaSignatureMessagePSSSHA256, message as CFData, &error) != nil else {
            throw error?.takeRetainedValue() as Error? ?? NIOSSLError.failedToLoadPrivateKey
        }
        print("CONTROL completed")
        return
    }
    guard args[1] == "raw" else { throw NIOSSLError.failedToLoadPrivateKey }
    var error: Unmanaged<CFError>?
    let publicDER = try Data(contentsOf: directory.appendingPathComponent("public.der"))
    guard let publicKey = SecKeyCreateWithData(publicDER as CFData, [
        kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic
    ] as CFDictionary, &error) else { throw NIOSSLError.failedToLoadPrivateKey }
    let schemes: [(SignatureAlgorithm, SecKeyAlgorithm)] = [
        (.rsaPssRsaeSha256, .rsaSignatureMessagePSSSHA256),
        (.rsaPssRsaeSha384, .rsaSignatureMessagePSSSHA384),
        (.rsaPssRsaeSha512, .rsaSignatureMessagePSSSHA512),
        (.rsaPkcs1Sha256, .rsaSignatureMessagePKCS1v15SHA256),
        (.rsaPkcs1Sha384, .rsaSignatureMessagePKCS1v15SHA384),
        (.rsaPkcs1Sha512, .rsaSignatureMessagePKCS1v15SHA512)
    ]
    for _ in 0..<100 {
        for (scheme, verifier) in schemes {
            let encoded = try KeychainRSASignature.encode(message, algorithm: scheme, modulusBitCount: 2048)
            let signature = try KeychainRSASignature.signEncoded(encoded, using: key)
            guard SecKeyVerifySignature(publicKey, verifier, message as CFData, signature as CFData, &error) else {
                throw error?.takeRetainedValue() as Error? ?? NIOSSLError.failedToLoadPrivateKey
            }
        }
    }
    print("PASS: 600 legacy-key signatures verified across all six TLS schemes without export approval")
}
setbuf(stdout, nil)
do { try run() } catch { print("FAIL:", error); exit(1) }
