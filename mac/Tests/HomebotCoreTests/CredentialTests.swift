// The credential rules of DESIGN §20.4 (replacing test/tokens-credentials.test.ts's credential
// part: environment variables and detection of other tools' logins are gone by design). Every key here is a
// synthetic test value.
import Foundation
import Testing

@testable import HomebotCore

@Suite("Credentials (DESIGN §20.4)")
struct CredentialTests {
  struct Env {
    let dir: URL
    let creds: Credentials
    var login: URL { creds.loginFile }

    init() throws {
      dir = try tmpDir()
      creds = Credentials(keyFile: dir.appendingPathComponent("support/api-key"), userHome: dir.appendingPathComponent("home"))
    }

    func writeLogin(_ obj: [String: Any]) throws {
      try FileManager.default.createDirectory(at: login.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: obj).write(to: login)
    }
  }

  @Test("order: the saved key, then the BDK login, then nothing")
  func order() throws {
    let e = try Env()
    #expect(try e.creds.resolve() == nil)
    #expect(e.creds.loginStatus == .none)
    try e.writeLogin(["apiKey": "login-key", "backendUrl": "https://api.cursor.com"])
    #expect(try e.creds.resolve() == Credential(key: "login-key", source: .bdkLogin))
    try e.creds.save(key: "  saved-key \n")
    #expect(try e.creds.resolve() == Credential(key: "saved-key", source: .saved))
    try e.creds.removeSaved()
    #expect(try e.creds.resolve()?.source == .bdkLogin, "the detected login applies again")
    #expect(CredentialSource.bdkLogin.rawValue == "bdk-login")
  }

  @Test("the saved key is one 0600 file in a 0700 directory, holding the key only")
  func savedFile() throws {
    let e = try Env()
    try e.creds.save(key: "k-123")
    #expect(modeOf(e.creds.keyFile) == 0o600)
    #expect(modeOf(e.creds.keyFile.deletingLastPathComponent()) == 0o700)
    #expect(try String(contentsOf: e.creds.keyFile, encoding: .utf8) == "k-123\n")
    #expect(throws: FileUtil.FileError.self) { try e.creds.save(key: "   ") }
    #expect(throws: FileUtil.FileError.self) { try e.creds.save(key: "a\nb") }
  }

  @Test("the BDK login is used only for Cursor's backend", arguments: [
    ("https://api.cursor.com", true), ("https://api.cursor.com/", true),
    ("http://api.cursor.com", false), ("https://api.cursor.com:443", false), ("https://API.CURSOR.COM", false),
    ("https://api.cursor.com.evil.example", false), ("https://user@api.cursor.com", false),
    ("https://api.cursor.com/v0", false), ("https://api.cursor.com?x=1", false), ("https://api.cursor.com#f", false),
    ("https://staging.cursor.com", false), ("", false),
  ])
  func backend(url: String, ok: Bool) throws {
    #expect(Credentials.isCursorBackend(url) == ok, "\(url)")
    let e = try Env()
    try e.writeLogin(["apiKey": "k", "backendUrl": url])
    #expect(e.creds.loginStatus == (ok ? .usable : .otherBackend), "\(url)")
    #expect((try e.creds.resolve() != nil) == ok)
  }

  @Test("a missing backendUrl is another backend; bad files are unreadable, never used")
  func badLogins() throws {
    let e = try Env()
    try e.writeLogin(["apiKey": "k"])
    #expect(e.creds.loginStatus == .otherBackend)
    try e.writeLogin(["apiKey": "", "backendUrl": "https://api.cursor.com"])
    #expect(e.creds.loginStatus == .unreadable)
    try e.writeLogin(["apiKey": 5, "backendUrl": "https://api.cursor.com"])
    #expect(e.creds.loginStatus == .unreadable)
    try Data("{not json dummy-secret".utf8).write(to: e.login)
    #expect(e.creds.loginStatus == .unreadable)
    #expect(try e.creds.resolve() == nil)
  }

  @Test("a symlinked login file is not followed")
  func symlink() throws {
    let e = try Env()
    let real = e.dir.appendingPathComponent("elsewhere.json")
    try JSONSerialization.data(withJSONObject: ["apiKey": "k", "backendUrl": "https://api.cursor.com"]).write(to: real)
    try FileManager.default.createDirectory(at: e.login.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: e.login, withDestinationURL: real)
    #expect(e.creds.loginStatus == .unreadable)
    #expect(try e.creds.resolve() == nil)
  }

  @Test("a FIFO at the login path is refused without blocking")
  func fifo() throws {
    let e = try Env()
    try FileManager.default.createDirectory(at: e.login.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(mkfifo(e.login.path, 0o600) == 0)
    #expect(e.creds.loginStatus == .unreadable)
  }

  @Test("no environment variable is read")
  func noEnv() throws {
    let e = try Env()
    setenv("CURSOR_API_KEY", "env-key-should-be-ignored", 1)
    defer { unsetenv("CURSOR_API_KEY") }
    #expect(try e.creds.resolve() == nil)
  }

  @Test("the accepted state belongs to one generation; a stale check is ignored")
  func generation() async throws {
    let status = CredentialStatus()
    let g1 = await status.observe(Credential(key: "k1", source: .saved))
    #expect(await status.state == .unchecked)
    #expect(await status.observe(Credential(key: "k1", source: .saved)) == g1, "same credential, same generation")
    let g2 = await status.observe(Credential(key: "k2", source: .saved))
    #expect(g2 != g1)
    #expect(await status.record(generation: g1, accepted: true) == false, "a slow check of the old key is ignored")
    #expect(await status.state == .unchecked)
    #expect(await status.record(generation: g2, accepted: false))
    #expect(await status.state == .rejected)
    _ = await status.observe(Credential(key: "k2", source: .bdkLogin))
    #expect(await status.state == .unchecked, "a source change resets it")
    #expect(await status.source == .bdkLogin)
    let g4 = await status.observe(nil)
    #expect(await status.record(generation: g4, accepted: true) == false, "no credential, nothing to accept")
  }

  @Test("a background check never replaces a result that arrived while it was out")
  func lateBackgroundCheck() async throws {
    let status = CredentialStatus()
    let g = await status.observe(Credential(key: "k1", source: .saved))
    // A Siri request is refused while the launch check is still out; the check then succeeds.
    #expect(await status.record(generation: g, accepted: false))
    #expect(await status.record(generation: g, accepted: true, onlyIfUnchecked: true) == false)
    #expect(await status.state == .rejected)
    #expect(await status.record(generation: g, accepted: true), "an explicit check still records")
    #expect(await status.state == .ok)
  }
}
