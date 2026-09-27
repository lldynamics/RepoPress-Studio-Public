import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownToolbarLayoutTests: XCTestCase {
  func testExpandedFormattingExposesEveryCommandWithoutOverflow() {
    let items = MarkdownToolbarLayout.expandedFormattingItems
    XCTAssertFalse(items.contains(.moreFormatting))
    XCTAssertEqual(items.count, Set(items).count)
    XCTAssertEqual(
      Set(items),
      Set(MarkdownToolbarFormattingItem.allCases).subtracting([.moreFormatting])
    )
    XCTAssertEqual(
      Array(items.prefix(6)), [.headingMenu, .bold, .italic, .listMenu, .link, .image]
    )
  }

  func testPrimaryFormattingItemsHaveAStableCompactOrder() {
    XCTAssertEqual(
      MarkdownToolbarLayout.primaryFormattingItems,
      [.headingMenu, .bold, .italic, .listMenu, .link, .image, .moreFormatting]
    )
  }

  func testMoreFormattingKeepsEverySecondaryCommandReachable() {
    XCTAssertEqual(
      MarkdownToolbarLayout.moreFormattingItems,
      [
        .inlineCode,
        .blockquote,
        .codeBlock,
        .strikethrough,
        .table,
        .horizontalRule,
        .internalLink,
        .snippets,
        .video,
        .chineseTypography,
        .diagnostics,
      ]
    )
    XCTAssertTrue(
      Set(MarkdownToolbarLayout.primaryFormattingItems)
        .isDisjoint(with: MarkdownToolbarLayout.moreFormattingItems)
    )
  }
}
