// Homebot.app's main binary. One window (setup, Home, Shortcuts, Settings) and a menu bar item;
// the gateway runs in this process for as long as the app runs, also with the window closed.
// Quit stops it (DESIGN §20.3). `--render-icon <dir>` draws the icon for the bundle script and
// exits; `--print-placement` prints where this copy runs from and exits; `--dev …` is the
// verification mode (AppEnv).
import AppKit
import HomebotUI
import SwiftUI

let env: AppEnv
do {
  env = try AppEnv.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data("Homebot: \(error)\n".utf8))
  exit(2)
}

if env.printPlacement {
  print(AppPlacement.of(Bundle.main.bundleURL).rawValue)
  exit(0)
}

if let dir = env.renderIcon {
  do {
    try MainActor.assumeIsolated {
      for icon in AppIcon.allCases { try IconRenderer.render(into: dir.appendingPathComponent("\(icon.resource).iconset"), style: icon) }
    }
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("Homebot: cannot render the icon\n".utf8))
    exit(1)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var model: AppModel!
  var quitting = false

  /// The chosen app icon, before the Dock tile shows the window's app (it shows the bundle icon
  /// from launch until here).
  func applicationWillFinishLaunching(_ n: Notification) {
    AppDelegate.model.applyAppIcon()
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    Task { await AppDelegate.model.launch() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// Opened again from Finder, Spotlight or the Dock: the window comes back, also when the menu
  /// bar item is hidden (then this is the only way in).
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { AppDelegate.model.reopen() }
    return true
  }

  /// Quit says what it means for Siri, then stops the gateway before the process ends. Dev runs
  /// quit without asking (scripts stop them).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateNow }
    let model = AppDelegate.model!
    if !model.env.dev {
      let a = NSAlert()
      a.messageText = model.tr.confirmQuit
      a.informativeText = model.tr.confirmQuitBody
      a.addButton(withTitle: model.tr.quit)
      a.addButton(withTitle: model.tr.cancel)
      NSApp.activate()
      guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }
    quitting = true
    Task {
      await model.shutdown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

struct HomebotApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  let model = AppDelegate.model!

  var body: some Scene {
    Window("Homebot", id: "main") {
      RootView()
        .environment(model)
        .onAppear { model.showInDock() }
        .background(WindowOpener(model: model))
        // Closing the window keeps Homebot running in the menu bar, without a Dock icon.
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
    .defaultSize(width: 1060, height: 760)
    // With a menu bar item in the app, SwiftUI otherwise leaves the window closed at launch.
    .defaultLaunchBehavior(.presented)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) { SettingsCommand(model: model) }
    }

    // Hidden in Settings (or Cmd-dragged out of the menu bar): saved the same way.
    MenuBarExtra(isInserted: Binding(get: { model.prefs.showMenuBar }, set: { model.setShowMenuBar($0) })) {
      MenuBarContent().environment(model)
    } label: {
      Image(nsImage: MenuBarIcon.image(dimmed: model.status?.running != true))
    }
    .menuBarExtraStyle(.menu)
  }
}

/// Hands the window's `openWindow` to the model (AppModel.reopen).
struct WindowOpener: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear.onAppear { model.openMainWindow = { openWindow(id: "main") } }
  }
}

MainActor.assumeIsolated {
  do {
    AppDelegate.model = try AppModel(env: env)
  } catch {
    let a = NSAlert()
    let tr = L10n.load(env.uiLang ?? L10n.preferred())
    a.messageText = tr.folderFailed
    a.informativeText = String(describing: error)
    a.runModal()
    exit(1)
  }
}
HomebotApp.main()
