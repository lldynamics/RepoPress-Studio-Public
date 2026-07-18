import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownPreviewRenderCacheTests: XCTestCase {
  func testReturnsInsertedSnapshotWithoutGrowingForSameKey() {
    var cache = MarkdownPreviewRenderCache<String, String>(capacity: 2)

    cache.insert("first", for: "article")
    cache.insert("updated", for: "article")

    XCTAssertEqual(cache.snapshot(for: "article"), "updated")
    XCTAssertEqual(cache.count, 1)
  }

  func testEvictsLeastRecentlyUsedSnapshot() {
    var cache = MarkdownPreviewRenderCache<String, Int>(capacity: 2)
    cache.insert(1, for: "first")
    cache.insert(2, for: "second")

    XCTAssertEqual(cache.snapshot(for: "first"), 1)
    cache.insert(3, for: "third")

    XCTAssertNil(cache.snapshot(for: "second"))
    XCTAssertEqual(cache.snapshot(for: "first"), 1)
    XCTAssertEqual(cache.snapshot(for: "third"), 3)
  }

  func testCapacityIsAlwaysAtLeastOneAndCacheCanBeCleared() {
    var cache = MarkdownPreviewRenderCache<String, Int>(capacity: 0)
    cache.insert(1, for: "first")
    cache.insert(2, for: "second")

    XCTAssertEqual(cache.capacity, 1)
    XCTAssertNil(cache.snapshot(for: "first"))
    XCTAssertEqual(cache.snapshot(for: "second"), 2)

    cache.removeAll()
    XCTAssertEqual(cache.count, 0)
  }
}
