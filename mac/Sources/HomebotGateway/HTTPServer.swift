// The LAN listener: Hummingbird 2 (HTTP/1.1 parsing on SwiftNIO) in front of VoiceAPI. Hummingbird
// keeps a request's handler running when its client goes away, so ConnectionWatch (a channel
// handler after the HTTP codec) fires the request's CancelSignal on a client's FIN, reset or
// close, which is what AskService and the conversation runs need (TypeScript: `res.on("close")`).
// It also closes the connection after a response marked `Connection: close` (a body over the
// limit is not read any further) and bounds how long a request may take to arrive.
import Foundation
import HTTPTypes
import Logging
import HomebotCore
import Hummingbird
import NIOCore
import NIOHTTPTypes

/// Hummingbird's request context, plus the channel (to find the request's ConnectionWatch).
public struct GatewayContext: RequestContext {
  public var coreContext: CoreRequestContextStorage
  public let channel: any Channel

  public init(source: ApplicationRequestContextSource) {
    coreContext = .init(source: source)
    channel = source.channel
  }
}

/// Per connection: the current request's signal, Connection: close, and the request timer.
final class ConnectionWatch: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
  typealias InboundIn = HTTPRequestPart
  typealias InboundOut = HTTPRequestPart
  typealias OutboundIn = HTTPResponsePart
  typealias OutboundOut = HTTPResponsePart

  private let lock = NSLock()
  private var _signal = CancelSignal()
  /// Every request on this connection not yet answered (pipelined requests included), so a
  /// client that leaves cancels all of them, not only the newest.
  private var open: [CancelSignal] = []
  private var closeAfterResponse = false
  private var requestTimer: Scheduled<Void>?
  let requestTimeout: TimeAmount

  init(requestTimeout: TimeAmount) {
    self.requestTimeout = requestTimeout
  }

  /// The signal of the request being handled (requests on one connection are handled in turn).
  var signal: CancelSignal { lock.withLock { _signal } }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head:
      lock.withLock {
        _signal = CancelSignal()
        open.append(_signal)
      }
      requestTimer?.cancel()
      // The whole request must arrive within the limit (Node's requestTimeout).
      let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
      requestTimer = context.eventLoop.scheduleTask(in: requestTimeout) { ctx.value.close(promise: nil) }
    case .end:
      requestTimer?.cancel()
      requestTimer = nil
    case .body:
      break
    }
    context.fireChannelRead(data)
  }

  private func cancelAll() {
    let all = lock.withLock { open + [_signal] }
    for s in all { s.cancel() }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let e = event as? ChannelEvent, e == .inputClosed { cancelAll() }
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    requestTimer?.cancel()
    cancelAll()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    cancelAll()
    context.fireErrorCaught(error)
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    switch unwrapOutboundIn(data) {
    case .head(let head):
      if head.headerFields[.connection]?.lowercased() == "close" { closeAfterResponse = true }
      context.write(data, promise: promise)
    case .end:
      // Responses go out in request order: this one answers the oldest open request.
      lock.withLock { if !open.isEmpty { open.removeFirst() } }
      if closeAfterResponse {
        context.writeAndFlush(data, promise: promise)
        context.close(promise: nil)
      } else {
        context.write(data, promise: promise)
      }
    case .body:
      context.write(data, promise: promise)
    }
  }
}

struct VoiceResponder: HTTPResponder {
  typealias Context = GatewayContext
  let api: VoiceAPI

  /// A request from this Mac itself: a loopback address, or the address it was sent to (a Mac
  /// calling its own LAN address connects from that same address).
  static func isThisMac(remote: String?, local: String?) -> Bool {
    guard let r = remote.map(plain) else { return false }
    if r == "::1" || r.hasPrefix("127.") { return true }
    return local.map(plain) == r
  }

  /// "::ffff:192.168.1.2" -> "192.168.1.2"; a zone ("fe80::1%en0") is dropped.
  static func plain(_ ip: String) -> String {
    var s = ip.lowercased()
    if let z = s.firstIndex(of: "%") { s = String(s[..<z]) }
    if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
    return s
  }

