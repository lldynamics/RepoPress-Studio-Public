import XCTest
@testable import PublishingWorkbenchCore

final class PreflightIssueStructuredMetadataTests: XCTestCase {
  func testStructuredMetadataRoundTripsThroughCodable() throws {
    let issue = PreflightIssue(
      severity: .warning,
      title: "Localized diagnostic",
      message: "Localized detail",
      field: "body",
      category: .unregisteredBodyImage,
      relatedValue: "/images/diagram.png"
    )

    let data = try JSONEncoder().encode(issue)
    let decoded = try JSONDecoder().decode(PreflightIssue.self, from: data)

    XCTAssertEqual(decoded, issue)
    XCTAssertEqual(decoded.structuredField, .body)
  }

  func testLegacyIssueWithoutCategoryOrRelatedValueStillDecodes() throws {
    let issue = PreflightIssue(
      severity: .warning,
      title: "疑似密钥泄露",
      message: "Legacy detail",
      field: "body",
      category: .publicRisk,
      relatedValue: "/images/legacy.png"
    )
    let encoded = try JSONEncoder().encode(issue)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "category")
    object.removeValue(forKey: "relatedValue")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PreflightIssue.self, from: legacyData)

    XCTAssertEqual(decoded.field, "body")
    XCTAssertEqual(decoded.structuredField, .body)
    XCTAssertNil(decoded.category)
    XCTAssertNil(decoded.relatedValue)
    XCTAssertFalse(decoded.isPublicRiskIssue)
  }

  func testPublicRiskClassificationUsesCategoryInsteadOfLocalizedTitle() {
    let categorized = PreflightIssue(
      severity: .error,
      title: "Arbitrary localized copy",
      message: "Arbitrary localized detail",
      category: .publicRisk
    )
    let titleOnly = PreflightIssue(
      severity: .error,
      title: "疑似泄露私钥公开风险",
      message: "Legacy localized detail"
    )

    XCTAssertTrue(categorized.isPublicRiskIssue)
    XCTAssertFalse(titleOnly.isPublicRiskIssue)
  }

  func testPreflightProducesStructuredLocationForUnregisteredBodyImage() throws {
    let profile = SiteProfile.defaultProfile
    let missingImagePath = "/images/diagram.png"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Structured issue",
      slug: "structured-issue",
      bodyMarkdown: "This article body is long enough for preflight. ![Diagram](\(missingImagePath))"
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )
    let issue = try XCTUnwrap(issues.first { $0.category == .unregisteredBodyImage })

    XCTAssertEqual(issue.field, "body")
    XCTAssertEqual(issue.structuredField, .body)
    XCTAssertEqual(issue.relatedValue, missingImagePath)
  }
}
