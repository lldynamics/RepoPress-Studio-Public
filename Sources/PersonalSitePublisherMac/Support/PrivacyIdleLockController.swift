import AppKit
import PublishingWorkbenchCore

/// Keeps AppKit event monitoring at the edge while the existing workbench
/// store remains the single source of truth for privacy lock state.
@MainActor
final class PrivacyIdleLockController: NSObject {
  private weak var store: WorkbenchStore?
  private var eventMonitor: Any?
  private var evaluationTimer: Timer?
  private var lastActivityAt = Date()
  private var observedLockedState = false

  func start(monitoring store: WorkbenchStore) {
    stop()
    self.store = store
    lastActivityAt = Date()
    observedLockedState = store.isPrivacyLocked

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.activityEventMask) {
      [weak self] event in
      self?.recordActivity()
      return event
    }

    let timer = Timer(
      timeInterval: 1,
      target: self,
      selector: #selector(evaluateInactivity),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
    evaluationTimer = timer
  }

  func stop() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    evaluationTimer?.invalidate()
    evaluationTimer = nil
    store = nil
  }

  private func recordActivity() {
    guard store?.isPrivacyLocked != true else { return }
    lastActivityAt = Date()
  }

  @objc private func evaluateInactivity() {
    guard let store else { return }

    if store.isPrivacyLocked {
      observedLockedState = true
      return
    }

    if observedLockedState {
      observedLockedState = false
      lastActivityAt = Date()
      return
    }

    let settings = store.privacySettings
    guard let interval = settings.inactivityLockInterval else {
      lastActivityAt = Date()
      return
    }
    guard Date().timeIntervalSince(lastActivityAt) >= interval else { return }

    let minutes = settings.effectiveInactivityLockDelayMinutes
    observedLockedState = true
    let reason = String.localizedStringWithFormat(
      String(localized: "连续 %@ 分钟未操作，软件已自动锁定。"),
      String(minutes)
    )
    store.lockPrivacy(reason: reason)
  }

  private static let activityEventMask: NSEvent.EventTypeMask = [
    .keyDown,
    .flagsChanged,
    .leftMouseDown,
    .rightMouseDown,
    .otherMouseDown,
    .mouseMoved,
    .leftMouseDragged,
    .rightMouseDragged,
    .otherMouseDragged,
    .scrollWheel,
    .gesture,
    .magnify,
    .swipe,
    .rotate,
  ]
}
