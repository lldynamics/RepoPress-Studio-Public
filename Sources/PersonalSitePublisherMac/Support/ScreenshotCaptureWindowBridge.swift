#if DEBUG
import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// Makes automated App Store captures deterministic without relying on
/// Accessibility APIs to discover or resize the SwiftUI window.
struct ScreenshotCaptureWindowBridge: NSViewRepresentable {
  enum Role: Equatable {
    case workbench
    case settings
  }

  var role: Role = .workbench

  func makeNSView(context: Context) -> NSView {
    CaptureBridgeView(role: role)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CaptureBridgeView: NSView {
  private let role: ScreenshotCaptureWindowBridge.Role
  private var didConfigureWindow = false

  init(role: ScreenshotCaptureWindowBridge.Role) {
    self.role = role
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard !didConfigureWindow,
          ScreenshotDemoDataService.isEnabledFromEnvironment,
          ProcessInfo.processInfo.environment[
            "PERSONAL_SITE_PUBLISHER_DISABLE_CAPTURE_WINDOW_BRIDGE"
          ] != "1",
          shouldCaptureRequestedSurface,
          let window
    else {
      return
    }
    didConfigureWindow = true
    configureWindow(window)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    if let windowIDPath = ProcessInfo.processInfo.environment[
      "PERSONAL_SITE_PUBLISHER_SCREENSHOT_WINDOW_ID_FILE"
    ], !windowIDPath.isEmpty {
      try? String(window.windowNumber).write(
        toFile: windowIDPath,
        atomically: true,
        encoding: .utf8
      )
    }

    if let capturePath = ProcessInfo.processInfo.environment[
      "PERSONAL_SITE_PUBLISHER_SCREENSHOT_SOURCE_FILE"
    ], !capturePath.isEmpty {
      Task { @MainActor [weak window] in
        try? await Task.sleep(for: .seconds(2))
        guard let window else { return }
        configureWindow(window)
        try? await Task.sleep(for: .milliseconds(500))
        captureWindow(window, to: capturePath)
      }
    }
  }

  @MainActor
  private func configureWindow(_ window: NSWindow) {
    let targetScreen = NSScreen.screens.max { lhs, rhs in
      lhs.backingScaleFactor < rhs.backingScaleFactor
    } ?? window.screen ?? NSScreen.main
    guard let targetScreen else { return }
    let visibleFrame = targetScreen.visibleFrame
    let targetSize = NSSize(
      width: min(1200, visibleFrame.width - 40),
      height: min(800, visibleFrame.height - 40)
    )
    let targetFrame = NSRect(
      x: visibleFrame.midX - targetSize.width / 2,
      y: visibleFrame.midY - targetSize.height / 2,
      width: targetSize.width,
      height: targetSize.height
    ).integral
    window.setFrame(targetFrame, display: true)
  }

  private var shouldCaptureRequestedSurface: Bool {
    if ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .proSettings {
      return role == .settings
    }
    return role == .workbench
  }

  @MainActor
  private func captureWindow(_ window: NSWindow, to path: String) {
    guard let frameView = window.contentView?.superview else { return }
    frameView.displayIfNeeded()
    let contentWidth = window.contentView?.frame.width ?? frameView.bounds.width
    let bounds = NSRect(
      x: frameView.bounds.minX,
      y: frameView.bounds.minY,
      width: min(contentWidth, frameView.bounds.width),
      height: frameView.bounds.height
    ).integral
    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(Int((bounds.width * scale).rounded()), 1),
      pixelsHigh: max(Int((bounds.height * scale).rounded()), 1),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return
    }
    bitmap.size = bounds.size
    frameView.cacheDisplay(in: bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}
#endif
