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

/// Expands restored windows once per window lifetime so both sidebars can
/// start open. Later user resizing survives representable recreation.
struct MainWindowInitialSizeBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> MainWindowSizingView {
    MainWindowSizingView()
  }

  func updateNSView(_ nsView: MainWindowSizingView, context: Context) {
  }
}

final class MainWindowSizingView: NSView {
  private static let initiallySizedWindows = NSHashTable<NSWindow>.weakObjects()
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    applyInitialSizeIfNeeded(to: window)
  }

  private func applyInitialSizeIfNeeded(to window: NSWindow) {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      // CaptureBridgeView owns the explicit fixture size; a default-size
      // adjustment would race it and can widen a minimum-size UI test.
      guard !ScreenshotCaptureWindowBridge.managesWorkbenchWindowSize else { return }
    #endif
    guard !Self.initiallySizedWindows.contains(window) else { return }
    // Weak window identity also survives SwiftUI recreating this bridge,
    // without retaining closed windows or carrying state across launches.
    Self.initiallySizedWindows.add(window)

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
