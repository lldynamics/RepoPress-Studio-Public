import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownToolbarLayoutTests: XCTestCase {
  func testPrimaryFormattingItemsHaveAStableOrder() {
    XCTAssertEqual(
      MarkdownToolbarLayout.primaryFormattingItems,
      [.headingMenu, .bold, .italic, .listMenu, .link, .image, .insertMenu, .formatMenu]
    )
  }

  func testGroupedMenusKeepEverySecondaryCommandReachable() {
    XCTAssertEqual(
      MarkdownToolbarLayout.insertMenuItems,
      [.codeBlock, .table, .horizontalRule, .video, .internalLink, .snippets]
    )
    XCTAssertEqual(
      MarkdownToolbarLayout.formatMenuItems,
      [.inlineCode, .blockquote, .strikethrough, .chineseTypography]
    )

    let primary = MarkdownToolbarLayout.primaryFormattingItems
    let insert = MarkdownToolbarLayout.insertMenuItems
    let format = MarkdownToolbarLayout.formatMenuItems
    let reachable = primary + insert + format
    XCTAssertEqual(reachable.count, Set(reachable).count, "No command may appear twice.")
    XCTAssertEqual(Set(reachable), Set(MarkdownToolbarFormattingItem.allCases))
  }

  func testMenuEntriesAreNotNestedInsideOtherMenus() {
    let menus: Set<MarkdownToolbarFormattingItem> = [
      .headingMenu, .listMenu, .insertMenu, .formatMenu,
    ]
    XCTAssertTrue(menus.isDisjoint(with: MarkdownToolbarLayout.insertMenuItems))
    XCTAssertTrue(menus.isDisjoint(with: MarkdownToolbarLayout.formatMenuItems))
  }
}
