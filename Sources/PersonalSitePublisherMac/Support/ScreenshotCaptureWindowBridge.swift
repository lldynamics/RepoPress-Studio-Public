import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// Pure policies shared by the capture bridge and responsive accessibility
/// tests. The bridge itself remains excluded from normal Release behavior.
enum ScreenshotCaptureWindowSizingPolicy {
  static let contentWidthEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_CONTENT_WIDTH"
  static let contentHeightEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_CONTENT_HEIGHT"
  static let dynamicTypeSizeEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DYNAMIC_TYPE_SIZE"

  static func clampedContentSize(
    requestedWidth: CGFloat?,
    requestedHeight: CGFloat?,
    visibleFrameSize: CGSize,
    minimumSize: CGSize = CGSize(
      width: WorkbenchLayoutMode.minimumWindowWidth,
      height: WorkbenchLayoutMode.minimumWindowHeight
    ),
    defaultSize: CGSize = CGSize(
      width: WorkbenchLayoutMode.defaultWindowWidth,
      height: WorkbenchLayoutMode.defaultWindowHeight
    ),
    margin: CGFloat = 40
  ) -> CGSize {
    let safeWidth = requestedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? defaultSize.width
    let safeHeight = requestedHeight.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? defaultSize.height
    let maximumWidth = max(minimumSize.width, visibleFrameSize.width - margin)
    let maximumHeight = max(minimumSize.height, visibleFrameSize.height - margin)
    return CGSize(
      width: min(max(safeWidth, minimumSize.width), maximumWidth),
      height: min(max(safeHeight, minimumSize.height), maximumHeight)
    )
  }

  static func contentSizeFromEnvironment(
    environment: [String: String],
    visibleFrameSize: CGSize
  ) -> CGSize {
    clampedContentSize(
      requestedWidth: positiveFiniteCGFloat(environment[contentWidthEnvironmentKey]),
      requestedHeight: positiveFiniteCGFloat(environment[contentHeightEnvironmentKey]),
      visibleFrameSize: visibleFrameSize
    )
  }

  static func dynamicTypeSize(from rawValue: String?) -> DynamicTypeSize? {
    guard let rawValue else { return nil }
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
    switch normalized {
    case "xsmall": return .xSmall
    case "small": return .small
    case "medium": return .medium
    case "large": return .large
    case "xlarge": return .xLarge
    case "xxlarge": return .xxLarge
    case "xxxlarge": return .xxxLarge
    case "accessibility1": return .accessibility1
    case "accessibility2": return .accessibility2
    case "accessibility3": return .accessibility3
    case "accessibility4": return .accessibility4
    case "accessibility5": return .accessibility5
    default: return nil
    }
  }

  private static func positiveFiniteCGFloat(_ rawValue: String?) -> CGFloat? {
    guard let rawValue,
          let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite,
          value > 0
    else {
      return nil
    }
    return CGFloat(value)
  }
}

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
/// Makes automated release captures deterministic without relying on
/// Accessibility APIs to discover or resize the SwiftUI window.
struct ScreenshotCaptureWindowBridge: NSViewRepresentable {
  static let contentWidthEnvironmentKey =
    ScreenshotCaptureWindowSizingPolicy.contentWidthEnvironmentKey
  static let contentHeightEnvironmentKey =
    ScreenshotCaptureWindowSizingPolicy.contentHeightEnvironmentKey
  static let dynamicTypeSizeEnvironmentKey =
    ScreenshotCaptureWindowSizingPolicy.dynamicTypeSizeEnvironmentKey

  enum Role: Equatable {
    case workbench
    case settings
  }

  var role: Role = .workbench

  /// Returns a legal content size for a screenshot or accessibility fixture.
  /// Keeping this pure makes the minimum-window contract testable without an
  /// AppKit window or a running screenshot process.
  static func clampedContentSize(
    requestedWidth: CGFloat?,
    requestedHeight: CGFloat?,
    visibleFrameSize: CGSize,
    minimumSize: CGSize = CGSize(
      width: WorkbenchLayoutMode.minimumWindowWidth,
      height: WorkbenchLayoutMode.minimumWindowHeight
    ),
    defaultSize: CGSize = CGSize(
      width: WorkbenchLayoutMode.defaultWindowWidth,
      height: WorkbenchLayoutMode.defaultWindowHeight
    ),
    margin: CGFloat = 40
  ) -> CGSize {
    ScreenshotCaptureWindowSizingPolicy.clampedContentSize(
      requestedWidth: requestedWidth,
      requestedHeight: requestedHeight,
      visibleFrameSize: visibleFrameSize,
      minimumSize: minimumSize,
      defaultSize: defaultSize,
      margin: margin
    )
  }

  static func contentSizeFromEnvironment(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    visibleFrameSize: CGSize
  ) -> CGSize {
    ScreenshotCaptureWindowSizingPolicy.contentSizeFromEnvironment(
      environment: environment,
      visibleFrameSize: visibleFrameSize
    )
  }

  static func dynamicTypeSize(from rawValue: String?) -> DynamicTypeSize? {
    ScreenshotCaptureWindowSizingPolicy.dynamicTypeSize(from: rawValue)
  }

  static var dynamicTypeSizeOverride: DynamicTypeSize? {
    dynamicTypeSize(
      from: ProcessInfo.processInfo.environment[dynamicTypeSizeEnvironmentKey]
    )
  }

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
    let targetContentSize = ScreenshotCaptureWindowBridge.contentSizeFromEnvironment(
      visibleFrameSize: visibleFrame.size
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
