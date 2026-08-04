import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSFeedSidebarCountsTests: XCTestCase {
  func testBuildsAllSidebarCountsInOneSnapshot() {
    let firstFeedID = UUID()
    let secondFeedID = UUID()
    let articles = [
      RSSArticleHeader(
        id: "first-unread",
        feedID: firstFeedID,
        title: "First",
        isStarred: true
      ),
      RSSArticleHeader(
        id: "first-read",
        feedID: firstFeedID,
        title: "Second",
        readAt: Date(),
        isStarred: true
      ),
      RSSArticleHeader(
        id: "second-unread",
        feedID: secondFeedID,
        title: "Third"
      ),
    ]

    let counts = RSSFeedSidebarCounts(articles: articles)

    XCTAssertEqual(counts.unreadCount, 2)
    XCTAssertEqual(counts.starredCount, 2)
    XCTAssertEqual(counts.unreadCount(for: firstFeedID), 1)
    XCTAssertEqual(counts.unreadCount(for: secondFeedID), 1)
    XCTAssertEqual(counts.unreadCount(for: UUID()), 0)
  }

  func testFeedLookupKeepsFirstDuplicateWithoutCrashing() {
    let feedID = UUID()
    let first = RSSFeed(
      id: feedID,
      title: "First",
      url: URL(fileURLWithPath: "/first.xml")
    )
    let duplicate = RSSFeed(
      id: feedID,
      title: "Duplicate",
      url: URL(fileURLWithPath: "/duplicate.xml")
    )

    let lookup = RSSFeedLookup(feeds: [first, duplicate])

    XCTAssertEqual(lookup[feedID]?.title, "First")
  }

  func testFeedGroupsMoveRecoveredFeedsToRegularList() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let failing = RSSFeed(
      title: "需要处理",
      url: try XCTUnwrap(URL(string: "https://example.com/failing.xml")),
      lastError: "网络错误"
    )
    let healthy = RSSFeed(
      title: "正常订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/healthy.xml")),
      lastUpdatedAt: now
    )

    let groups = RSSFeedSidebarFeedGroups(feeds: [failing, healthy], now: now)

    XCTAssertEqual(groups.needsAttention.map(\.id), [failing.id])
    XCTAssertEqual(groups.regular.map(\.id), [healthy.id])

    var recovered = failing
    recovered.lastError = nil
    recovered.lastIssue = nil
    recovered.lastUpdatedAt = now
    let recoveredGroups = RSSFeedSidebarFeedGroups(feeds: [recovered, healthy], now: now)

    XCTAssertTrue(recoveredGroups.needsAttention.isEmpty)
    XCTAssertEqual(recoveredGroups.regular.map(\.id), [recovered.id, healthy.id])
  }
}
