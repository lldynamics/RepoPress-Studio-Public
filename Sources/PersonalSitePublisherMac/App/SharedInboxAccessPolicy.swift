import Foundation

/// The App Group inbox belongs to the real workspace, even when the app itself
/// has been launched with a temporary home or screenshot persistence directory.
enum SharedInboxAccessPolicy {
  static var isEnabled: Bool {
    #if SCREENSHOT_CAPTURE_BUILD
      let isScreenshotBuild = true
    #else
      let isScreenshotBuild = false
    #endif
    return allowsAccess(
      environment: ProcessInfo.processInfo.environment,
      isScreenshotBuild: isScreenshotBuild,
      isTestProcess: NSClassFromString("XCTestCase") != nil
        || CommandLine.arguments.contains { $0.hasSuffix(".xctest") }
    )
  }

  static func allowsAccess(
    environment: [String: String],
    isScreenshotBuild: Bool,
    isTestProcess: Bool
  ) -> Bool {
    guard !isScreenshotBuild, !isTestProcess else { return false }
    let isolatedRunFlags = [
      "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO",
      "PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST",
      "XCODE_RUNNING_FOR_PREVIEWS",
    ]
    if isolatedRunFlags.contains(where: { key in
      ["1", "true", "yes"].contains(environment[key]?.lowercased() ?? "")
    }) {
      return false
    }
    let testMarkers = [
      "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
      "CFFIXED_USER_HOME",
      "PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT",
      "PERSONAL_SITE_PUBLISHER_SCREENSHOT_KNOWLEDGE_ROOT",
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_PERSISTENCE_ROOT",
    ]
    guard !testMarkers.contains(where: { environment[$0] != nil }) else { return false }
    let fixture = environment["PERSONAL_SITE_PUBLISHER_PERFORMANCE_FIXTURE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return fixture != "markdown-scroll" && fixture != "markdown-rich-scroll"
  }
}
