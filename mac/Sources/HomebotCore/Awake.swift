// Keeping the Mac awake while the gateway serves (DESIGN §20.3, §20.11 S4): an IOPMAssertion of
// type PreventUserIdleSystemSleep, plus a ProcessInfo activity so App Nap never stalls the
// listener. Idle sleep only: closing the lid, the Apple menu and low battery still sleep the Mac,
// and the display may sleep. The app owns one instance and switches it with its setting.
import Foundation
import IOKit.pwr_mgt

public final class AwakeService: @unchecked Sendable {
  public static let reason = "Homebot answers Siri on this Mac"

  private let lock = NSLock()
  private var assertion: IOPMAssertionID = 0
  private var activity: NSObjectProtocol?

  public init() {}

  public var isHeld: Bool { lock.withLock { assertion != 0 } }

  /// The assertion id, for checks against `IOPMCopyAssertionsByProcess` (0 when not held).
  public var assertionID: UInt32 { lock.withLock { assertion } }

  /// Hold both (idempotent). False if the power assertion was refused; the activity is held anyway.
  @discardableResult
  public func hold() -> Bool {
    lock.withLock {
      if activity == nil {
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: AwakeService.reason)
      }
      if assertion != 0 { return true }
      var id: IOPMAssertionID = 0
      let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), AwakeService.reason as CFString, &id)
      guard r == kIOReturnSuccess else { return false }
      assertion = id
      return true
    }
  }

  public func release() {
    lock.withLock {
      if assertion != 0 {
        IOPMAssertionRelease(assertion)
        assertion = 0
      }
      if let a = activity {
        ProcessInfo.processInfo.endActivity(a)
        activity = nil
      }
    }
  }

  deinit { release() }
}
