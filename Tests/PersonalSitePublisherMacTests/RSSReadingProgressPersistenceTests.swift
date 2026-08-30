import Foundation
import XCTest
@testable import PersonalSitePublisherMac

final class RSSReadingProgressPersistenceTests: XCTestCase {
  func testOlderSubmissionCannotOverwriteNewerReadingProgress() async throws {
    let suiteName = "RSSReadingProgressPersistenceTests-\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let persistence = RSSReadingProgressPersistence(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
    )

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

    let storedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertEqual(RSSReadingProgressStore.load(defaults: storedDefaults), ["newest": 0.8])
    XCTAssertEqual(RSSReadingProgressStore.loadOrder(defaults: storedDefaults), ["newest"])
  }

  func testNewerSubmissionReplacesEarlierReadingProgress() async throws {
    let suiteName = "RSSReadingProgressPersistenceTests-\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let persistence = RSSReadingProgressPersistence(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
    )

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

    let storedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertEqual(
      RSSReadingProgressStore.load(defaults: storedDefaults)["article"],
      0.75
    )
  }

  func testRecencySnapshotIsOrderedInsidePersistenceBoundary() async throws {
    let suiteName = "RSSReadingProgressRecencyTests-\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let persistence = RSSReadingProgressPersistence(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
    )

    await persistence.save(
      ["older": 0.2, "newer": 0.8, "same-a": 0.4, "same-b": 0.5],
      recencyByArticleID: ["older": 1, "newer": 3, "same-a": 2, "same-b": 2],
      revision: 1
    )

    let storedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertEqual(
      RSSReadingProgressStore.loadOrder(defaults: storedDefaults),
      ["newer", "same-a", "same-b", "older"]
    )
  }
}
