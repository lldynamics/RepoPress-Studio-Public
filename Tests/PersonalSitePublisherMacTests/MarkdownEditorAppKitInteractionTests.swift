import AppKit
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionTests: XCTestCase {
  func testAutomaticPairingUsesLiveTextViewUndoableInsertionPath() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: true
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollProgressChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    let shouldApplyDefaultInsertion = coordinator.textView(
      textView,
      shouldChangeTextIn: selectedRange,
      replacementString: "("
    )

    XCTAssertFalse(shouldApplyDefaultInsertion)
    XCTAssertEqual(textView.string, "()正文")
    XCTAssertEqual(selectedRange, NSRange(location: 1, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
  }

  func testAutomaticPairingCanBeDisabled() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: false
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollProgressChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.delegate = coordinator

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: selectedRange,
        replacementString: "("
      )
    )
    XCTAssertEqual(textView.string, "正文")
  }

  func testBodyEditKeepsExistingFrontMatterBoundary() {
    let source = "---\r\ntitle: Draft\r\n---\r\n\r\n正文"
    let sourceText = source as NSString
    let bodyRange = sourceText.range(of: "正文")
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: "正文",
      bodyUTF16Offset: bodyRange.location
    )
    let textView = NSTextView()
    textView.string = source
    textView.delegate = coordinator
    let editRange = NSRange(location: bodyRange.location, length: 1)

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: editRange,
        replacementString: "改"
      )
    )
    let updated = sourceText.replacingCharacters(in: editRange, with: "改")
    textView.string = updated
    textView.setSelectedRange(NSRange(location: editRange.location + 1, length: 0))
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(coordinator.bodyUTF16Offset, bodyRange.location)
    XCTAssertEqual(coordinator.bodyMarkdown, "改文")
    coordinator.invalidateHighlightedTextCache()
  }

  func testFrontMatterEditRecomputesBoundaryWithoutChangingBody() {
    let source = "---\ntitle: Old\n---\n\n正文"
    let sourceText = source as NSString
    let originalBodyRange = sourceText.range(of: "正文")
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: "正文",
      bodyUTF16Offset: originalBodyRange.location
    )
    let textView = NSTextView()
    textView.string = source
    textView.delegate = coordinator
    let editRange = sourceText.range(of: "Old")
    let replacement = "A much longer title"

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: editRange,
        replacementString: replacement
      )
    )
    let updated = sourceText.replacingCharacters(in: editRange, with: replacement)
    textView.string = updated
    textView.setSelectedRange(
      NSRange(location: editRange.location + (replacement as NSString).length, length: 0)
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(
      coordinator.bodyUTF16Offset,
      (updated as NSString).range(of: "正文").location
    )
    XCTAssertEqual(coordinator.bodyMarkdown, "正文")
    coordinator.invalidateHighlightedTextCache()
  }

  func testDragAcceptsSupportedImagesAndDeliversOnlyFilteredFileURLs() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pasteboard = NSPasteboard(
      name: .init("MarkdownEditorAppKitInteractionTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    XCTAssertTrue(
      pasteboard.writeObjects([
        fixture.imageURL as NSURL,
        fixture.textURL as NSURL,
      ])
    )

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Draft"
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
    let pasteboard = NSPasteboard(
      name: .init("MarkdownEditorAppKitInteractionTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([fixture.textURL as NSURL]))

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    var didDrop = false
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
    let pasteboard = NSPasteboard(
      name: .init("MarkdownEditorAppKitInteractionTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    pasteboard.setData(
      Data("> 引用片段".utf8),
      forType: KnowledgeArticleInsertionService.knowledgeMarkdownPasteboardType
    )
    pasteboard.setData(
      try JSONEncoder().encode(citation),
      forType: KnowledgeArticleInsertionService.knowledgeCitationPasteboardType
    )

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Draft"
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
    let pasteboard = NSPasteboard(
      name: .init("MarkdownEditorAppKitInteractionTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    pasteboard.setString("<p><strong>Hello</strong></p>", forType: .html)
    pasteboard.setString("https://example.com/articles/1", forType: .URL)

    let content = MarkdownPasteboardReader.richTextContent(from: pasteboard)

    XCTAssertEqual(content?.html, "<p><strong>Hello</strong></p>")
    XCTAssertEqual(content?.baseURL?.absoluteString, "https://example.com/articles/1")
  }

  private func makeCoordinator(
    source: String,
    bodyMarkdown: String,
    bodyUTF16Offset: Int
  ) -> MacMarkdownTextView.Coordinator {
    var text = source
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    return MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollProgressChanged: { _ in },
      onDroppedFiles: { _ in }
    )
  }

  private func makeFixture() throws -> (root: URL, imageURL: URL, textURL: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MarkdownEditorAppKitInteractionTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let imageURL = root.appendingPathComponent("cover.png")
    let textURL = root.appendingPathComponent("notes.txt")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
    try Data("notes".utf8).write(to: textURL)
    return (root, imageURL, textURL)
  }
}

@MainActor
private final class MarkdownDraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation = .copy
  var draggingLocation: NSPoint = .zero
  var draggedImageLocation: NSPoint = .zero
  var draggedImage: NSImage?
  var draggingSource: Any?
  var draggingSequenceNumber: Int = 1
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight = .none

  init(pasteboard: NSPasteboard) {
    draggingPasteboard = pasteboard
  }

  func slideDraggedImage(to screenPoint: NSPoint) {}

  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
    nil
  }

  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [],
    for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}

  func resetSpringLoading() {}
}
