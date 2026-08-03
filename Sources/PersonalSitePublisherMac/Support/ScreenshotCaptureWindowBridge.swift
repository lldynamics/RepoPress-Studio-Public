#if DEBUG || SCREENSHOT_CAPTURE_BUILD
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
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
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
    let targetContentSize = NSSize(
      width: min(WorkbenchLayoutMode.defaultWindowWidth, visibleFrame.width - 40),
      height: min(WorkbenchLayoutMode.defaultWindowHeight, visibleFrame.height - 40)
    )
    let targetSize = window.frameRect(
      forContentRect: NSRect(origin: .zero, size: targetContentSize)
    ).size
    let targetFrame = NSRect(
      x: visibleFrame.midX - targetSize.width / 2,
      y: visibleFrame.midY - targetSize.height / 2,
      width: targetSize.width,
      height: targetSize.height
    ).integral
    window.setFrame(targetFrame, display: true)
  }

  private var shouldCaptureRequestedSurface: Bool {
    return role == .workbench
  }

  @MainActor
  private func captureWindow(_ window: NSWindow, to path: String) {
    guard let frameView = window.contentView?.superview ?? window.contentView else {
      recordCaptureFailure("window content view is unavailable", path: path)
      return
    }
    frameView.displayIfNeeded()
    let bounds = frameView.bounds.integral
    guard !bounds.isEmpty,
          let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
      recordCaptureFailure("could not allocate a window cache bitmap", path: path)
      return
    }
    bitmap.size = bounds.size
    frameView.cacheDisplay(in: bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      recordCaptureFailure("could not encode the window cache as PNG", path: path)
      return
    }
    do {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
      recordCaptureFailure("could not write PNG: \(error.localizedDescription)", path: path)
    }
  }

  private func recordCaptureFailure(_ message: String, path: String) {
    try? message.write(
      toFile: path + ".error.txt",
      atomically: true,
      encoding: .utf8
    )
  }
}
#endif
