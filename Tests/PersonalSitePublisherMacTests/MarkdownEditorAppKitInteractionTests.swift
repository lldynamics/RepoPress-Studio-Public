import AppKit
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionTests: XCTestCase {
  func testSlashCommandTextUsesUTF16OffsetsForEmojiAndComposedCharacters() {
    let emojiBody = "😀\n/ti"
    let emojiCaret = (emojiBody as NSString).length
    XCTAssertEqual(
      MarkdownSlashCommandText.query(in: emojiBody, caretUTF16Location: emojiCaret),
      "ti"
    )
    XCTAssertEqual(
      MarkdownSlashCommandText.replacementRange(
        in: emojiBody,
        caretUTF16Location: emojiCaret
      ),
      NSRange(location: 3, length: 3)
    )

    let composedBody = "e\u{301}\n/h"
    let composedCaret = (composedBody as NSString).length
    XCTAssertEqual(
      MarkdownSlashCommandText.query(in: composedBody, caretUTF16Location: composedCaret),
      "h"
    )
    XCTAssertEqual(
      MarkdownSlashCommandText.replacementRange(
        in: composedBody,
        caretUTF16Location: composedCaret
      ),
      NSRange(location: 3, length: 2)
    )
  }

  func testSlashCommandTextRejectsOutOfBoundsCaret() {
    let body = "正文/"
    let length = (body as NSString).length
    XCTAssertNil(MarkdownSlashCommandText.query(in: body, caretUTF16Location: length + 1))
    XCTAssertNil(MarkdownSlashCommandText.replacementRange(in: body, caretUTF16Location: 0))
  }

  func testSlashCommandKeyRoutingDoesNotFallThroughToTextEditing() throws {
    let textView = makeTextView()
    textView.string = "原文"
    var receivedKeys: [MarkdownSlashCommandKey] = []
    textView.slashCommandKeyHandler = { key in
      receivedKeys.append(key)
      return true
    }

    let downEvent = try XCTUnwrap(makeKeyEvent(keyCode: 125))
    let returnEvent = try XCTUnwrap(makeKeyEvent(keyCode: 36))
    textView.keyDown(with: downEvent)
    textView.keyDown(with: returnEvent)

    XCTAssertEqual(receivedKeys, [.moveDown, .select])
    XCTAssertEqual(textView.string, "原文")
  }

  func testSlashCommandKeyRoutingConsumesUpAndEscapeWithoutEditing() throws {
    let textView = makeTextView()
    textView.string = "原文"
    var receivedKeys: [MarkdownSlashCommandKey] = []
    textView.slashCommandKeyHandler = { key in
      receivedKeys.append(key)
      return true
    }

    let upEvent = try XCTUnwrap(makeKeyEvent(keyCode: 126))
    let escapeEvent = try XCTUnwrap(makeKeyEvent(keyCode: 53))
    textView.keyDown(with: upEvent)
    textView.keyDown(with: escapeEvent)

    XCTAssertEqual(receivedKeys, [.moveUp, .dismiss])
    XCTAssertEqual(textView.string, "原文")
  }

  func testSlashCommandSelectionWrapsAtBoundariesAndHandlesEmptyLists() {
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 0,
        itemCount: 3,
        direction: .moveUp
      ),
      2
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 2,
        itemCount: 3,
        direction: .moveDown
      ),
      0
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 99,
        itemCount: 3,
        direction: .moveDown
      ),
      0
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: -1,
        itemCount: 3,
        direction: .moveUp
      ),
      2
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 0,
        itemCount: 0,
        direction: .moveDown
      ),
      0
    )
  }

  func testSlashCommandFilteringKeepsSelectedIndexWithinBounds() {
    let items = [
      SlashCommandItem(id: "h1", title: "一级标题", subtitle: "#", systemImage: "textformat") {},
      SlashCommandItem(id: "quote", title: "引用块", subtitle: ">", systemImage: "text.quote") {},
    ]
    XCTAssertEqual(
      MarkdownSlashCommandMenu.filteredItems(from: items, matching: "quote").map(\.id),
      ["quote"]
    )
    XCTAssertTrue(
      MarkdownSlashCommandMenu.filteredItems(from: items, matching: "missing").isEmpty
    )
  }

  func testSlashCommandKeyRoutingLeavesModifiedKeysToTextView() throws {
    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    var receivedKeys: [MarkdownSlashCommandKey] = []
    textView.slashCommandKeyHandler = { key in
      receivedKeys.append(key)
      return true
    }

    let commandDown = try XCTUnwrap(
      makeKeyEvent(keyCode: 125, modifiers: [.command])
    )
    textView.keyDown(with: commandDown)

    XCTAssertTrue(receivedKeys.isEmpty)
    XCTAssertEqual(
      MarkdownSlashCommandKey.from(keyCode: 125, modifiers: [.function]),
      .moveDown
    )
    XCTAssertEqual(
      MarkdownSlashCommandKey.from(keyCode: 76, modifiers: [.numericPad]),
      .select
    )
  }

  func testTypingFeedbackOnlyPlaysForPrintableUnmodifiedInput() {
    XCTAssertEqual(
      MarkdownTypingFeedbackPolicy.defaultPreset,
      .off
    )
    XCTAssertTrue(
      MarkdownTypingFeedbackPolicy.shouldPlay(
        for: .insertedText,
        preset: .typewriter
      )
    )
    XCTAssertFalse(
      MarkdownTypingFeedbackPolicy.shouldPlay(
        for: .insertedText,
        preset: .off
      )
    )
    XCTAssertFalse(
      MarkdownTypingFeedbackPolicy.shouldPlay(
        for: .command,
        preset: .typewriter
      )
    )
    XCTAssertFalse(
      MarkdownTypingFeedbackPolicy.shouldPlay(
        for: .navigation,
        preset: .typewriter
      )
    )
    XCTAssertFalse(
      MarkdownTypingFeedbackPolicy.shouldPlay(
        for: .insertedText,
        preset: .typewriter,
        elapsedSincePreviousPlayback: MarkdownTypingFeedbackPolicy.minimumPlaybackInterval / 2
      )
    )
    XCTAssertTrue(
      MarkdownTypingFeedbackPolicy.shouldPlay(
        for: .insertedText,
        preset: .typewriter,
        elapsedSincePreviousPlayback: MarkdownTypingFeedbackPolicy.minimumPlaybackInterval
      )
    )
    XCTAssertEqual(
      MarkdownTypingFeedbackPolicy.event(
        keyCode: 0,
        characters: "😀",
        modifiers: []
      ),
      .insertedText
    )
    XCTAssertEqual(
      MarkdownTypingFeedbackPolicy.event(
        keyCode: 0,
        characters: "c",
        modifiers: [.command]
      ),
      .command
    )
    XCTAssertEqual(
      MarkdownTypingFeedbackPolicy.event(
        keyCode: 125,
        characters: nil,
        modifiers: []
      ),
      .navigation
    )
  }

  func testComfortDefaultsIncludeSilentTypingAndParagraphSpotlightReset() {
    XCTAssertEqual(
      MarkdownEditorComfortConfiguration.defaultTypewriterSoundPreset,
      .off
    )
    XCTAssertFalse(MarkdownEditorComfortConfiguration.defaultParagraphSpotlightEnabled)
  }

  func testEquivalentAppKitSelectionDoesNotRepublishSwiftUIBindings() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var selectionWriteCount = 0
    var frontMatterWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: {
          selectionWriteCount += 1
          selectedRange = $0
        }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: {
          frontMatterWriteCount += 1
          isFrontMatterSelection = $0
        }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollProgressChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.setSelectedRange(selectedRange)

    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(selectionWriteCount, 0)
    XCTAssertEqual(frontMatterWriteCount, 0)
  }

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

  private func makeKeyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    )
  }

  private func makeTextView() -> DroppableMarkdownTextView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
    )
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    return DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: textContainer
    )
  }
}

struct TestMarkdownPasteboardSource: MarkdownPasteboardSource {
  let strings: [NSPasteboard.PasteboardType: String]
  let dataByType: [NSPasteboard.PasteboardType: Data]

  init(
    strings: [NSPasteboard.PasteboardType: String] = [:],
    data: [NSPasteboard.PasteboardType: Data] = [:]
  ) {
    self.strings = strings
    self.dataByType = data
  }

  func readObjects(
    forClasses classArray: [AnyClass],
    options: [NSPasteboard.ReadingOptionKey: Any]? = nil
  ) -> [Any]? {
    nil
  }

  func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
    dataByType[dataType]
  }

  func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
    strings[dataType]
  }

  var appKitPasteboard: NSPasteboard? { nil }
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
