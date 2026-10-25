// JSONL diagnostic log (DESIGN §11, §20.6 A7): one line per event, file 0600, rotated at
// 5 MB × 3. Callers pass only ids, timings, outcomes and lengths — never secrets or text.
// Ported from src/core/log.ts.
import Foundation

public enum LogField: Sendable, Equatable, Encodable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  public init(stringLiteral v: String) { self = .string(v) }
  public init(integerLiteral v: Int) { self = .int(v) }
  public init(booleanLiteral v: Bool) { self = .bool(v) }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .bool(let b): try c.encode(b)
    }
  }
}

public typealias LogEvent = [String: LogField]
public typealias LogFn = @Sendable (LogEvent) -> Void

public enum Log {
  /// An error's class for the log, from a fixed list. A type name or message can carry data, so
  /// any other error is logged as "other" (BDK re-review R2).
  public static func errorName(_ e: Error?) -> String {
    guard let e else { return "non-error" }
    switch e {
    case is CancellationError: return "AbortError"
    case is BdkError: return "BdkError"
    case is DecodingError: return "SyntaxError"
    case let u as URLError where u.code == .timedOut: return "TimeoutError"
    default: return "other"
    }
  }

  public static let maxBytes = 5 * 1024 * 1024
  public static let keep = 3
}

/// Appends events to `<dir>/homebot.jsonl` in order; failures are swallowed (logging never
/// breaks a request).
public actor JSONLLogger {
  public nonisolated let file: URL
  let maxBytes: Int

  public init(dir: URL, maxBytes: Int = Log.maxBytes) {
    file = dir.appendingPathComponent("homebot.jsonl")
    self.maxBytes = maxBytes
  }

  /// A logging function for services; events are written in the order they were sent.
  public nonisolated var fn: LogFn {
    let (stream, cont) = AsyncStream<LogEvent>.makeStream()
    Task { for await e in stream { await self.write(e) } }
    return { cont.yield($0) }
  }

  public func write(_ event: LogEvent) {
    var e = event
    e["ts"] = .string(ISO8601DateFormatter.withFractionalSeconds.string(from: Date()))
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard var line = try? enc.encode(e) else { return }
    line.append(0x0A)
    // The app and the CLI may log to the same file: the size check, the rotation and the append
    // happen under one kernel lock, so two processes never rotate each other's lines away.
    let lockFd = open(file.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    if lockFd >= 0 { flock(lockFd, LOCK_EX) }
    defer {
      if lockFd >= 0 {
        flock(lockFd, LOCK_UN)
        close(lockFd)
      }
    }
    rotate()
    let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    close(fd)
  }

  func rotate() {
    var st = stat()
    guard stat(file.path, &st) == 0, st.st_size >= maxBytes else { return }
    for i in stride(from: Log.keep - 1, through: 1, by: -1) {
      rename("\(file.path).\(i)", "\(file.path).\(i + 1)")
    }
    rename(file.path, "\(file.path).1")
  }
}

extension ISO8601DateFormatter {
  nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
