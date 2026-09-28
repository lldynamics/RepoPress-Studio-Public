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
    XCTAssertNil(decoded.code)
    XCTAssertFalse(decoded.isPublicRiskIssue)
  }

  func testIssueCodeRoundTripsAndLegacyPayloadWithoutCodeDecodes() throws {
    let issue = PreflightIssue(
      severity: .warning, title: "Remote Same-Path Changes", message: "Review remote diff",
      field: "repository", code: .remoteSamePathChanges)
    let encoded = try JSONEncoder().encode(issue)
    XCTAssertEqual(
      try JSONDecoder().decode(PreflightIssue.self, from: encoded).code,
      .remoteSamePathChanges)

    var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyObject.removeValue(forKey: "code")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    XCTAssertNil(try JSONDecoder().decode(PreflightIssue.self, from: legacyData).code)
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

  func testRemoteFreshnessClassificationUsesIssueCode() throws {
    let service = RemotePublishRiskService()
    let unknown = try XCTUnwrap(
      service.issues(
        for: .init(state: .unknown), includeUnknownState: true
      ).first)
    let conflict = try XCTUnwrap(
      service.issues(
        for: .init(state: .conflict, conflictPaths: ["post.md"])
      ).first)

    XCTAssertEqual(unknown.code, .remoteStatusUnconfirmed)
    XCTAssertEqual(conflict.code, .remoteSamePathChanges)
    XCTAssertTrue(unknown.isDeferredRemoteIssue)
    XCTAssertTrue(conflict.isDeferredRemoteIssue)
    XCTAssertFalse(
      PreflightIssue(
        severity: .error, title: conflict.title, message: "Other cause", field: "repository"
      ).isDeferredRemoteIssue)
  }

  func testPreflightProducesStructuredLocationForUnregisteredBodyImage() throws {
    let profile = SiteProfile.defaultProfile
    let missingImagePath = "/images/diagram.png"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Structured issue",
      slug: "structured-issue",
      bodyMarkdown:
        "This article body is long enough for preflight. ![Diagram](\(missingImagePath))"
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
