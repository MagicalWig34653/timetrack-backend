// swift-tools-version:6.3
import PackageDescription
let package = Package(
    name: "TimetrackBackend",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TimetrackKit", targets: ["TimetrackKit"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-mysql-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/swift-server/webauthn-swift.git", from: "1.0.0-beta.1"),
        .package(url: "https://github.com/tmthecoder/Argon2Swift.git", from: "1.0.4")
    ],
    targets: [
        .target(name: "TimetrackKit", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            .product(name: "WebAuthn", package: "webauthn-swift"),
            .product(name: "Argon2Swift", package: "Argon2Swift")
        ]),
        .executableTarget(name: "App", dependencies: ["TimetrackKit"]),
        .testTarget(name: "TimetrackKitTests", dependencies: ["TimetrackKit", .product(name: "XCTVapor", package: "vapor")])
    ]
)
