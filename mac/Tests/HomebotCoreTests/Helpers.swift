import Foundation
import Testing

@testable import HomebotCore
@_exported import HomebotTestSupport

/// The value, asserted to exist (the TypeScript `must`).
func must<T>(_ v: T?, _ what: String = "value", sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
  try #require(v, "expected \(what) to exist", sourceLocation: sourceLocation)
}

func fixture(_ name: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

/// Deterministic UUIDs, as scripts/swift-golden.ts draws them.
func counterUUIDs() -> ShortcutBuilder {
  var n = 0
  return ShortcutBuilder {
    n += 1
    let hex = String(n, radix: 16, uppercase: true)
    return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - hex.count) + hex
  }
}

/// Error text of a thrown error, for message checks.
func errorText(_ body: () async throws -> Void) async -> String? {
  do {
    try await body()
    return nil
  } catch {
    return String(describing: error)
  }
}

/// Run `plutil -lint` on XML text.
func plutilLint(_ xml: String) throws -> Bool {
  let dir = try tmpDir()
  let f = dir.appendingPathComponent("x.shortcut")
  try xml.write(to: f, atomically: true, encoding: .utf8)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
  p.arguments = ["-lint", f.path]
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  try p.run()
  p.waitUntilExit()
  return p.terminationStatus == 0
}

