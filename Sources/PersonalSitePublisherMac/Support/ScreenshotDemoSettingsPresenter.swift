#if DEBUG
import AppKit
import PublishingWorkbenchCore

enum ScreenshotDemoSettingsPresenter {
  static func openSettingsIfNeeded() {
    guard ScreenshotDemoDataService.isEnabledFromEnvironment,
          ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .proSettings
    else {
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }
}
#endif
