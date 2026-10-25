// A hard time limit for work that may not honour cancellation (a network transport, a page loop).
// A task group would wait for a child that ignores cancellation; this returns as soon as the time
// is up or the caller is cancelled, cancels the work, and lets it finish on its own.
import Foundation

public enum Deadline {
  public struct Expired: Error {}

  /// `work`'s result, or `Expired` after `ms`, or `CancellationError` when the caller is cancelled.
  public static func run<T: Sendable>(ms: Int, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = Box<T>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        box.start(c)
        let worker = Task { box.finish(await Result(catching: { try await work() })) }
        let timer = Task {
          try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
          box.finish(.failure(Expired()))
        }
        box.track([worker, timer])
      }
    } onCancel: {
      box.finish(.failure(CancellationError()))
    }
  }

  final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var done = false

    func start(_ c: CheckedContinuation<T, Error>) {
      let early: Result<T, Error>? = lock.withLock { done ? .failure(CancellationError()) : { continuation = c; return nil }() }
      if let early { c.resume(with: early) }
    }

    func track(_ t: [Task<Void, Never>]) {
      let cancelNow = lock.withLock { () -> Bool in
        tasks = t
        return done
      }
      if cancelNow { t.forEach { $0.cancel() } }
    }

    /// The first result wins; the others are dropped and every task is cancelled.
    func finish(_ r: Result<T, Error>) {
      let (c, t): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = lock.withLock {
        if done { return (nil, []) }
        done = true
        defer { continuation = nil }
        return (continuation, tasks)
      }
      t.forEach { $0.cancel() }
      c?.resume(with: r)
    }
  }
}

extension Result where Failure == Error {
  init(catching body: () async throws -> Success) async {
    do { self = .success(try await body()) } catch { self = .failure(error) }
  }
}
