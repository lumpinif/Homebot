// Private-file helpers (DESIGN §11, §20.5 T0). Every file Homebot writes may hold a secret, so it
// is created 0600 from the first byte (temp file in the same directory, then rename) and never
// widened later. Ported from src/core/fsutil.ts.
import Foundation

public enum FileUtil {
  public static let tmpSuffix = ".homebot-tmp"

  /// An error whose message never quotes file content (these files hold secrets).
  public struct FileError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
  }

  /// Create a directory (and parents) with mode 0700; tighten it if it already exists.
  public static func ensurePrivateDir(_ dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var st = stat()
    guard stat(dir.path, &st) == 0 else { throw FileError("cannot stat \(dir.lastPathComponent)") }
    if st.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
  }

  /// Atomically write `data` to `file` with mode 0600.
  public static func writePrivateFile(_ file: URL, _ data: Data) throws {
    let dir = file.deletingLastPathComponent()
    try ensurePrivateDir(dir)
    let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).\(Random.hex(bytes: 6))\(tmpSuffix)")
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FileError("cannot write \(file.lastPathComponent) (errno \(errno))") }
    var ok = false
    defer {
      if !ok { unlink(tmp.path) }
    }
    let written = data.withUnsafeBytes { buf -> Bool in
      var off = 0
      while off < buf.count {
        let n = write(fd, buf.baseAddress! + off, buf.count - off)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        off += n
      }
      return true
    }
    let synced = fsync(fd) == 0
    close(fd)
    guard written, synced else { throw FileError("cannot write \(file.lastPathComponent)") }
    guard rename(tmp.path, file.path) == 0 else { throw FileError("cannot write \(file.lastPathComponent) (errno \(errno))") }
    ok = true
  }

  public static func writePrivateFile(_ file: URL, _ text: String) throws {
    try writePrivateFile(file, Data(text.utf8))
  }

  /// Write a JSON value the way the TypeScript version did: two-space indent, trailing newline.
  public static func writeJSON<T: Encodable>(_ file: URL, _ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try enc.encode(value)
    data.append(0x0A)
    try writePrivateFile(file, data)
  }

  /// The file's bytes, or nil if it does not exist. Other failures get a fixed message.
  public static func readIfExists(_ file: URL) throws -> Data? {
    do {
      return try Data(contentsOf: file)
    } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
      return nil
    } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) {
      return nil
    } catch {
      throw FileError("cannot read \(file.lastPathComponent)")
    }
  }

  /// Decode JSON; nil if the file does not exist. Parse errors are replaced by a fixed message:
  /// a decoder error can quote file content, and these files hold secrets.
  public static func readJSON<T: Decodable>(_ type: T.Type, from file: URL) throws -> T? {
    guard let data = try readIfExists(file) else { return nil }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw FileError("\(file.path) is not valid JSON")
    }
  }

  /// A temp file younger than this may belong to a write in progress in another process.
  public static let tempSweepAgeMs: Double = 10 * 60 * 1000

  /// Delete leftover temp files from interrupted writes (called at startup). Only files older than
  /// `tempSweepAgeMs` are removed, so another process's write in progress is never broken.
  @discardableResult
  public static func sweepTempFiles(_ dir: URL, minAgeMs: Double = tempSweepAgeMs) -> Int {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
    let now = Date().timeIntervalSince1970 * 1000
    var n = 0
    for name in names where name.hasSuffix(tmpSuffix) && (ageMs(dir.appendingPathComponent(name), now: now) ?? 0) >= minAgeMs {
      if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { n += 1 }
    }
    return n
  }

  /// "inode:size:mtime" of a file, or "missing": writes are rename-based, so any change shows.
  public static func fingerprint(_ file: URL) -> String {
    var st = stat()
    guard stat(file.path, &st) == 0 else { return "missing" }
    return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
  }

  /// The permission bits of a path (tests and checks).
  public static func mode(_ path: URL) -> mode_t? {
    var st = stat()
    guard lstat(path.path, &st) == 0 else { return nil }
    return st.st_mode & 0o777
  }

  /// Seconds since the last modification, or nil if missing.
  static func ageMs(_ path: URL, now: Double) -> Double? {
    var st = stat()
    guard lstat(path.path, &st) == 0 else { return nil }
    let mtime = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec) / 1_000_000
    return now - mtime
  }
}

/// The lock is acquired asynchronously and released synchronously, so callers inside an actor do
/// their read-modify-write without a suspension point in between.
/// Cross-process lock on `<file>.lock` (DESIGN §20.5 T0): a kernel `flock`, released by the
/// kernel when the holder exits or crashes, and never broken by elapsed time. The lock file
/// itself is left in place (unlinking it would let two processes lock different files).
/// `flock` locks belong to the open file description, so two acquisitions in one process also
/// exclude each other.
public final class FileLock: Sendable {
  public let path: String
  let fd: Int32

  init(path: String, fd: Int32) {
    self.path = path
    self.fd = fd
  }

  public static func acquire(for file: URL, timeoutMs: Double = 3000) async throws -> FileLock {
    let lock = file.path + ".lock"
    let fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw FileUtil.FileError("cannot lock \(file.lastPathComponent) (errno \(errno))") }
    let start = Date()
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let err = errno
      guard err == EWOULDBLOCK || err == EINTR else {
        close(fd)
        throw FileUtil.FileError("cannot lock \(file.lastPathComponent) (errno \(err))")
      }
      if Date().timeIntervalSince(start) * 1000 > timeoutMs {
        close(fd)
        throw FileUtil.FileError("timed out waiting for \(file.lastPathComponent).lock")
      }
      do {
        try await Task.sleep(nanoseconds: 5_000_000)
      } catch {
        close(fd)
        throw error
      }
    }
    return FileLock(path: lock, fd: fd)
  }

  /// Release the lock (closing the descriptor releases it too). Call exactly once.
  public func release() {
    flock(fd, LOCK_UN)
    close(fd)
  }
}

/// Cryptographically secure random values (SystemRandomNumberGenerator is backed by the kernel CSPRNG).
public enum Random {
  public static func bytes(_ n: Int) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
  }

  public static func hex(bytes n: Int) -> String {
    bytes(n).map { String(format: "%02x", $0) }.joined()
  }

  /// base64url without padding, like Node's `toString("base64url")`.
  public static func base64url(bytes n: Int) -> String {
    Data(bytes(n)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// The gateway owner's lock (DESIGN §20.6 A5): a kernel `flock` on `gateway.lock`, held for the
/// life of the process that serves the LAN and owns the activity database. Never waited for:
/// either this process becomes the owner now, or another one already is.
public final class OwnerLock: Sendable {
  public let path: String
  let fd: Int32

  init(path: String, fd: Int32) {
    self.path = path
    self.fd = fd
  }

  /// The lock, or nil when another holder has it.
  public static func tryAcquire(_ file: URL) throws -> OwnerLock? {
    let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw FileUtil.FileError("cannot open \(file.lastPathComponent) (errno \(errno))") }
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let err = errno
      if err == EINTR { continue }
      close(fd)
      if err == EWOULDBLOCK { return nil }
      throw FileUtil.FileError("cannot lock \(file.lastPathComponent) (errno \(err))")
    }
    return OwnerLock(path: file.path, fd: fd)
  }

  /// Whether another process (or another holder in this one) owns the lock right now.
  public static func isHeld(_ file: URL) -> Bool {
    do {
      guard let l = try tryAcquire(file) else { return true }
      l.release()
      return false
    } catch {
      return false
    }
  }

  /// Release the lock. Call exactly once.
  public func release() {
    flock(fd, LOCK_UN)
    close(fd)
  }
}
