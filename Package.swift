// swift-tools-version:6.3
import PackageDescription
let package = Package(
    name: "TimetrackBackend",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TimetrackKit", targets: ["TimetrackKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-mysql-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/swift-server/webauthn-swift.git", from: "1.0.0-beta.1"),
        .package(url: "https://github.com/tmthecoder/Argon2Swift.git", branch: "main"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(name: "TimetrackKit", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            .product(name: "WebAuthn", package: "webauthn-swift"),
            .product(name: "Argon2Swift", package: "Argon2Swift"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ], resources: [.copy("Resources/RecoveryMail.de.json")]),
        .executableTarget(name: "App", dependencies: ["TimetrackKit"]),
        .testTarget(name: "TimetrackKitTests", dependencies: ["TimetrackKit", .product(name: "NIOEmbedded", package: "swift-nio"), .product(name: "XCTVapor", package: "vapor")])
    ]
)
