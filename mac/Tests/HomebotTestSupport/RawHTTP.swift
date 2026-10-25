// A minimal HTTP/1.1 client over a POSIX socket, for gateway tests: it can send a body in pieces
// with pauses, lie about Content-Length, and drop the connection, which URLSession can't. Every
// request says `Connection: close` and reads the response to EOF. Runs on its own thread.
import Foundation

public struct RawResponse: Sendable {
  public var status: Int
  /// Header names in lower case.
  public var headers: [String: String]
  public var body: Data
  /// The whole response as received ("" if the server closed without answering).
  public var raw: String

  public var text: String { String(decoding: body, as: UTF8.self) }
  public var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

public enum RawHTTP {
  /// Send a request. `parts` (if given) replace `body` and are written `pauseMs` apart.
  /// `dropAfterSend`: close the socket right after the last part, without reading.
  /// `abortAfterMs`: close the socket that long after sending, if no answer came yet.
  public static func send(port: Int, method: String = "POST", path: String = "/v1/ask", headers: [String: String] = [:], body: Data = Data(), parts: [Data]? = nil, contentLength: Int? = nil, pauseMs: Int = 30, dropAfterSend: Bool = false, abortAfterMs: Int? = nil, timeoutMs: Int = 10_000) async -> RawResponse {
    await withCheckedContinuation { c in
      let t = Thread {
        c.resume(returning: run(port: port, method: method, path: path, headers: headers, parts: parts ?? [body], contentLength: contentLength, pauseMs: pauseMs, dropAfterSend: dropAfterSend, abortAfterMs: abortAfterMs, timeoutMs: timeoutMs))
      }
      t.start()
    }
  }

  public static func json(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])) ?? Data() }

  /// POST a JSON value with the token header.
  public static func post(port: Int, path: String = "/v1/ask", token: String? = "t", _ value: Any) async -> RawResponse {
    var h = ["Content-Type": "application/json"]
    if let token { h["X-Homebot-Token"] = token }
    return await send(port: port, path: path, headers: h, body: json(value))
  }

  public static func get(port: Int, path: String, token: String? = nil, abortAfterMs: Int? = nil) async -> RawResponse {
    var h: [String: String] = [:]
    if let token { h["X-Homebot-Token"] = token }
    return await send(port: port, method: "GET", path: path, headers: h, abortAfterMs: abortAfterMs)
  }

  static func run(port: Int, method: String, path: String, headers: [String: String], parts: [Data], contentLength: Int?, pauseMs: Int, dropAfterSend: Bool, abortAfterMs: Int?, timeoutMs: Int) -> RawResponse {
    let empty = RawResponse(status: 0, headers: [:], body: Data(), raw: "")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return empty }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { return empty }
    let len = contentLength ?? parts.reduce(0) { $0 + $1.count }
    var head = "\(method) \(path) HTTP/1.1\r\nHost: x\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    if method != "GET" || len > 0 { head += "Content-Length: \(len)\r\n" }
    head += "Connection: close\r\n\r\n"
    writeAll(fd, Data(head.utf8))
    for (i, p) in parts.enumerated() {
      writeAll(fd, p)
      if parts.count > 1 && i < parts.count - 1 { usleep(useconds_t(pauseMs * 1000)) }
    }
    if dropAfterSend { return empty }
    let deadline = Date().addingTimeInterval(Double(abortAfterMs ?? timeoutMs) / 1000)
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while Date() < deadline {
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ms = Int32(max(1, min(50, deadline.timeIntervalSinceNow * 1000)))
      if poll(&p, 1, ms) <= 0 { continue }
      let n = read(fd, &buf, buf.count)
      if n <= 0 { break }
      data.append(contentsOf: buf[0..<n])
    }
    return parse(data)
  }

  /// Write raw bytes (e.g. two pipelined requests), wait, then close without reading.
  public static func writeThenClose(port: Int, _ raw: Data, closeAfterMs: Int) async {
    await Task.detached {
      let fd = socket(AF_INET, SOCK_STREAM, 0)
      guard fd >= 0 else { return }
      defer { close(fd) }
      var one: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      var addr = sockaddr_in()
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = in_port_t(UInt16(port).bigEndian)
      addr.sin_addr.s_addr = inet_addr("127.0.0.1")
      let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
      guard ok == 0 else { return }
      writeAll(fd, raw)
      usleep(useconds_t(closeAfterMs * 1000))
    }.value
  }

  static func writeAll(_ fd: Int32, _ d: Data) {
    d.withUnsafeBytes { b in
      var off = 0
      while off < b.count {
        let n = write(fd, b.baseAddress! + off, b.count - off)
        if n <= 0 { return }
        off += n
      }
    }
  }

  static func parse(_ data: Data) -> RawResponse {
    let raw = String(decoding: data, as: UTF8.self)
    guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return RawResponse(status: 0, headers: [:], body: Data(), raw: raw) }
    let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let status = head.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
    var headers: [String: String] = [:]
    for line in head.dropFirst() {
      guard let i = line.firstIndex(of: ":") else { continue }
      headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
    }
    var body = Data(data[sep.upperBound...])
    if headers["transfer-encoding"]?.lowercased() == "chunked" { body = dechunk(body) }
    return RawResponse(status: status, headers: headers, body: body, raw: raw)
  }

  static func dechunk(_ d: Data) -> Data {
    var out = Data()
    var rest = d[...]
    while let crlf = rest.range(of: Data("\r\n".utf8)) {
      let size = Int(String(decoding: rest[..<crlf.lowerBound], as: UTF8.self), radix: 16) ?? 0
      if size == 0 { break }
      let start = crlf.upperBound
      guard rest.distance(from: start, to: rest.endIndex) >= size else { break }
      let end = rest.index(start, offsetBy: size)
      out.append(rest[start..<end])
      rest = rest[rest.index(end, offsetBy: min(2, rest.distance(from: end, to: rest.endIndex)))...]
    }
    return out
  }
}
