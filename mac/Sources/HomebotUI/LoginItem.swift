// "Open at login" through SMAppService.mainApp (DESIGN §20.3; S0: works for the ad-hoc signed,
// un-notarized app). A copy running translocated (opened straight from a quarantined download)
// would record a random read-only path, so the app refuses and says to move it to Applications
// first (§20.11 B1). Dev runs use an in-memory stand-in and never register anything.
import Foundation
import ServiceManagement

public enum LoginItemState: Sendable, Equatable {
  case off
  case on
  /// Registered, waiting for the user's approval in System Settings › Login Items.
  case needsApproval
}

/// Where this copy of the app runs from (§20.11 B1).
public enum AppPlacement: String, Sendable, Equatable {
  /// /Applications or ~/Applications: where the install guide puts it.
  case applications
  /// Opened straight from a quarantined download: macOS runs it from a random read-only path.
  case translocated
  /// Anywhere else (Downloads, the Desktop, a build folder): works, but a login item would
  /// record this path and lose the app when it is moved.
  case elsewhere

  public static func of(_ bundle: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPlacement {
    if SystemLoginItems.isTranslocated(bundle) { return .translocated }
    let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
    let folders = ["/Applications", userHome.appendingPathComponent("Applications").standardizedFileURL.resolvingSymlinksInPath().path]
    return folders.contains { path.hasPrefix($0 + "/") } ? .applications : .elsewhere
  }
}

public enum LoginItemError: Error, Equatable {
  case translocated
  case failed
}

@MainActor
public protocol LoginItems: AnyObject {
  var state: LoginItemState { get }
  func set(_ on: Bool) throws
  func openSettings()
}

@MainActor
public final class SystemLoginItems: LoginItems {
  let bundleURL: URL

  public init(bundleURL: URL = Bundle.main.bundleURL) {
    self.bundleURL = bundleURL
  }

  public nonisolated static func isTranslocated(_ url: URL) -> Bool {
    url.path.contains("/AppTranslocation/")
  }

  public var state: LoginItemState {
    switch SMAppService.mainApp.status {
    case .enabled: .on
    case .requiresApproval: .needsApproval
    default: .off
    }
  }

  public func set(_ on: Bool) throws {
    if on {
      guard !SystemLoginItems.isTranslocated(bundleURL) else { throw LoginItemError.translocated }
      do { try SMAppService.mainApp.register() } catch { throw LoginItemError.failed }
    } else {
      do { try SMAppService.mainApp.unregister() } catch { throw LoginItemError.failed }
    }
  }

  public func openSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// Dev mode and tests: remembers the switch, registers nothing.
@MainActor
public final class FakeLoginItems: LoginItems {
  public var state: LoginItemState = .off
  public var translocated = false
  public init() {}
  public func set(_ on: Bool) throws {
    if on && translocated { throw LoginItemError.translocated }
    state = on ? .on : .off
  }
  public func openSettings() {}
}
