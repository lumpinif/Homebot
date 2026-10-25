// Small helpers shared by the test targets.
import Foundation
import HomebotCore

/// A fresh private temporary directory (outside any git work tree).
public func tmpDir() throws -> URL {
  let u = FileManager.default.temporaryDirectory.appendingPathComponent("homebot-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u
}

/// Collects log events from a service.
public final class LogSink: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [LogEvent] = []

  public init() {}

  public var fn: LogFn { { e in self.lock.withLock { self.items.append(e) } } }
  public var events: [LogEvent] { lock.withLock { items } }
  public var json: String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return events.map { String(data: (try? enc.encode($0)) ?? Data(), encoding: .utf8) ?? "" }.joined(separator: "\n")
  }

  /// The first event named `name`.
  public func first(_ name: String) -> LogEvent? {
    events.first { $0["event"] == .string(name) }
  }
}

/// Wait until `cond` holds, polling every 5 ms, at most `ms`.
public func eventually(ms: Int = 2000, _ cond: @Sendable () async -> Bool) async -> Bool {
  let until = Date().addingTimeInterval(Double(ms) / 1000)
  while Date() < until {
    if await cond() { return true }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return await cond()
}

public func sleepMs(_ ms: Int) async {
  try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

/// A locked mutable value shared with @Sendable closures.
public final class Box<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var v: T
  public init(_ v: T) { self.v = v }
  public var value: T {
    get { lock.withLock { v } }
    set { lock.withLock { v = newValue } }
  }
  public func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
