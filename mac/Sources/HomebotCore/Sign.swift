// Wrapper around macOS `shortcuts sign` (DESIGN D7, §7.5). Apple's signing service is often slow
// or failing (spike: minutes of 502/503/504), so retry with backoff and alternate modes;
// `people-who-know-me` sometimes worked when `anyone` failed. Called only after the user agreed
// to signing (settings.appleSigning). Tests use a fake signer only. Ported from src/shortcut/sign.ts.
import Foundation

public enum SignMode: String, Sendable, CaseIterable {
  case peopleWhoKnowMe = "people-who-know-me"
  case anyone
}

public struct SignError: Error, CustomStringConvertible, Equatable {
  public let description: String
}

/// A failed command, with its exit status (never its output: it could name paths or tokens).
public struct CommandFailed: Error, Equatable {
  public let status: Int32
}

public typealias RunCommand = @Sendable (_ cmd: String, _ args: [String]) async throws -> Void

public enum Signer {
  public static let backoffMs = [2000, 4000, 8000, 16000, 30000]

  /// The signer writes the token-bearing output itself, with the process umask. A fixed /bin/sh
  /// launcher sets 077 and then execs the signer, so the output is 0600 from creation, also if
  /// signing is interrupted. The script is a constant; the signer and all paths are separate
  /// arguments ("$0" "$@"), never interpolated into it.
  public static let umaskLauncher = ["-c", "umask 077 && exec \"$0\" \"$@\""]

  /// Runs a command with an argument array (no shell string), discarding its output.
  public static let runProcess: RunCommand = { cmd, args in
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      p.terminationHandler = { proc in
        if proc.terminationStatus == 0 { c.resume() } else { c.resume(throwing: CommandFailed(status: proc.terminationStatus)) }
      }
      do { try p.run() } catch { c.resume(throwing: error) }
    }
  }

  public static func sign(
    input: String, output: String, attempts: Int = backoffMs.count, command: String = "/usr/bin/shortcuts",
    run: RunCommand = runProcess,
    wait: @Sendable (Int) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
    onAttempt: (@Sendable (Int, SignMode) -> Void)? = nil
  ) async throws -> (mode: SignMode, attempts: Int) {
    var last: Error?
    for i in 0..<attempts {
      let mode = SignMode.allCases[i % SignMode.allCases.count]
      onAttempt?(i + 1, mode)
      do {
        try await run("/bin/sh", umaskLauncher + [command, "sign", "--mode", mode.rawValue, "--input", input, "--output", output])
        return (mode, i + 1)
      } catch {
        last = error
        if i + 1 < attempts { try await wait(backoffMs[min(i, backoffMs.count - 1)]) }
      }
    }
    let code = (last as? CommandFailed).map { String($0.status) } ?? "unknown"
    throw SignError(description: "signing failed after \(attempts) attempts (last exit: \(code)); Apple's signing service may be down, try again later")
  }
}
