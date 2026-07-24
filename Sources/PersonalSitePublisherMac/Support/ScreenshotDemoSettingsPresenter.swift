#if DEBUG || SCREENSHOT_CAPTURE_BUILD
import AppKit
import PublishingWorkbenchCore

@MainActor
enum ScreenshotDemoSettingsPresenter {
  static func openSettingsIfNeeded(openSettings: @escaping @MainActor () -> Void) {
    guard ScreenshotDemoDataService.isEnabledFromEnvironment,
          ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .proSettings
    else {
      return
    }

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      openSettings()
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
#endif
