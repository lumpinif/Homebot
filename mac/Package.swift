// swift-tools-version: 6.2
// Homebot.app, native rewrite (DESIGN §20). HomebotCore holds everything that is not UI or
// network listener: stores, tokens, the Grok Bot client, ownership rules, catalogs, Shortcut
// builder, AskService, activity. HomebotGateway is the LAN listener (Hummingbird 2 on SwiftNIO,
// DESIGN §20.2) and the gateway host the app and `homebot start` own. HomebotCLI is the `homebot`
// command for agents and power users. HomebotUI is the app's model and SwiftUI views (S3); the
// HomebotApp executable is Homebot.app's main binary, bundled by scripts/build-app.sh. The S0
// spike in spike/ is a separate package.
import PackageDescription

let package = Package(
  name: "Homebot",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "HomebotCore", targets: ["HomebotCore"]),
    .library(name: "HomebotGateway", targets: ["HomebotGateway"]),
    .library(name: "HomebotCLI", targets: ["HomebotCLI"]),
    .executable(name: "homebot", targets: ["homebot"]),
    .executable(name: "HomebotApp", targets: ["HomebotApp"]),
  ],
  dependencies: [
    // Apache-2.0 (checked at adoption, 2026-10-23; DESIGN §20.2).
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", .upToNextMinor(from: "2.28.0")),
    // Apache-2.0.
    .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMinor(from: "1.8.2")),
    // Apache-2.0; already resolved for Hummingbird. Named so the gateway can use ByteBuffer and
    // its own channel handler (disconnects, Connection: close, the request timer).
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
  ],
  targets: [
    .target(name: "HomebotCore", path: "Sources/HomebotCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOKit")]),
    .target(
      name: "HomebotGateway",
      dependencies: [
        "HomebotCore",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Sources/HomebotGateway"
    ),
    .target(
      name: "HomebotCLI",
      dependencies: ["HomebotCore", "HomebotGateway", .product(name: "ArgumentParser", package: "swift-argument-parser")],
      path: "Sources/HomebotCLI"
    ),
    .executableTarget(name: "homebot", dependencies: ["HomebotCLI"], path: "Sources/homebot"),
    .target(
      name: "HomebotUI",
      dependencies: ["HomebotCore", "HomebotGateway"],
      path: "Sources/HomebotUI",
      linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("CoreImage")]
    ),
    .executableTarget(name: "HomebotApp", dependencies: ["HomebotUI"], path: "Sources/HomebotApp"),
    // Test doubles shared by the test targets (the fake Grok Bot API, scripted pages).
    .target(name: "HomebotTestSupport", dependencies: ["HomebotCore"], path: "Tests/HomebotTestSupport"),
    .testTarget(
      name: "HomebotCoreTests",
      dependencies: ["HomebotCore", "HomebotTestSupport"],
      path: "Tests/HomebotCoreTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "HomebotGatewayTests",
      dependencies: ["HomebotCore", "HomebotGateway", "HomebotCLI", "HomebotTestSupport"],
      path: "Tests/HomebotGatewayTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "HomebotUITests",
      dependencies: ["HomebotCore", "HomebotGateway", "HomebotUI", "HomebotTestSupport"],
      path: "Tests/HomebotUITests"
    ),
  ]
)
