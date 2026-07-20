import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// Applies the wider workspace default once to windows restored from an older,
/// narrower build. SwiftUI's `defaultSize` covers new windows, while this tiny
/// bridge handles the existing restoration record without overriding later
/// user resizing choices.
struct MainWindowInitialSizeBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> MainWindowSizingView {
    MainWindowSizingView()
  }

  func updateNSView(_ nsView: MainWindowSizingView, context: Context) {}
}

final class MainWindowSizingView: NSView {
  private static let migrationKey = "didMigrateMainWindowDefaultSizeV1"
  private var didInspectWindow = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard !didInspectWindow, let window else { return }
    didInspectWindow = true
    applyMigrationIfNeeded(to: window)
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
}
