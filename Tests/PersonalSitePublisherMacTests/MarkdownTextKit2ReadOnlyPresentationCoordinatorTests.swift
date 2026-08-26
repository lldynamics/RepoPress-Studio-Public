import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownTextKit2ReadOnlyPresentationCoordinatorTests: XCTestCase {
  func testPolicyIsDefaultOffAndAcceptsOnlyExplicitTruthyValues() {
    XCTAssertFalse(
      MarkdownTextKit2ReadOnlyPresentationPolicy.isEnabled(environment: [:])
    )
    XCTAssertFalse(
      MarkdownTextKit2ReadOnlyPresentationPolicy.isEnabled(
        environment: [
          MarkdownTextKit2ReadOnlyPresentationPolicy.environmentKey: "0"
        ]
      )
    )
    for truthyValue in ["1", "true", "YES", " on "] {
      XCTAssertTrue(
        MarkdownTextKit2ReadOnlyPresentationPolicy.isEnabled(
          environment: [
            MarkdownTextKit2ReadOnlyPresentationPolicy.environmentKey: truthyValue
          ]
        )
      )
    }
  }

  func testDisabledPolicyNeverReplacesEditableMarkdown() {
    let source = "prefix $x$ suffix"
    let fixture = makeFixture(source: source, isEnabled: false)
    defer { fixture.close() }

    XCTAssertFalse(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertNil(fixture.coordinator.readOnlyPresentationDocument)
    XCTAssertEqual(fixture.state.text, source)
  }

  func testSemanticOnlyPresentationInstallsAndRestoresWithoutAttachments() throws {
    let source = "# Title\n\n**bold** with `inline code`."
    let selection = (source as NSString).range(of: "bold")
    let preservedAttribute = NSAttributedString.Key("repopress.test.preserved-highlight")
    let fixture = makeFixture(source: source, isEnabled: true)
    defer { fixture.close() }
    fixture.textView.setSelectedRange(selection)
    fixture.textView.textStorage?.addAttribute(
      preservedAttribute,
      value: "visible-source-highlight",
      range: selection
    )

    XCTAssertTrue(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    let document = try XCTUnwrap(fixture.coordinator.readOnlyPresentationDocument)
    XCTAssertEqual(document.installedAttachments.count, 0)
    XCTAssertEqual(document.attributedString.length, (source as NSString).length)
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertFalse(fixture.textView.isEditable)
    XCTAssertTrue(fixture.textView.isSelectable)

    fixture.coordinator.restoreEditableMarkdown(in: fixture.textView)
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertEqual(fixture.textView.selectedRange(), selection)
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertNil(fixture.coordinator.readOnlyPresentationDocument)
    XCTAssertEqual(
      fixture.textView.textStorage?.attribute(
        preservedAttribute,
        at: selection.location,
        effectiveRange: nil
      ) as? String,
      "visible-source-highlight"
    )
  }

  func testInvalidBodyContextStillRejectsPresentation() {
    let source = "# Title\n\n**bold**"
    let fixture = makeFixture(
      source: source,
      isEnabled: true,
      bodyMarkdown: "different body"
    )
    defer { fixture.close() }

    XCTAssertFalse(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertNil(fixture.coordinator.readOnlyPresentationDocument)
  }

  func testTextViewSourceMismatchStillRejectsPresentation() {
    let source = "# Title\n\n**bold**"
    let fixture = makeFixture(source: source, isEnabled: true)
    defer { fixture.close() }
    fixture.textView.string = "different source"

    XCTAssertFalse(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    XCTAssertEqual(fixture.textView.string, "different source")
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertNil(fixture.coordinator.readOnlyPresentationDocument)
  }

  func testPresentationIsReadOnlyAndRestorePreservesSourceSelectionAndUndoState() throws {
    let source = "prefix $x$ suffix"
    let sourceFormulaRange = (source as NSString).range(of: "$x$")
    let fixture = makeFixture(source: source, isEnabled: true)
    defer { fixture.close() }
    fixture.textView.setSelectedRange(sourceFormulaRange)
    let couldUndoBeforePresentation = fixture.textView.undoManager?.canUndo ?? false

    XCTAssertTrue(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    let presentationDocument = try XCTUnwrap(
      fixture.coordinator.readOnlyPresentationDocument
    )
    XCTAssertEqual(fixture.textView.string, "prefix \u{FFFC} suffix")
    XCTAssertFalse(fixture.textView.isEditable)
    XCTAssertTrue(fixture.textView.isSelectable)
    XCTAssertFalse(fixture.textView.usesFindBar)
    XCTAssertEqual(fixture.state.text, source)
    XCTAssertNil(fixture.coordinator.pendingTextBindingValue)
    XCTAssertEqual(
      fixture.textView.undoManager?.canUndo ?? false,
      couldUndoBeforePresentation
    )

    let presentationFormulaRange = try XCTUnwrap(
      presentationDocument.presentationRange(forSourceRange: sourceFormulaRange)
    )
    fixture.textView.setSelectedRange(presentationFormulaRange)
    fixture.coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: fixture.textView)
    )
    XCTAssertEqual(
      fixture.coordinator.pendingSelectedRangeBindingValue,
      sourceFormulaRange
    )

    fixture.coordinator.restoreEditableMarkdown(in: fixture.textView)
    fixture.coordinator.flushPendingBindingWrites()
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertTrue(fixture.textView.usesFindBar)
    XCTAssertEqual(fixture.textView.selectedRange(), sourceFormulaRange)
    XCTAssertEqual(fixture.state.text, source)
    XCTAssertEqual(fixture.state.selectedRange, sourceFormulaRange)
    XCTAssertNil(fixture.coordinator.readOnlyPresentationDocument)
    XCTAssertEqual(
      fixture.textView.undoManager?.canUndo ?? false,
      couldUndoBeforePresentation
    )
  }

  func testUnchangedSourceReusesCachedPresentationAfterRefocus() throws {
    let source = "before $x$ after"
    let fixture = makeFixture(source: source, isEnabled: true)
    defer { fixture.close() }

    XCTAssertTrue(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    let firstDocument = try XCTUnwrap(
      fixture.coordinator.readOnlyPresentationDocument
    )
    fixture.coordinator.restoreEditableMarkdown(in: fixture.textView)

    XCTAssertTrue(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    let reusedDocument = try XCTUnwrap(
      fixture.coordinator.readOnlyPresentationDocument
    )
    XCTAssertTrue(reusedDocument === firstDocument)
    XCTAssertEqual(fixture.textView.string, "before \u{FFFC} after")
  }

  func testExternalSourceReplacementRestoresRawSourceBeforeFurtherEditing() {
    let original = "before $x$ after"
    let replacement = "new source 🙂"
    let fixture = makeFixture(source: original, isEnabled: true)
    defer { fixture.close() }

    XCTAssertTrue(fixture.coordinator.showReadOnlyPresentation(in: fixture.textView))
    fixture.coordinator.representedText = replacement
    fixture.coordinator.restoreEditableMarkdown(in: fixture.textView)

    XCTAssertEqual(fixture.textView.string, replacement)
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertNil(fixture.coordinator.readOnlyPresentationDocument)
  }

  func testFocusBridgeInstallsAfterResignAndRestoresBeforeRefocus() async {
    let source = "before $x$ after"
    let fixture = makeFixture(source: source, isEnabled: true)
    defer { fixture.close() }
    fixture.coordinator.configureReadOnlyPresentationFocusBridge(on: fixture.textView)

    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertTrue(fixture.textView.isEditable)

    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.sibling))
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(fixture.textView.string, "before \u{FFFC} after")
    XCTAssertFalse(fixture.textView.isEditable)

    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
    XCTAssertEqual(fixture.textView.string, source)
    XCTAssertTrue(fixture.textView.isEditable)
    XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
  }

  private func makeFixture(
    source: String,
    isEnabled: Bool,
    bodyMarkdown: String? = nil,
    bodyUTF16Offset: Int = 0
  ) -> ReadOnlyPresentationFixture {
    let state = ReadOnlyPresentationBindingState(source: source)
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { state.text },
        set: { state.text = $0 }
      ),
      bodyMarkdown: bodyMarkdown ?? source,
      bodyUTF16Offset: bodyUTF16Offset,
      selectedRange: Binding(
        get: { state.selectedRange },
        set: { state.selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { state.isFrontMatterSelection },
        set: { state.isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      attachments: [],
      readOnlyNativePresentationEnabled: isEnabled,
      ghostText: "",
      ssgSnippets: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onGhostTextAccepted: { _ in },
      onGhostTextDismissed: {},
      onSSGSnippetShortcut: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in },
      onDroppedMarkdown: { _, _, _ in }
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    textView.allowsUndo = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.delegate = coordinator

    let sibling = ReadOnlyPresentationTestResponderView(
      frame: NSRect(x: 0, y: 485, width: 640, height: 20)
    )
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
    textView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    root.addSubview(textView)
    root.addSubview(sibling)
    let window = NSWindow(
      contentRect: root.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = root
    XCTAssertTrue(window.makeFirstResponder(sibling))
    return ReadOnlyPresentationFixture(
      state: state,
      coordinator: coordinator,
      textView: textView,
      sibling: sibling,
      window: window
    )
  }
}

@MainActor
private final class ReadOnlyPresentationFixture {
  let state: ReadOnlyPresentationBindingState
  let coordinator: MacMarkdownTextView.Coordinator
  let textView: DroppableMarkdownTextView
  let sibling: NSView
  let window: NSWindow

  init(
    state: ReadOnlyPresentationBindingState,
    coordinator: MacMarkdownTextView.Coordinator,
    textView: DroppableMarkdownTextView,
    sibling: NSView,
    window: NSWindow
  ) {
    self.state = state
    self.coordinator = coordinator
    self.textView = textView
    self.sibling = sibling
    self.window = window
  }

  func close() {
    coordinator.cancelReadOnlyPresentationTasks()
    textView.willBecomeFirstResponderHandler = nil
    textView.didResignFirstResponderHandler = nil
    textView.delegate = nil
    _ = window.makeFirstResponder(nil)
    window.orderOut(nil)
  }
}

@MainActor
private final class ReadOnlyPresentationBindingState {
  var text: String
  var selectedRange = NSRange(location: 0, length: 0)
  var isFrontMatterSelection = false

  init(source: String) {
    text = source
  }
}

private final class ReadOnlyPresentationTestResponderView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
