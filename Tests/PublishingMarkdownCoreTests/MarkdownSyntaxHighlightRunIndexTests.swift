import Foundation
@testable import PublishingMarkdownCore
import XCTest

final class MarkdownSyntaxHighlightRunIndexTests: XCTestCase {
  func testViewportQueryFindsLongOuterRunAndClipsResults() {
    let index = MarkdownSyntaxHighlightRunIndex(runs: [
      MarkdownSyntaxHighlightRun(
        style: .codeBlock,
        range: NSRange(location: 10, length: 1_000)
      ),
      MarkdownSyntaxHighlightRun(
        style: .bold,
        range: NSRange(location: 40, length: 8)
      ),
      MarkdownSyntaxHighlightRun(
        style: .link,
        range: NSRange(location: 500, length: 20)
      ),
    ])

    XCTAssertEqual(
      index.runs(
        intersecting: NSRange(location: 490, length: 20),
        clippingToIntersection: true
      ),
      [
        MarkdownSyntaxHighlightRun(
          style: .codeBlock,
          range: NSRange(location: 490, length: 20)
        ),
        MarkdownSyntaxHighlightRun(
          style: .link,
          range: NSRange(location: 500, length: 10)
        ),
      ]
    )
  }

  func testViewportQueryPreservesOriginalStyleApplicationOrder() {
    let runs = [
      MarkdownSyntaxHighlightRun(style: .heading1, range: NSRange(location: 20, length: 30)),
      MarkdownSyntaxHighlightRun(style: .link, range: NSRange(location: 30, length: 8)),
      MarkdownSyntaxHighlightRun(style: .bold, range: NSRange(location: 22, length: 10)),
    ]
    let index = MarkdownSyntaxHighlightRunIndex(runs: runs)

    XCTAssertEqual(
      index.runs(
        intersecting: NSRange(location: 25, length: 10),
        clippingToIntersection: false
      ),
      runs
    )
  }
}
