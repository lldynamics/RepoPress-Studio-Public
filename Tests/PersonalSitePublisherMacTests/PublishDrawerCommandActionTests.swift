import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class PublishDrawerCommandActionTests: XCTestCase {
  func testCurrentArticleAndRepositoryActionsStaySeparate() {
    var articlePreparationCount = 0
    var repositoryOpenCount = 0
    let action = PublishDrawerCommandAction(
      currentArticleID: UUID(),
      prepareCurrentArticle: { articlePreparationCount += 1 },
      open: { _ in repositoryOpenCount += 1 }
    )

    XCTAssertTrue(action.canPrepareCurrentArticle)
    action.openCurrentArticle()
    XCTAssertEqual(articlePreparationCount, 1)
    XCTAssertEqual(repositoryOpenCount, 0)
    action.open(nil)
    XCTAssertEqual(articlePreparationCount, 1)
    XCTAssertEqual(repositoryOpenCount, 1)
  }

  func testMissingCurrentArticleNeverFallsBackToRepositoryPublish() {
    var invocationCount = 0
    let action = PublishDrawerCommandAction(
      prepareCurrentArticle: { invocationCount += 1 },
      open: { _ in invocationCount += 1 }
    )

    XCTAssertFalse(action.canPrepareCurrentArticle)
    action.openCurrentArticle()
    XCTAssertEqual(invocationCount, 0)
  }

  func testMissingArticleHandlerIsDisabledEvenWhenAnIDExists() {
    let action = PublishDrawerCommandAction(currentArticleID: UUID(), open: { _ in })
    XCTAssertFalse(action.canPrepareCurrentArticle)
  }
}
