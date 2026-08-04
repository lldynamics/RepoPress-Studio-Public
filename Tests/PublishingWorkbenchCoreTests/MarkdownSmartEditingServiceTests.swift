import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownSmartEditingServiceTests: XCTestCase {
  private let service = MarkdownSmartEditingService()

  func testContinuesBulletTaskOrderedListAndQuote() throws {
    try assertNewline("- item", becomes: "- item\n- ")
    try assertNewline("- [x] done", becomes: "- [x] done\n- [ ] ")
    try assertNewline("9. item", becomes: "9. item\n10. ")
    try assertNewline("1、第一项", becomes: "1、第一项\n2、")
    try assertNewline("9、 第九项", becomes: "9、 第九项\n10、 ")
    try assertNewline("> quote", becomes: "> quote\n> ")
  }

  func testEmptyListItemExitsList() throws {
    let markdown = "- first\n- "
    let edit = try XCTUnwrap(
      service.newlineEdit(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0)
      )
    )

    XCTAssertEqual(applying(edit, to: markdown), "- first\n")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 8, length: 0))
  }

  func testEmptyChineseOrderedListItemExitsList() throws {
    let markdown = "1、第一项\n2、"
    let edit = try XCTUnwrap(
      service.newlineEdit(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0)
      )
    )

    XCTAssertEqual(applying(edit, to: markdown), "1、第一项\n")
    XCTAssertEqual(
      edit.selectedRange,
      NSRange(location: ("1、第一项\n" as NSString).length, length: 0)
    )
  }

  func testDoesNotContinuePlainTextOrMarkersInsideCodeFence() {
    let plain = "plain text"
    XCTAssertNil(
      service.newlineEdit(
        in: plain,
        selectedRange: NSRange(location: (plain as NSString).length, length: 0)
      )
    )

    let code = "```\n- code"
    XCTAssertNil(
      service.newlineEdit(
        in: code,
        selectedRange: NSRange(location: (code as NSString).length, length: 0)
      )
    )
  }

  func testDoesNotOverflowLargestOrderedListNumber() {
    let markdown = "\(Int.max)、内容"

    XCTAssertNil(
      service.newlineEdit(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0)
      )
    )
  }

  func testIndentsAndOutdentsCurrentListItem() throws {
    let markdown = "- parent\n- child"
    let cursor = (markdown as NSString).range(of: "child").location
    let indent = try XCTUnwrap(
      service.indentationEdit(
        in: markdown,
        selectedRange: NSRange(location: cursor, length: 0),
        direction: .indent
      )
    )
    let indented = applying(indent, to: markdown)

    XCTAssertEqual(indented, "- parent\n  - child")
    XCTAssertEqual(indent.selectedRange.location, cursor + 2)

    let outdent = try XCTUnwrap(
      service.indentationEdit(
        in: indented,
        selectedRange: indent.selectedRange,
        direction: .outdent
      )
    )
    XCTAssertEqual(applying(outdent, to: indented), markdown)
    XCTAssertEqual(outdent.selectedRange.location, cursor)
  }

  func testIndentsMultipleSelectedListItemsAsOneEdit() throws {
    let markdown = "- one\n- two\nparagraph"
    let selection = NSRange(location: 0, length: ("- one\n- two" as NSString).length)
    let edit = try XCTUnwrap(
      service.indentationEdit(
        in: markdown,
        selectedRange: selection,
        direction: .indent
      )
    )

    XCTAssertEqual(applying(edit, to: markdown), "  - one\n  - two\nparagraph")
    XCTAssertEqual(edit.selectedRange.location, 0)
    XCTAssertEqual(edit.selectedRange.length, ("  - one\n  - two\n" as NSString).length)
  }

  func testLeavesMixedPlainTextSelectionToSystemDefault() {
    let markdown = "- item\nplain"
    XCTAssertNil(
      service.indentationEdit(
        in: markdown,
        selectedRange: NSRange(location: 0, length: (markdown as NSString).length),
        direction: .indent
      )
    )
  }

  private func assertNewline(
    _ markdown: String,
    becomes expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let edit = try XCTUnwrap(
      service.newlineEdit(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0)
      ),
      file: file,
      line: line
    )
    XCTAssertEqual(applying(edit, to: markdown), expected, file: file, line: line)
    XCTAssertEqual(edit.selectedRange.location, (expected as NSString).length, file: file, line: line)
  }

  private func applying(_ edit: MarkdownSmartEdit, to markdown: String) -> String {
    (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
  }
}
