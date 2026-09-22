import XCTest

@testable import PublishingWorkbenchCore

final class ArticlePublishRepairRoutePolicyTests: XCTestCase {
  func testArticleReadinessTargetsStayInWritingWithTheirAtomicTarget() {
    let targets: [PublishReadinessTarget] = [
      .body(query: "/images/cover.png"),
      .metadata(field: "summary"),
      .images(attachmentID: UUID()),
      .seo,
    ]

    for target in targets {
      let route = ArticlePublishRepairRoutePolicy.route(for: target)
      XCTAssertEqual(route, .article(target))
      XCTAssertEqual(route.workspaceSection, .writing)
      XCTAssertTrue(route.keepsArticleContext)
    }
  }

  func testRepositoryReadinessIsTheOnlyTargetThatRoutesToSite() {
    let route = ArticlePublishRepairRoutePolicy.route(for: .repository)

    XCTAssertEqual(route, .repository)
    XCTAssertEqual(route.workspaceSection, .sync)
    XCTAssertFalse(route.keepsArticleContext)
  }

  func testPreflightRoutesKeepBodyQueryAndRepositoryClassificationAtomic() {
    let bodyIssue = PreflightIssue(
      severity: .error,
      title: "图片未登记",
      message: "修复图片引用",
      field: "body",
      category: .unregisteredBodyImage,
      relatedValue: "/images/cover.png"
    )
    XCTAssertEqual(
      PublishReadinessTarget.preflight(bodyIssue),
      .body(query: "/images/cover.png")
    )

    let repositoryIssue = PreflightIssue(
      severity: .error,
      title: "仓库未配置",
      message: "选择仓库",
      field: "repository"
    )
    XCTAssertEqual(PublishReadinessTarget.preflight(repositoryIssue), .repository)
  }
}
