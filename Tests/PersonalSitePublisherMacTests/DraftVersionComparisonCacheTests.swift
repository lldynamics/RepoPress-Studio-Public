import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

private actor ComparisonCacheCounter {
  var count = 0

  func compare(_ previous: ArticleDraft, _ current: ArticleDraft) -> DraftVersionComparison {
    count += 1
    return DraftVersionComparisonService().compare(
      previous: previous, current: current, includeAlignedBodyRows: true)
  }
}

@MainActor
final class DraftVersionComparisonCacheTests: XCTestCase {
  func testFullBodyCacheRetainsRecentPairsAndEvictsLeastRecentlyUsedPair() async {
    let draft = ArticleDraft(siteProfileID: UUID(), title: "文章", bodyMarkdown: "原稿")
    let source = DraftVersionSnapshot(draft: draft, reason: .manual)
    let requests = (0..<9).map { index in
      var target = draft
      target.bodyMarkdown = "修改版 \(index)"
      return DraftVersionComparisonRequest.version(
        sourceVersion: source,
        targetVersion: DraftVersionSnapshot(draft: target, reason: .manual)
      )
    }
    let counter = ComparisonCacheCounter()
    let loader = DraftVersionComparisonLoader { previous, current in
      await counter.compare(previous, current)
    }
    for request in requests.prefix(8) { await loader.load(request) }
    await loader.load(requests[0])
    await loader.load(requests[8])
    await loader.load(requests[0])
    let cachedCount = await counter.count
    XCTAssertEqual(cachedCount, 9)
    await loader.load(requests[1])
    let recomputedCount = await counter.count
    XCTAssertEqual(recomputedCount, 10)
    XCTAssertEqual(
      loader.comparison?.alignedBodyRows.compactMap { $0.current?.text }.joined(separator: "\n"),
      requests[1].current.bodyMarkdown
    )
  }
}
