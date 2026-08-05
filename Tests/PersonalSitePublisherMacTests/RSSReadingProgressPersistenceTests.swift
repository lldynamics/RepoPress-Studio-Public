import Foundation
import XCTest
@testable import PersonalSitePublisherMac

final class RSSReadingProgressPersistenceTests: XCTestCase {
  func testOlderSubmissionCannotOverwriteNewerReadingProgress() async throws {
    let suiteName = "RSSReadingProgressPersistenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let persistence = RSSReadingProgressPersistence(defaults: defaults)

    await persistence.save(
      ["newest": 0.8],
      orderedArticleIDs: ["newest"],
      revision: 2
    )
    await persistence.save(
      ["stale": 0.2],
      orderedArticleIDs: ["stale"],
      revision: 1
    )

    XCTAssertEqual(
      RSSReadingProgressStore.load(defaults: defaults),
      ["newest": 0.8]
    )
    XCTAssertEqual(
      RSSReadingProgressStore.loadOrder(defaults: defaults),
      ["newest"]
    )
  }

  func testNewerSubmissionReplacesEarlierReadingProgress() async throws {
    let suiteName = "RSSReadingProgressPersistenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let persistence = RSSReadingProgressPersistence(defaults: defaults)

    await persistence.save(
      ["article": 0.25],
      orderedArticleIDs: ["article"],
      revision: 10
    )
    await persistence.save(
      ["article": 0.75],
      orderedArticleIDs: ["article"],
      revision: 11
    )

    XCTAssertEqual(
      RSSReadingProgressStore.load(defaults: defaults)["article"],
      0.75
    )
  }
}
