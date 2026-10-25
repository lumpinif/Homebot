// The gateway owner's local control channel (DESIGN §20.6 A5): a Unix stream socket in the
// support directory (0700), itself 0600, that accepts only peers running as this user (checked
// with getpeereid). The CLI asks the owner for status and activity, and to clear activity, here;
// it opens the database itself only when it can take the owner lock. One JSON line in, one JSON
// line out, then the connection closes.
import Foundation

public enum ControlError: Error, CustomStringConvertible, Equatable {
  case noOwner
  case failed(String)

  public var description: String {
    switch self {
    case .noOwner: "no running Homebot gateway answered"
    case .failed(let s): s
    }
  }
}

public final class ControlServer: @unchecked Sendable {
  public let path: String
  let fd: Int32
  private let lock = NSLock()
  private var stopped = false
  let handler: @Sendable (Data) async -> Data

  /// Requests larger than this are refused.
  static let maxRequest = 64 * 1024

  /// Bind and listen. The caller holds the owner lock, so a socket file left at `path` belongs to
  /// a previous owner that exited; it is replaced (only if it is a socket).
  public init(path: String, handler: @escaping @Sendable (Data) async -> Data) throws {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw ControlError.failed("the control socket path is too long") }
    var st = stat()
    if lstat(path, &st) == 0 {
      guard st.st_mode & S_IFMT == S_IFSOCK else { throw ControlError.failed("\((path as NSString).lastPathComponent) exists and is not a socket") }
      unlink(path)
    }
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { throw ControlError.failed("cannot create the control socket (errno \(errno))") }
    var addr = ControlServer.address(path)
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard bound == 0, chmod(path, 0o600) == 0, listen(s, 16) == 0 else {
      let e = errno
      close(s)
      unlink(path)
      throw ControlError.failed("cannot listen on the control socket (errno \(e))")
    }
    fd = s
    self.path = path
    self.handler = handler
    let t = Thread { [self] in loop() }
    t.name = "homebot.control"
    t.start()
  }

  static func address(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      let b = Array(path.utf8)
      for (i, c) in b.enumerated() where i < buf.count - 1 { buf[i] = c }
    }
    return addr
  }

  private var isStopped: Bool { lock.withLock { stopped } }

  private func loop() {
    while !isStopped {
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if poll(&p, 1, 100) <= 0 { continue }
      let c = accept(fd, nil, nil)
      if c < 0 { continue }
      serve(c)
    }
    close(fd)
  }

  private func serve(_ c: Int32) {
    defer { close(c) }
    var one: Int32 = 1
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { return }
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count <= ControlServer.maxRequest, !data.contains(0x0A) {
      let n = read(c, &buf, buf.count)
      if n <= 0 { break }
      data.append(contentsOf: buf[0..<n])
    }
    guard data.count <= ControlServer.maxRequest, let nl = data.firstIndex(of: 0x0A) else { return }
    let req = Data(data[..<nl])
    let box = ResultBox()
    let sem = DispatchSemaphore(value: 0)
    let h = handler
    Task.detached {
      box.value = await h(req)
      sem.signal()
    }
    sem.wait()
    var out = box.value
    out.append(0x0A)
    out.withUnsafeBytes { b in
      var off = 0
      while off < b.count {
        let n = write(c, b.baseAddress! + off, b.count - off)
        if n <= 0 { return }
        off += n
      }
    }
  }

  final class ResultBox: @unchecked Sendable {
    var value = Data()
  }

  /// Stop accepting and remove the socket file at once. It never waits for a request being
  /// served: that request's handler may need the caller (the gateway actor), which would
  /// deadlock. The accept loop closes the listening socket within 100 ms; a request already
  /// accepted still gets its answer. The path is removed here, before the caller releases the
  /// owner lock, so the loop never touches a socket file of the next owner.
  public func stop() {
    let first = lock.withLock { () -> Bool in
      defer { stopped = true }
      return !stopped
    }
    guard first else { return }
    unlink(path)
  }

  deinit { stop() }
}

public enum ControlClient {
  /// Send one request to the owner and return its answer. `.noOwner` when nothing listens.
  public static func call(path: String, _ request: Data, timeoutMs: Int = 10_000) throws -> Data {
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { throw ControlError.failed("cannot create a socket (errno \(errno))") }
    defer { close(s) }
    var one: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = ControlServer.address(path)
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { throw ControlError.noOwner }
    var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var req = request
    req.append(0x0A)
    let sent = req.withUnsafeBytes { b -> Bool in
      var off = 0
      while off < b.count {
        let n = write(s, b.baseAddress! + off, b.count - off)
        if n <= 0 { return false }
        off += n
      }
      return true
    }
    guard sent else { throw ControlError.noOwner }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = read(s, &buf, buf.count)
      if n <= 0 { break }
      data.append(contentsOf: buf[0..<n])
      if data.last == 0x0A { break }
    }
    guard let nl = data.firstIndex(of: 0x0A) else { throw ControlError.failed("the gateway did not answer") }
    return Data(data[..<nl])
  }
}
