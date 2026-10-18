import XCTest

@testable import PublishingWorkbenchCore

final class SiteProfileLegacyAnalyticsTests: XCTestCase {
  func testProfileSavedWithRetiredAnalyticsSettingsStillDecodesAndDropsThem() throws {
    let encoded = try JSONEncoder.workbench.encode(SiteProfile(name: "Existing site"))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["siteAnalytics"] = [
      "isEnabled": true,
      "provider": "umami",
      "baseURL": "https://stats.example.com",
      "siteID": "legacy-site-id",
      "dateRangeDays": 28,
    ]
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let restored = try JSONDecoder.workbench.decode(SiteProfile.self, from: legacyData)
    let savedAgain = try JSONEncoder.workbench.encode(restored)

    XCTAssertEqual(restored.name, "Existing site")
    XCTAssertFalse(String(decoding: savedAgain, as: UTF8.self).contains("siteAnalytics"))
  }
}
