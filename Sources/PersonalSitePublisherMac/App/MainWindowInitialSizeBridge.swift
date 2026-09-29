import AppKit
import SwiftUI

struct MainWindowOpenActionRegistration: View {
  @Environment(\.openWindow) private var openWindow
  let register: (@escaping () -> Void) -> Void

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        register {
          openWindow(id: "main-workbench")
        }
      }
  }
}

/// Applies the current workspace default once to windows restored from an
/// older build. SwiftUI's `defaultSize` covers new windows, while this tiny
/// bridge migrates an existing restoration record before preserving later
/// user resizing choices.
struct MainWindowInitialSizeBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> MainWindowSizingView {
    MainWindowSizingView()
  }

  func updateNSView(_ nsView: MainWindowSizingView, context: Context) {
  }
}

final class MainWindowSizingView: NSView {
  private static let migrationKey = "didMigrateMainWindowDefaultSizeV2"
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    applyMigrationIfNeeded(to: window)
  }

  private func applyMigrationIfNeeded(to window: NSWindow) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.migrationKey) else { return }
    // Record the migration even when the restored window is already wide. This
    // is what preserves the user's later choice to resize it more narrowly.
    defaults.set(true, forKey: Self.migrationKey)

    guard window.contentLayoutRect.width < WorkbenchLayoutMode.defaultWindowWidth,
      let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
      visibleFrame.width >= WorkbenchLayoutMode.minimumInspectorWorkspaceWidth
    else {
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
