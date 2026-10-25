// A one-shot cancellation signal, like the TypeScript AbortSignal: the HTTP layer fires it when
// the client disconnects, and work that may be shared between requests (a conversation step and
// its retries) observes the signal of the request that started it instead of its own task.
import Foundation

public final class CancelSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var handlers: [Int: @Sendable () -> Void] = [:]
  private var next = 0

  public init() {}

  public var isCancelled: Bool { lock.withLock { cancelled } }

  /// Fire the signal once; every registered handler runs (outside the lock).
  public func cancel() {
    let hs: [@Sendable () -> Void] = lock.withLock {
      if cancelled { return [] }
      cancelled = true
      defer { handlers = [:] }
      return Array(handlers.values)
    }
    hs.forEach { $0() }
  }

  /// Run `fn` when the signal fires (at once if it already has). Returns a token for `remove`.
  @discardableResult
  public func onCancel(_ fn: @escaping @Sendable () -> Void) -> Int {
    let (id, now): (Int, Bool) = lock.withLock {
      if cancelled { return (-1, true) }
      next += 1
      handlers[next] = fn
      return (next, false)
    }
    if now { fn() }
    return id
  }

  public func remove(_ id: Int) {
    _ = lock.withLock { handlers.removeValue(forKey: id) }
  }

  /// Sleep `ms`, returning early (false) when the signal fires or the task is cancelled.
  public func sleep(ms: Int) async -> Bool {
    await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      let once = Once(c)
      let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
        once.resume(!self.isCancelled)
      }
      let id = onCancel {
        timer.cancel()
        once.resume(false)
      }
      Task {
        _ = await timer.value
        self.remove(id)
      }
    }
  }

  final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<Bool, Never>?
    init(_ c: CheckedContinuation<Bool, Never>) { self.c = c }
    func resume(_ v: Bool) {
      let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
        defer { self.c = nil }
        return self.c
      }
      c?.resume(returning: v)
    }
  }
}
