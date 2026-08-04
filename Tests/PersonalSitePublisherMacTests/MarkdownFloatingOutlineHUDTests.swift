import Foundation
import XCTest

@testable import PersonalSitePublisherMac
import PublishingWorkbenchCore

final class MarkdownFloatingOutlineHUDTests: XCTestCase {
  func testActiveItemFollowsVisibleViewportHeading() throws {
    let items = makeItems()
    let secondHeading = try XCTUnwrap(items.last)

    let activeID = MarkdownFloatingOutlineHUDPresentation.activeItemID(
      items: items,
      visibleRange: NSRange(
        location: secondHeading.headingLocation + 4,
        length: 80
      ),
      selectedRange: NSRange(location: 0, length: 0)
    )

    XCTAssertEqual(activeID, secondHeading.id)
  }

  func testFirstVisibleHeadingIsActiveWhenViewportStartsBeforeOutline() throws {
    let items = makeItems()
    let firstHeading = try XCTUnwrap(items.first)

    let activeItem = MarkdownFloatingOutlineHUDPresentation.activeItem(
      items: items,
      visibleRange: NSRange(location: 0, length: firstHeading.headingLocation + 4),
      selectedRange: NSRange(location: 0, length: 0)
    )

    XCTAssertEqual(activeItem?.id, firstHeading.id)
  }

  func testSelectedRangeIsUsedUntilEditorReportsViewport() throws {
    let items = makeItems()
    let selectedItem = try XCTUnwrap(items.last)

    let activeID = MarkdownFloatingOutlineHUDPresentation.activeItemID(
      items: items,
      visibleRange: NSRange(location: 0, length: 0),
      selectedRange: NSRange(location: selectedItem.headingLocation, length: 0)
    )

    XCTAssertEqual(activeID, selectedItem.id)
  }

  func testEmptyOutlineHasNoActiveItem() {
    XCTAssertNil(
      MarkdownFloatingOutlineHUDPresentation.activeItemID(
        items: [],
        visibleRange: NSRange(location: 0, length: 0),
        selectedRange: NSRange(location: 0, length: 0)
      )
    )
  }

  private func makeItems() -> [MarkdownOutlineItem] {
    MarkdownOutlineService().outline(
      in: """
      引导文字

      ## 第一章
      第一章内容

      ### 子章节
      子章节内容

      ## 第二章
      第二章内容
      """
    )
  }
}
