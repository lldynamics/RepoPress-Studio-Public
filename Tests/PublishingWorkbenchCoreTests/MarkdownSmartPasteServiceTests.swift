import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownSmartPasteServiceTests: XCTestCase {
  private let service = MarkdownSmartPasteService()

  func testWrapsSelectedTextWithPastedWebURL() throws {
    let markdown = "Read the guide"
    let range = (markdown as NSString).range(of: "the guide")
    let edit = try XCTUnwrap(
      service.linkEdit(
        in: markdown,
        selectedRange: range,
        pastedText: "https://example.com/docs"
      )
    )

    XCTAssertEqual(
      applying(edit, to: markdown),
      "Read [the guide](https://example.com/docs)"
    )
    XCTAssertEqual(edit.selectedRange.location, 42)
  }

  func testTrimsURLAndEscapesMarkdownLabelAndParentheses() throws {
    let markdown = #"read a ] guide"#
    let range = (markdown as NSString).range(of: #"a ] guide"#)
    let edit = try XCTUnwrap(
      service.linkEdit(
        in: markdown,
        selectedRange: range,
        pastedText: "  https://example.com/a_(b)\n"
      )
    )

    XCTAssertEqual(
      applying(edit, to: markdown),
      #"read [a \] guide](<https://example.com/a_(b)>)"#
    )
  }

  func testLeavesNonWebTextAndEmptySelectionToSystemPaste() {
    let markdown = "guide"
    XCTAssertNil(
      service.linkEdit(
        in: markdown,
        selectedRange: NSRange(location: 0, length: 5),
        pastedText: "not a URL"
      )
    )
    XCTAssertNil(
      service.linkEdit(
        in: markdown,
        selectedRange: NSRange(location: 5, length: 0),
        pastedText: "https://example.com"
      )
    )
    XCTAssertNil(
      service.linkEdit(
        in: markdown,
        selectedRange: NSRange(location: 0, length: 5),
        pastedText: "file:///tmp/private.txt"
      )
    )
  }

  func testStoresPastedPNGInDurableConfiguredDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownSmartPasteServiceTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PastedImageFileStore(rootDirectoryURL: root)
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let data = Data([0x89, 0x50, 0x4E, 0x47])

    let url = try store.storePNG(data, id: id)

    XCTAssertEqual(
      url.lastPathComponent,
      "pasted-image-11111111-2222-3333-4444-555555555555.png"
    )
    XCTAssertEqual(try Data(contentsOf: url), data)
  }

  func testRejectsEmptyPastedImageData() {
    let store = PastedImageFileStore(rootDirectoryURL: FileManager.default.temporaryDirectory)
    XCTAssertThrowsError(try store.storePNG(Data())) { error in
      XCTAssertEqual(
        error as? PastedImageFileStoreError,
        .emptyImageData
      )
    }
  }

  private func applying(_ edit: MarkdownSmartEdit, to markdown: String) -> String {
    (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
  }
}
