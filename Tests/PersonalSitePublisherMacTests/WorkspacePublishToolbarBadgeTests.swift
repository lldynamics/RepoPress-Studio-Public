import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspacePublishToolbarBadgeTests: XCTestCase {
  func testPrimaryActionUsesUpdateOnlyForPublishedArticle() {
    XCTAssertEqual(
      WorkspacePreparePublishToolbarButton.primaryActionTitle(isPublished: true), "更新文章")
    XCTAssertEqual(
      WorkspacePreparePublishToolbarButton.primaryActionTitle(isPublished: false), "发布这篇")
  }

  func testPrimaryActionIsDisabledWithoutCurrentArticleOrWhileBusy() {
    let noArticle = PublishCommandAction(currentArticleID: nil, publishAll: {})
    XCTAssertFalse(WorkspacePreparePublishToolbarButton.isPrimaryActionEnabled(noArticle))

    let busy = PublishCommandAction(
      currentArticleID: UUID(), isBusy: true, publishArticle: {}, publishAll: {})
    XCTAssertFalse(WorkspacePreparePublishToolbarButton.isPrimaryActionEnabled(busy))
  }

  func testBlockingStatusShowsTheCompleteChecklistCount() {
    // Content and publish-condition blockers both use the error severity.
    XCTAssertEqual(
      WorkspacePublishToolbarBadge.make(severity: .error, count: 6),
      .blockingCount(6)
    )
  }

  func testWarningOnlyStatusShowsADot() {
    XCTAssertEqual(
      WorkspacePublishToolbarBadge.make(severity: .warning, count: 6),
      .warningDot
    )
  }

  func testReadyAndPendingStatusesShowNoBadge() {
    for severity in [PublishingStatusSeverity.ready, .pending] {
      XCTAssertEqual(
        WorkspacePublishToolbarBadge.make(severity: severity, count: 6),
        .none
      )
    }
  }

  func testOtherNonblockingStatusesShowNoBadge() {
    for severity in [PublishingStatusSeverity.information, .active] {
      XCTAssertEqual(
        WorkspacePublishToolbarBadge.make(severity: severity, count: 6),
        .none
      )
    }
  }

  func testZeroOrMissingCountShowsNoBadge() {
    for severity in [PublishingStatusSeverity.error, .warning, .ready, .pending] {
      for count: Int? in [0, nil] {
        XCTAssertEqual(
          WorkspacePublishToolbarBadge.make(severity: severity, count: count),
          .none
        )
      }
    }
  }

  func testNegativeCountShowsNoBadge() {
    for severity in [PublishingStatusSeverity.error, .warning] {
      XCTAssertEqual(
        WorkspacePublishToolbarBadge.make(severity: severity, count: -1),
        .none
      )
    }
  }
}