  func respond(to request: Request, context: GatewayContext) async throws -> Response {
    let watch = try? await context.channel.pipeline.handler(type: ConnectionWatch.self).get()
    let signal = watch?.signal ?? CancelSignal()
    let token = request.headers[values: HTTPField.Name("x-homebot-token")!].first ?? ""
    let body = BodyBox(request.body)
    let here = VoiceResponder.isThisMac(remote: context.channel.remoteAddress?.ipAddress, local: context.channel.localAddress?.ipAddress)
    let req = VoiceRequest(method: request.method.rawValue, target: request.head.path ?? "/", token: token, signal: signal, here: here) { max in
      try await body.read(max: max)
    }
    let r = await api.handle(req)
    if r.dropped {
      // The client left: close without answering.
      context.channel.close(promise: nil)
      return Response(status: .init(code: 499), headers: [.connection: "close"])
    }
    var headers = HTTPFields()
    for (k, v) in r.headers.sorted(by: { $0.key < $1.key }) {
      if let name = HTTPField.Name(k) { headers[name] = v }
    }
    if r.close { headers[.connection] = "close" }
    return Response(status: .init(code: r.status), headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: r.body)))
  }
}

/// The request body, read at most once, up to a limit.
final class BodyBox: @unchecked Sendable {
  private let body: RequestBody
  init(_ body: RequestBody) { self.body = body }

  func read(max: Int) async throws -> Data? {
    var out = Data()
    for try await chunk in body {
      if out.count + chunk.readableBytes > max { return nil }
      out.append(contentsOf: chunk.readableBytesView)
    }
    return out
  }
}

/// A running listener.
public final class HTTPServer: @unchecked Sendable {
  public let host: String
  private let lock = NSLock()
  private var task: Task<Void, Error>?
  private var _port: Int?

  public var port: Int? { lock.withLock { _port } }

  public init(host: String) {
    self.host = host
  }

  /// Start serving `api` on `host:port` (0: an ephemeral port). Returns the bound port, or throws
  /// when the address can't be bound (e.g. in use).
  public func start(port: Int, api: VoiceAPI, idleTimeoutMs: Int = 10_000, requestTimeoutMs: Int = 70_000) async throws -> Int {
    let bound = AsyncStream<Result<Int, Error>>.makeStream()
    let reqTimeout = TimeAmount.milliseconds(Int64(requestTimeoutMs))
    var logger = Logger(label: "homebot.gateway")
    logger.logLevel = .critical
    let app = Application(
      responder: VoiceResponder(api: api),
      server: .http1(configuration: .init(additionalChannelHandlers: [ConnectionWatch(requestTimeout: reqTimeout)], idleTimeout: .milliseconds(Int64(idleTimeoutMs)))),
      configuration: .init(address: .hostname(host, port: port), serverName: nil),
      onServerRunning: { channel in
        bound.continuation.yield(.success(channel.localAddress?.port ?? port))
      },
      logger: logger
    )
    let t = Task {
      do {
        try await app.run()
        bound.continuation.yield(.failure(GatewayError("the listener stopped")))
      } catch {
        bound.continuation.yield(.failure(error))
        throw error
      }
    }
    lock.withLock { task = t }
    for await r in bound.stream {
      switch r {
      case .success(let p):
        lock.withLock { _port = p }
        return p
      case .failure(let e):
        throw GatewayError("cannot listen on \(host):\(port) (\(HTTPServer.describe(e)))")
      }
    }
    throw GatewayError("cannot listen on \(host):\(port)")
  }

  static func describe(_ e: Error) -> String {
    let s = String(describing: e)
    if s.contains("Address already in use") || s.contains("EADDRINUSE") { return "address already in use" }
    return "bind failed"
  }

  /// Stop listening and close every connection; waits until the listener is down.
  public func stop() async {
    let t = lock.withLock { () -> Task<Void, Error>? in
      defer { task = nil }
      return task
    }
    t?.cancel()
    _ = await t?.result
  }
}

public struct GatewayError: Error, CustomStringConvertible, Equatable {
  public let description: String
  public init(_ d: String) { description = d }
}
