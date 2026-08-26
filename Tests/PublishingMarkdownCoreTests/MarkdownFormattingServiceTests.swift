import XCTest
@testable import PublishingMarkdownCore

final class MarkdownFormattingServiceTests: XCTestCase {
  private let service = MarkdownFormattingService()

  func testBoldWrapsAndTogglesSelectedText() throws {
    let markdown = "write clearly"
    let range = (markdown as NSString).range(of: "clearly")
    let wrapped = try edit(markdown, range: range, command: .bold)
    let formatted = applying(wrapped, to: markdown)

    XCTAssertEqual(formatted, "write **clearly**")
    XCTAssertEqual(wrapped.selectedRange, NSRange(location: 8, length: 7))

    let toggled = try edit(formatted, range: wrapped.selectedRange, command: .bold)
    XCTAssertEqual(applying(toggled, to: formatted), markdown)
    XCTAssertEqual(toggled.selectedRange, range)
  }

  func testBoldAndItalicInsertEditablePlaceholdersWithoutSelection() throws {
    let bold = try edit("text ", range: NSRange(location: 5, length: 0), command: .bold)
    XCTAssertEqual(applying(bold, to: "text "), "text ****")
    XCTAssertEqual(bold.selectedRange, NSRange(location: 7, length: 0))

    let italic = try edit("text ", range: NSRange(location: 5, length: 0), command: .italic)
    XCTAssertEqual(applying(italic, to: "text "), "text **")
    XCTAssertEqual(italic.selectedRange, NSRange(location: 6, length: 0))
  }

  func testItalicDoesNotMistakeBoldMarkersForItalic() throws {
    let markdown = "**strong**"
    let range = (markdown as NSString).range(of: "strong")
    let edit = try self.edit(markdown, range: range, command: .italic)

    XCTAssertEqual(applying(edit, to: markdown), "***strong***")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 3, length: 6))
  }

  func testLinkWrapsSelectionAndSelectsDestinationPlaceholder() throws {
    let markdown = "Read guide"
    let range = (markdown as NSString).range(of: "guide")
    let edit = try self.edit(markdown, range: range, command: .link)

    XCTAssertEqual(applying(edit, to: markdown), "Read [guide](https://)")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 13, length: 8))
  }

  func testLinkWithoutSelectionPlacesCursorInLabel() throws {
    let edit = try self.edit("Read ", range: NSRange(location: 5, length: 0), command: .link)

    XCTAssertEqual(applying(edit, to: "Read "), "Read [](https://)")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 6, length: 0))
  }

  func testLinkTogglesWhenLabelOrWholeLinkIsSelected() throws {
    let markdown = "[guide](https://example.com)"
    let labelRange = (markdown as NSString).range(of: "guide")
    let labelToggle = try edit(markdown, range: labelRange, command: .link)
    XCTAssertEqual(applying(labelToggle, to: markdown), "guide")
    XCTAssertEqual(labelToggle.selectedRange, NSRange(location: 0, length: 5))

    let wholeToggle = try edit(
      markdown,
      range: NSRange(location: 0, length: (markdown as NSString).length),
      command: .link
    )
    XCTAssertEqual(applying(wholeToggle, to: markdown), "guide")
  }

  func testHeadingAddsChangesAndTogglesCurrentLine() throws {
    let markdown = "Intro\nHeading text\nEnd"
    let cursor = (markdown as NSString).range(of: "text").location
    let h2 = try edit(markdown, range: NSRange(location: cursor, length: 0), command: .heading(level: 2))
    let h2Markdown = applying(h2, to: markdown)
    XCTAssertEqual(h2Markdown, "Intro\n## Heading text\nEnd")
    XCTAssertEqual(h2.selectedRange.location, cursor + 3)

    let h3 = try edit(h2Markdown, range: h2.selectedRange, command: .heading(level: 3))
    let h3Markdown = applying(h3, to: h2Markdown)
    XCTAssertEqual(h3Markdown, "Intro\n### Heading text\nEnd")

    let plain = try edit(h3Markdown, range: h3.selectedRange, command: .heading(level: 3))
    XCTAssertEqual(applying(plain, to: h3Markdown), markdown)
  }

  func testHeadingFormatsSelectedNonemptyLinesAsOneEdit() throws {
    let markdown = "One\n\nTwo\nEnd"
    let selection = NSRange(location: 0, length: ("One\n\nTwo" as NSString).length)
    let edit = try self.edit(markdown, range: selection, command: .heading(level: 2))

    XCTAssertEqual(applying(edit, to: markdown), "## One\n\n## Two\nEnd")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 0, length: ("## One\n\n## Two\n" as NSString).length))
  }

  func testHeadingDoesNotModifyFencedCode() {
    let markdown = "```\ncode\n```"
    let cursor = (markdown as NSString).range(of: "code").location
    XCTAssertNil(
      service.edit(
        in: markdown,
        selectedRange: NSRange(location: cursor, length: 0),
        command: .heading(level: 2)
      )
    )
  }

  func testRejectsInvalidHeadingLevelAndRange() {
    XCTAssertNil(
      service.edit(
        in: "Heading",
        selectedRange: NSRange(location: 0, length: 0),
        command: .heading(level: 7)
      )
    )
    XCTAssertNil(
      service.edit(
        in: "Heading",
        selectedRange: NSRange(location: -1, length: 0),
        command: .bold
      )
    )
  }

  private func edit(
    _ markdown: String,
    range: NSRange,
    command: MarkdownFormattingCommand
  ) throws -> MarkdownSmartEdit {
    try XCTUnwrap(service.edit(in: markdown, selectedRange: range, command: command))
  }

  private func applying(_ edit: MarkdownSmartEdit, to markdown: String) -> String {
    (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
  }
}
