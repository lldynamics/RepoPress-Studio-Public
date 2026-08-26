import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownTextMutationServiceTests: XCTestCase {
  func testBuildsMinimalInsertionEdit() throws {
    let edit = try XCTUnwrap(
      MarkdownTextMutationService.edit(
        from: "第一段\n第三段",
        to: "第一段\n第二段\n第三段",
        selectedRange: NSRange(location: 8, length: 0)
      )
    )

    XCTAssertEqual(edit.replacedRange.length, 0)
    XCTAssertEqual(edit.replacement, "第二段\n")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 8, length: 0))
  }

  func testDoesNotSplitComposedEmoji() throws {
    let original = "开头 👨‍👩‍👧‍👦 旧内容 结尾"
    let updated = "开头 👨‍👩‍👧‍👦 新内容 结尾"
    let edit = try XCTUnwrap(
      MarkdownTextMutationService.edit(
        from: original,
        to: updated,
        selectedRange: NSRange(location: updated.utf16.count, length: 0)
      )
    )

    let result = (original as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
    XCTAssertEqual(result, updated)
  }

  func testReturnsNilWhenTextIsUnchanged() {
    XCTAssertNil(
      MarkdownTextMutationService.edit(
        from: "相同",
        to: "相同",
        selectedRange: NSRange(location: 0, length: 0)
      )
    )
  }
}
