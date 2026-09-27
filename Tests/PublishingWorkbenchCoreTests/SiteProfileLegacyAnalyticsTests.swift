import XCTest

@testable import PublishingWorkbenchCore

final class SiteProfileLegacyAnalyticsTests: XCTestCase {
  func testSavingAnOlderProfilePreservesAnalyticsSettingsWithoutASecret() throws {
    let legacySettings = SiteAnalyticsSettings(
      isEnabled: true,
      provider: .umami,
      baseURL: "https://stats.example.com",
      siteID: "legacy-site-id",
      dateRangeDays: 28
    )
    let legacyProfile = SiteProfile(name: "Existing site", siteAnalytics: legacySettings)

    let saved = try JSONEncoder.workbench.encode(legacyProfile)
    let restored = try JSONDecoder.workbench.decode(SiteProfile.self, from: saved)
    let savedAgain = try JSONEncoder.workbench.encode(restored)

    XCTAssertEqual(restored.siteAnalytics, legacySettings)
    XCTAssertEqual(
      try JSONDecoder.workbench.decode(SiteProfile.self, from: savedAgain).siteAnalytics,
      legacySettings
    )
    XCTAssertFalse(String(decoding: savedAgain, as: UTF8.self).contains("accessToken"))
  }
}
