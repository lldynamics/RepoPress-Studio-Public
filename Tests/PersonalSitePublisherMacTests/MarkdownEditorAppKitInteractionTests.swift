import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
class MarkdownEditorAppKitInteractionTestCase: XCTestCase {
  func makeCoordinator(
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
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
  }

  func makeFixture() throws -> (root: URL, imageURL: URL, textURL: URL) {
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

  func makeKeyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    characters: String = "",
    charactersIgnoringModifiers: String = "",
    isARepeat: Bool = false
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      isARepeat: isARepeat,
      keyCode: keyCode
    )
  }

  func makeTextView() -> DroppableMarkdownTextView {
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

@MainActor
final class MarkdownInlineAttachmentTaskCancellationProbe {
  var started = false
  var cancelled = false
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
final class MarkdownDraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
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
