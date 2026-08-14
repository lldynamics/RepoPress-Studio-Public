import XCTest

@testable import PublishingWorkbenchCore

final class SiteProfileAutomationPreferenceTests: XCTestCase {
  func testNewProfileAutomaticallyImportsNewRepositoryArticles() {
    let profile = SiteProfile(name: "测试站点")

    XCTAssertTrue(profile.resolvedAutomaticallyImportsNewRepositoryArticles)
    XCTAssertEqual(profile.automaticallyImportsNewRepositoryArticles, true)
  }

  func testLegacyProfileWithoutPreferencePreservesEnabledBehavior() throws {
    let encoded = try JSONEncoder.workbench.encode(SiteProfile(name: "旧站点"))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "automaticallyImportsNewRepositoryArticles")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder.workbench.decode(SiteProfile.self, from: legacyData)

    XCTAssertNil(decoded.automaticallyImportsNewRepositoryArticles)
    XCTAssertTrue(decoded.resolvedAutomaticallyImportsNewRepositoryArticles)
  }

  func testExplicitlyDisabledPreferenceSurvivesRoundTrip() throws {
    var profile = SiteProfile(name: "安静站点")
    profile.resolvedAutomaticallyImportsNewRepositoryArticles = false

    let encoded = try JSONEncoder.workbench.encode(profile)
    let decoded = try JSONDecoder.workbench.decode(SiteProfile.self, from: encoded)

    XCTAssertEqual(decoded.automaticallyImportsNewRepositoryArticles, false)
    XCTAssertFalse(decoded.resolvedAutomaticallyImportsNewRepositoryArticles)
  }
}
