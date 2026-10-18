import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class PublishCommandActionTests: XCTestCase {
  func testCurrentArticleAndPublishAllStaySeparate() {
    var articleCount = 0
    var allCount = 0
    let action = PublishCommandAction(
      currentArticleID: UUID(),
      publishArticle: { articleCount += 1 },
      publishAll: { allCount += 1 }
    )

    XCTAssertTrue(action.canPublishCurrentArticle)
    action.publishCurrentArticle()
    XCTAssertEqual(articleCount, 1)
    XCTAssertEqual(allCount, 0)
    action.publishAll()
    XCTAssertEqual(articleCount, 1)
    XCTAssertEqual(allCount, 1)
  }

  func testMissingCurrentArticleNeverFallsBackToPublishAll() {
    var invocationCount = 0
    let action = PublishCommandAction(
      publishArticle: { invocationCount += 1 },
      publishAll: { invocationCount += 1 }
    )

    XCTAssertFalse(action.canPublishCurrentArticle)
    action.publishCurrentArticle()
    XCTAssertEqual(invocationCount, 0)
    XCTAssertFalse(
      PublishCommandAction(currentArticleID: UUID(), publishAll: {}).canPublishCurrentArticle)
  }

  func testRunningPublishDisablesBothActions() {
    var invocationCount = 0
    let action = PublishCommandAction(
      currentArticleID: UUID(), isBusy: true,
      publishArticle: { invocationCount += 1 },
      publishAll: { invocationCount += 1 }
    )

    XCTAssertFalse(action.canPublishCurrentArticle)
    XCTAssertFalse(action.canPublishAll)
    action.publishCurrentArticle()
    action.publishAll()
    XCTAssertEqual(invocationCount, 0)
  }
}
