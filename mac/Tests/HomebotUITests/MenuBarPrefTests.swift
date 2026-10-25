// Settings › Show in menu bar: on by default, saved in app.json, back on after Reset everything;
// the footer says where Homebot goes when the window closes in both states.
import Foundation
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct MenuBarPrefTests {
  @Test func onByDefaultAlsoForOlderPrefs() throws {
    #expect(AppPrefs().showMenuBar)
    let old = try JSONDecoder().decode(AppPrefs.self, from: Data(#"{"keepAwake":false}"#.utf8))
    #expect(old.showMenuBar, "a file from before the setting keeps the item")
  }

  @Test func savedTheCaptionFollowsAndResetRestoresIt() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    #expect(m.windowNote == m.tr.windowNote)
    // SwiftUI writes the binding back with the same value: nothing is saved (no update loop).
    let file = AppPrefs.file(m.home)
    try FileManager.default.removeItem(at: file)
    m.setShowMenuBar(true)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    m.setShowMenuBar(false)
    #expect(!m.prefs.showMenuBar)
    #expect(!AppPrefs.load(m.home).showMenuBar, "saved")
    #expect(m.windowNote == m.tr.windowNoteHidden)
    #expect(m.windowNote != m.tr.windowNote, "no mention of a menu bar item that isn't there")

    #expect(await m.resetEverything(removeKey: false))
    #expect(m.prefs.showMenuBar && m.windowNote == m.tr.windowNote)
  }

  @Test func reopeningOpensTheWindow() async throws {
    let m = try await makeModel(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    var opened = 0
    m.openMainWindow = { opened += 1 }
    m.setShowMenuBar(false)
    m.reopen()
    #expect(opened == 1)
  }
}
