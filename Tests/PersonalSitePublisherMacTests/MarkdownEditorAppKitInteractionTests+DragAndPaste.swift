import AppKit
import PublishingCoreSupport
import PublishingKnowledgeCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionDragAndPasteTests:
  MarkdownEditorAppKitInteractionTestCase
{
  func testDragAcceptsSupportedImagesAndDeliversOnlyFilteredFileURLs() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pasteboard = NSPasteboard.general

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Draft"
    textView.fileDropImageURLsProvider = { _ in
      ImageFileSupport.supportedImageURLs(in: [fixture.imageURL, fixture.textURL])
    }
    var targetedStates: [Bool] = []
    var droppedURLs: [URL] = []
    textView.fileDropTargetChangedHandler = { targetedStates.append($0) }
    textView.fileDropHandler = { urls, _ in droppedURLs = urls }
    let draggingInfo = MarkdownDraggingInfoStub(pasteboard: pasteboard)

    XCTAssertEqual(textView.draggingEntered(draggingInfo), .copy)
    XCTAssertTrue(textView.prepareForDragOperation(draggingInfo))
    XCTAssertTrue(textView.performDragOperation(draggingInfo))
    XCTAssertEqual(droppedURLs, [fixture.imageURL.standardizedFileURL])
    XCTAssertEqual(targetedStates, [true, false])
  }

  func testDragRejectsUnsupportedFilesWithoutCallingDropHandler() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pasteboard = NSPasteboard.general

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    var didDrop = false
    textView.fileDropImageURLsProvider = { _ in [] }
    textView.fileDropHandler = { _, _ in didDrop = true }
    let draggingInfo = MarkdownDraggingInfoStub(pasteboard: pasteboard)

    XCTAssertEqual(textView.draggingEntered(draggingInfo), [])
    XCTAssertFalse(textView.prepareForDragOperation(draggingInfo))
    XCTAssertFalse(textView.performDragOperation(draggingInfo))
    XCTAssertFalse(didDrop)
  }

  func testKnowledgeDragCarriesCitationMetadataIntoDropHandler() throws {
    let citation = KnowledgeCitation(
      id: "drag-citation",
      documentID: UUID(),
      chunkID: UUID(),
      title: "本地资料",
      locator: "第二章",
      excerpt: "用于写作的资料片段"
    )
    let pasteboard = NSPasteboard.general

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Draft"
    textView.knowledgeMarkdownProvider = { _ in "> 引用片段" }
    textView.knowledgeCitationProvider = { _ in citation }
    var receivedMarkdown: String?
    var receivedCitation: KnowledgeCitation?
    textView.knowledgeMarkdownDropHandler = { markdown, _, citation in
      receivedMarkdown = markdown
      receivedCitation = citation
    }
    let draggingInfo = MarkdownDraggingInfoStub(pasteboard: pasteboard)

    XCTAssertEqual(textView.draggingEntered(draggingInfo), .copy)
    XCTAssertTrue(textView.performDragOperation(draggingInfo))
    XCTAssertEqual(receivedMarkdown, "> 引用片段")
    XCTAssertEqual(receivedCitation, citation)
  }

  func testRichHTMLPasteboardKeepsTrustedWebBaseURL() {
    let pasteboard = TestMarkdownPasteboardSource(
      strings: [
        .html: "<p><strong>Hello</strong></p>",
        .URL: "https://example.com/articles/1",
      ]
    )

    let content = MarkdownPasteboardReader.richTextContent(from: pasteboard)

    XCTAssertEqual(content?.html, "<p><strong>Hello</strong></p>")
    XCTAssertEqual(content?.baseURL?.absoluteString, "https://example.com/articles/1")
  }

}
