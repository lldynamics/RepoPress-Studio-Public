import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PublishReadinessNavigationTests: XCTestCase {
  func testWritingEntryUsesCurrentArticleWhileProjectEntryUsesRepository() {
    XCTAssertEqual(PublishScope.initialScope(for: .writing), .currentArticle)
    XCTAssertEqual(PublishScope.initialScope(for: .sync), .repository)
    XCTAssertEqual(PublishScope.initialScope(for: .siteStarter), .repository)
  }

  func testBodyImageIssuePreservesItsSearchTarget() {
    let issue = PreflightIssue(
      severity: .error, title: "图片未登记", message: "修复图片引用", field: "body",
      category: .unregisteredBodyImage, relatedValue: "/images/example.png"
    )
    XCTAssertEqual(PublishReadinessTarget.preflight(issue), .body(query: "/images/example.png"))
  }

  func testImageIssueKeepsAttachmentIdentityAndUnknownIssueHasUsefulFallback() {
    let id = UUID()
    let issue = ImageWorkbenchIssue(
      severity: .warning, title: "补充 Alt", message: "描述图片", attachmentID: id
    )
    XCTAssertEqual(PublishReadinessTarget.image(issue), .images(attachmentID: id))
    XCTAssertEqual(
      PublishReadinessTarget.preflight(PreflightIssue(severity: .warning, title: "检查", message: "未知字段")),
      .metadata(field: nil)
    )
  }

  func testSEORoutesToActualEditableFieldInsteadOfAlwaysOpeningSEO() {
    let finding = SEOAuditFinding(severity: .warning, title: "摘要", message: "补全摘要", field: "summary")
    XCTAssertEqual(PublishReadinessTarget.seo(finding), .metadata(field: "summary"))
    XCTAssertEqual(PublishMetadataFieldAnchor.id(for: "summary"), "publish-metadata-summary")
    XCTAssertEqual(PublishMetadataFieldAnchor.id(for: "unsupported"), "publish-metadata-title")
    var changed = finding
    changed.field = "body"
    XCTAssertEqual(PublishReadinessTarget.seo(changed), .body(query: nil))
    changed.field = "jsonLD"
    XCTAssertEqual(PublishReadinessTarget.seo(changed), .seo)
    changed.field = "repositoryToken"
    XCTAssertEqual(PublishReadinessTarget.seo(changed), .repository)
  }

  func testRepeatedNavigationRequestsRemainDistinctAndDraftBound() {
    let first = PublishReadinessNavigationRequest(draftID: UUID(), target: .metadata(field: "title"))
    let next = PublishReadinessNavigationRequest(draftID: first.draftID, target: first.target)
    XCTAssertNotEqual(first.id, next.id)
    XCTAssertEqual(first.draftID, next.draftID)
    XCTAssertEqual(first.target.inspectorTab, .metadata)
  }

  func testArticleRepairSessionPreservesTheCurrentPublishScopeAndExactDraft() {
    let draftID = UUID()
    let session = ArticlePublishRepairSession(
      draftID: draftID,
      target: .images(attachmentID: UUID()),
      publishScope: .currentArticle
    )

    XCTAssertEqual(session.draftID, draftID)
    XCTAssertEqual(session.publishScope, .currentArticle)
    XCTAssertEqual(
      ArticlePublishRepairRoutePolicy.route(for: session.target).workspaceSection,
      .writing
    )
  }
}
