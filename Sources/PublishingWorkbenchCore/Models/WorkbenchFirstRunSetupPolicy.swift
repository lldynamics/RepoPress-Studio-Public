import Foundation

public enum WorkbenchFirstRunSetupPolicy {
  public static func shouldPresent(
    didCompleteSetup: Bool,
    profile: SiteProfile,
    isScreenshotDemo: Bool
  ) -> Bool {
    guard !didCompleteSetup, !isScreenshotDemo else { return false }
    guard profile.purpose.requiresRepositoryReadiness else { return false }
    return profile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }
}
