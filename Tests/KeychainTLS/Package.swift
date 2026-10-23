// swift-tools-version: 5.10
import PackageDescription

// The runner copies the production sources into its ignored build directory.
let package = Package(
    name: "SodutoKeychainTLS",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.0")
    ],
    targets: [
        .target(name: "SodutoIdentity", dependencies: [
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1")
        ]),
        .testTarget(name: "KeychainTLSTests", dependencies: [
            "SodutoIdentity", .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "_CryptoExtras", package: "swift-crypto")
        ])
    ]
)
