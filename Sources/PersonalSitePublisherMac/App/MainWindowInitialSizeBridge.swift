import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// Applies the wider workspace default once to windows restored from an older,
/// narrower build. SwiftUI's `defaultSize` covers new windows, while this tiny
/// bridge handles the existing restoration record without overriding later
/// user resizing choices.
struct MainWindowInitialSizeBridge: NSViewRepresentable {
  let sourceSession: RepositoryHTMLSourceSession
  let profileProvider: () -> SiteProfile

  func makeNSView(context: Context) -> MainWindowSizingView {
    MainWindowSizingView(
      sourceSession: sourceSession,
      profileProvider: profileProvider
    )
  }

  func updateNSView(_ nsView: MainWindowSizingView, context: Context) {
    nsView.updateCloseProtectionContext(
      sourceSession: sourceSession,
      profileProvider: profileProvider
    )
  }
}

final class MainWindowSizingView: NSView {
  private static let migrationKey = "didMigrateMainWindowDefaultSizeV1"
  private weak var sourceSession: RepositoryHTMLSourceSession?
  private var profileProvider: () -> SiteProfile
  private weak var protectedWindow: NSWindow?
  private var closeProtectionProxy: MainWindowCloseProtectionProxy?

  init(
    sourceSession: RepositoryHTMLSourceSession,
    profileProvider: @escaping () -> SiteProfile
  ) {
    self.sourceSession = sourceSession
    self.profileProvider = profileProvider
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    if let protectedWindow, protectedWindow !== window {
      uninstallCloseProtection()
    }
    applyMigrationIfNeeded(to: window)
    if protectedWindow !== window {
      installCloseProtection(on: window)
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if let protectedWindow, protectedWindow !== newWindow {
      uninstallCloseProtection()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  func updateCloseProtectionContext(
    sourceSession: RepositoryHTMLSourceSession,
    profileProvider: @escaping () -> SiteProfile
  ) {
    self.sourceSession = sourceSession
    self.profileProvider = profileProvider
    closeProtectionProxy?.update(
      sourceSession: sourceSession,
      profileProvider: profileProvider
    )
  }

  private func applyMigrationIfNeeded(to window: NSWindow) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.migrationKey) else { return }
    // Record the migration even when the restored window is already wide. This
    // is what preserves the user's later choice to resize it more narrowly.
    defaults.set(true, forKey: Self.migrationKey)

    guard window.contentLayoutRect.width < WorkbenchLayoutMode.minimumInspectorWorkspaceWidth,
          let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
          visibleFrame.width >= WorkbenchLayoutMode.minimumInspectorWorkspaceWidth else {
      return
    }

    let titlebarHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
    let targetContentSize = NSSize(
      width: min(WorkbenchLayoutMode.defaultWindowWidth, visibleFrame.width),
      height: min(
        WorkbenchLayoutMode.defaultWindowHeight,
        max(visibleFrame.height - titlebarHeight, 0)
      )
    )
    window.setContentSize(targetContentSize)
    window.center()
  }

  private func installCloseProtection(on window: NSWindow) {
    guard closeProtectionProxy == nil else { return }
    let proxy = MainWindowCloseProtectionProxy(
      originalDelegate: window.delegate,
      sourceSession: sourceSession,
      profileProvider: profileProvider
    )
    closeProtectionProxy = proxy
    protectedWindow = window
    window.delegate = proxy
  }

  private func uninstallCloseProtection() {
    if let protectedWindow, protectedWindow.delegate === closeProtectionProxy {
      protectedWindow.delegate = closeProtectionProxy?.originalDelegate
    }
    protectedWindow = nil
    closeProtectionProxy = nil
  }
}

private final class MainWindowCloseProtectionProxy: NSObject, NSWindowDelegate {
  weak var originalDelegate: NSWindowDelegate?
  private weak var sourceSession: RepositoryHTMLSourceSession?
  private var profileProvider: () -> SiteProfile

  init(
    originalDelegate: NSWindowDelegate?,
    sourceSession: RepositoryHTMLSourceSession?,
    profileProvider: @escaping () -> SiteProfile
  ) {
    self.originalDelegate = originalDelegate
    self.sourceSession = sourceSession
    self.profileProvider = profileProvider
  }

  func update(
    sourceSession: RepositoryHTMLSourceSession,
    profileProvider: @escaping () -> SiteProfile
  ) {
    self.sourceSession = sourceSession
    self.profileProvider = profileProvider
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let sourceSession, sourceSession.hasUnsavedChanges else {
      return originalDelegate?.windowShouldClose?(sender) ?? true
    }
    guard !sourceSession.isSaving else {
      NSSound.beep()
      return false
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "HTML 源文件尚未保存")
    alert.informativeText = String(localized: "保存后关闭可保留源码更改；也可以返回编辑器继续处理。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "保存并关闭"))
    alert.addButton(withTitle: String(localized: "继续编辑")).keyEquivalent = "\u{1b}"
    alert.addButton(withTitle: String(localized: "不保存并关闭"))

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      guard sourceSession.saveSynchronously(profile: profileProvider()) else {
        let failureAlert = NSAlert()
        failureAlert.messageText = String(localized: "未能保存 HTML 源文件")
        failureAlert.informativeText = sourceSession.errorMessage
          ?? String(localized: "请返回编辑器检查文件权限或外部修改冲突。")
        failureAlert.alertStyle = .warning
        failureAlert.addButton(withTitle: String(localized: "继续编辑")).keyEquivalent = "\u{1b}"
        failureAlert.runModal()
        return false
      }
      return originalDelegate?.windowShouldClose?(sender) ?? true
    case .alertSecondButtonReturn:
      return false
    case .alertThirdButtonReturn:
      return originalDelegate?.windowShouldClose?(sender) ?? true
    default:
      return false
    }
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector)
      || originalDelegate?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if originalDelegate?.responds(to: selector) == true {
      return originalDelegate
    }
    return super.forwardingTarget(for: selector)
  }
}
