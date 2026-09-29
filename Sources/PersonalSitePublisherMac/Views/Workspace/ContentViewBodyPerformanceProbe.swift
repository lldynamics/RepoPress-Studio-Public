import Foundation
import OSLog

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  enum ContentViewBodyPerformanceProbe {
    private static let isEnabled =
      ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_CONTENT_VIEW_BODY_PROBE"] == "1"
    private static let signposter = OSSignposter(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "SwiftUIBody"
    )

    static func record() {
      guard isEnabled else { return }
      signposter.emitEvent("ContentView.body")
    }
  }
#endif
