import AppKit
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownTextKit2ReadOnlyPresentationFactoryTests: XCTestCase {
  func testFrontMatterIsNotParsedAndBodyRangesUseFullSourceUTF16Offset() throws {
    // Images are intentionally rendered only when they occupy their own
    // Markdown line. Keep non-BMP and CJK text around that line so the full
    // source UTF-16 offset remains covered by this test.
    let body = "🙂中文\n![图](assets/a.png)\n尾"
    let source = "---\ncover: ![前言](front.png)\n---\n" + body
    let bodyOffset = (source as NSString).range(of: body).location
    let draftAttachment = makeDraftAttachment(
      relativePublishPath: "assets/a.png",
      repositoryPath: "content/assets/a.png",
      sourceFilePath: "/tmp/repo/assets/a.png"
    )

    let output = MarkdownTextKit2ReadOnlyPresentationFactory.make(
      fullSource: source,
      bodyMarkdown: body,
      bodyUTF16Offset: bodyOffset,
      attachments: [draftAttachment],
      availableWidth: 640,
      baseFontSize: 16
    )

    let expectedBodyImageRange = NSRange(
      location: bodyOffset + (body as NSString).range(of: "![图](assets/a.png)").location,
      length: ("![图](assets/a.png)" as NSString).length
    )
    let entry = try XCTUnwrap(output.entries.first)
    XCTAssertEqual(output.entries.count, 1)
    XCTAssertEqual(entry.sourceRange, expectedBodyImageRange)
    XCTAssertEqual(output.imageLoads.count, 1)
    XCTAssertEqual(output.imageLoads[0].sourceRange, expectedBodyImageRange)
    XCTAssertEqual(output.imageLoads[0].sourceURL.path, "/tmp/repo/assets/a.png")
    XCTAssertEqual(output.document.source, source)
    XCTAssertFalse(output.document.source.contains("\u{FFFC}"))
    XCTAssertEqual(output.document.attributedString.string, "---\ncover: ![前言](front.png)\n---\n🙂中文\n\u{FFFC}\n尾")
  }

  func testFormulaEntriesUseCompactInlineAndAvailableBlockBounds() throws {
    let body = "prefix $x^2$ suffix\n$$a + b$$\n"
    let source = "标题🙂\n" + body
    let bodyOffset = (source as NSString).range(of: body).location

    let output = MarkdownTextKit2ReadOnlyPresentationFactory.make(
      fullSource: source,
      bodyMarkdown: body,
      bodyUTF16Offset: bodyOffset,
      attachments: [],
      availableWidth: 320,
      baseFontSize: 16
    )

    XCTAssertEqual(output.entries.count, 2)
    let inline = try XCTUnwrap(
      output.entries.first {
        if case .some(.formula(_, .inline)) = $0.kind { return true }
        return false
      }
    )
    let block = try XCTUnwrap(
      output.entries.first {
        if case .some(.formula(_, .display)) = $0.kind { return true }
        return false
      }
    )
    XCTAssertGreaterThan(inline.attachment.bounds.width, 0)
    XCTAssertLessThanOrEqual(inline.attachment.bounds.width, 320)
    XCTAssertGreaterThan(inline.attachment.bounds.height, 0)
    XCTAssertGreaterThan(block.attachment.bounds.width, 0)
    XCTAssertEqual(block.attachment.bounds.width, 320, accuracy: 0.01)
    XCTAssertGreaterThan(block.attachment.bounds.height, 0)
    XCTAssertEqual(output.document.installedAttachments.count, 2)
  }

  func testMissingOrEmptySourcePathImagesRemainOrdinaryMarkdown() {
    let body = "![missing](missing.png) ![empty](empty.png)"
    let source = "前缀\n" + body
    let bodyOffset = (source as NSString).range(of: body).location
    let missing = makeDraftAttachment(
      relativePublishPath: "missing.png",
      repositoryPath: "missing.png",
      sourceFilePath: nil
    )
    let empty = makeDraftAttachment(
      relativePublishPath: "empty.png",
      repositoryPath: "empty.png",
      sourceFilePath: "  \n"
    )

    let output = MarkdownTextKit2ReadOnlyPresentationFactory.make(
      fullSource: source,
      bodyMarkdown: body,
      bodyUTF16Offset: bodyOffset,
      attachments: [missing, empty],
      availableWidth: 640,
      baseFontSize: 16
    )

    XCTAssertTrue(output.entries.isEmpty)
    XCTAssertTrue(output.imageLoads.isEmpty)
    XCTAssertEqual(output.document.attributedString.string, source)
    XCTAssertTrue(output.document.installedAttachments.isEmpty)
  }

  func testAdjacentImageAndFormulaEntriesPreserveOrderingAndRanges() throws {
    let body = "![图](a.png)\n$x$"
    let source = "🙂中文" + body + "后"
    let bodyOffset = (source as NSString).range(of: body).location
    let image = makeDraftAttachment(
      relativePublishPath: "a.png",
      repositoryPath: "a.png",
      sourceFilePath: "/tmp/a.png"
    )

    let output = MarkdownTextKit2ReadOnlyPresentationFactory.make(
      fullSource: source,
      bodyMarkdown: body,
      bodyUTF16Offset: bodyOffset,
      attachments: [image],
      availableWidth: 240,
      baseFontSize: 14
    )

    XCTAssertEqual(output.entries.count, 2)
    XCTAssertEqual(output.imageLoads.count, 1)
    let imageRange = NSRange(
      location: bodyOffset,
      length: ("![图](a.png)" as NSString).length
    )
    let formulaRange = NSRange(
      location: bodyOffset + imageRange.length + 1,
      length: ("$x$" as NSString).length
    )
    XCTAssertEqual(output.entries[0].sourceRange, imageRange)
    XCTAssertEqual(output.entries[1].sourceRange, formulaRange)
    XCTAssertEqual(output.document.attributedString.string, "🙂中文\u{FFFC}\n\u{FFFC}后")
    XCTAssertEqual(
      output.document.installedAttachments.map(\.sourceRange),
      [imageRange, formulaRange]
    )
  }

  func testImageUpdateReusesProviderViewWithoutAddingTextViewSubview() throws {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = "A\u{FFFC}B"
    let attachment = MarkdownNativeTextAttachment(
      content: .image(accessibilityText: "图"),
      bounds: NSRect(x: 0, y: -20, width: 100, height: 80)
    )
    let storage = try XCTUnwrap(textView.textStorage)
    storage.addAttribute(
      .attachment,
      value: attachment,
      range: NSRange(location: 1, length: 1)
    )
    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    let contentManager = try XCTUnwrap(layoutManager.textContentManager)
    let location = try XCTUnwrap(
      contentManager.location(contentManager.documentRange.location, offsetBy: 1)
    )
    let provider = MarkdownNativeTextAttachmentViewProvider(
      textAttachment: attachment,
      parentView: textView,
      textLayoutManager: layoutManager,
      location: location
    )
    let view = try XCTUnwrap(provider.view)
    let subviewCount = textView.subviews.count
    attachment.updateImage(NSImage(size: NSSize(width: 8, height: 8)))

    XCTAssertTrue(provider.view === view)
    XCTAssertEqual(textView.subviews.count, subviewCount)
    XCTAssertEqual(textView.string, "A\u{FFFC}B")
  }

  private func makeDraftAttachment(
    relativePublishPath: String,
    repositoryPath: String,
    sourceFilePath: String?
  ) -> DraftAttachment {
    DraftAttachment(
      originalFilename: relativePublishPath,
      relativePublishPath: relativePublishPath,
      repositoryPath: repositoryPath,
      sourceFilePath: sourceFilePath
    )
  }
}
