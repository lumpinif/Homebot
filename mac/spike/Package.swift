// swift-tools-version: 6.0
// S0 spike (DESIGN §20.9): checks the platform behaviour the Swift rewrite depends on.
// Throwaway code; it never contacts Grok Bot or Apple's signing service.
import PackageDescription

let package = Package(
  name: "HomebotSpike",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "HomebotSpike", path: "Sources/HomebotSpike"),
  ]
)
