import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownTextViewFocusLifecycleTests: XCTestCase {
  func testWindowFocusLifecycleOrdersPreparationAndSuccessfulResignation() {
    let textView = makeTextView()
    let sibling = makeSiblingResponder()
    let window = makeWindow(textView: textView, sibling: sibling)
    defer {
      _ = window.makeFirstResponder(nil)
      window.orderOut(nil)
    }

    var events: [String] = []
    textView.willBecomeFirstResponderHandler = {
      events.append("prepare")
    }
    textView.didResignFirstResponderHandler = {
      events.append("resign")
    }

    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.firstResponder === textView)
    XCTAssertEqual(events, ["prepare"])

    XCTAssertTrue(window.makeFirstResponder(sibling))
    XCTAssertTrue(window.firstResponder === sibling)
    XCTAssertEqual(events, ["prepare", "resign"])

    // A second resign request after the successful transition is a no-op and
    // must not emit another lifecycle notification.
    _ = textView.resignFirstResponder()
    XCTAssertEqual(events, ["prepare", "resign"])

    // A later focus cycle gets one fresh pair of notifications.
    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.makeFirstResponder(sibling))
    XCTAssertEqual(events, ["prepare", "resign", "prepare", "resign"])
  }

  func testReentrantLifecycleHandlersDoNotDuplicateNotifications() {
    let textView = makeTextView()
    let sibling = makeSiblingResponder()
    let window = makeWindow(textView: textView, sibling: sibling)
    defer {
      _ = window.makeFirstResponder(nil)
      window.orderOut(nil)
    }

    var prepareCount = 0
    var resignCount = 0
    textView.willBecomeFirstResponderHandler = {
      prepareCount += 1
      _ = window.makeFirstResponder(textView)
    }
    textView.didResignFirstResponderHandler = {
      resignCount += 1
      _ = textView.resignFirstResponder()
    }

    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.makeFirstResponder(sibling))
    XCTAssertEqual(prepareCount, 1)
    XCTAssertEqual(resignCount, 1)
  }

  func testFocusLifecycleWithoutHandlersPreservesResponderBehavior() {
    let textView = makeTextView()
    let sibling = makeSiblingResponder()
    let window = makeWindow(textView: textView, sibling: sibling)
    defer {
      _ = window.makeFirstResponder(nil)
      window.orderOut(nil)
    }

    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.firstResponder === textView)
    XCTAssertTrue(window.makeFirstResponder(sibling))
    XCTAssertTrue(window.firstResponder === sibling)
  }

  func testReadOnlyPresentationFocusCycleRestoresSelectionSnapshotAndEditing() async throws {
    let source = "before $x$ after"
    let sourceSelection = (source as NSString).range(of: "$x$")
    let preservedAttribute = NSAttributedString.Key("repopress.focus-cycle-highlight")
    let state = FocusLifecyclePresentationBindingState(source: source)
    let coordinator = makeReadOnlyPresentationCoordinator(state: state)
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 320, height: 180)
    )
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    textView.string = source
    textView.isEditable = true
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.delegate = coordinator
    textView.setSelectedRange(sourceSelection)
    textView.textStorage?.addAttribute(
      preservedAttribute,
      value: "source-highlight",
      range: sourceSelection
    )

    let sibling = makeSiblingResponder()
    let window = makeWindow(textView: textView, sibling: sibling)
    coordinator.configureReadOnlyPresentationFocusBridge(on: textView)
    defer {
      coordinator.cancelReadOnlyPresentationTasks()
      textView.willBecomeFirstResponderHandler = nil
      textView.didResignFirstResponderHandler = nil
      textView.delegate = nil
      _ = window.makeFirstResponder(nil)
      window.orderOut(nil)
    }

    // This is a programmatic AppKit responder transition. It proves the
    // source starts editable before the projection is installed, without any
    // screen click or synthetic mouse event.
    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.firstResponder === textView)
    XCTAssertTrue(textView.isEditable)
    XCTAssertTrue(textView.isSelectable)
    XCTAssertEqual(textView.selectedRange(), sourceSelection)
    XCTAssertEqual(
      textView.textStorage?.attribute(
        preservedAttribute,
        at: sourceSelection.location,
        effectiveRange: nil
      ) as? String,
      "source-highlight"
    )

    // Resigning schedules the derived presentation after AppKit completes the
    // focus transition. Yielding here is intentional: it tests that lifecycle
    // boundary rather than invoking the coordinator directly.
    XCTAssertTrue(window.makeFirstResponder(sibling))
    for _ in 0..<50 where coordinator.readOnlyPresentationDocument == nil {
      await Task.yield()
      try await Task.sleep(for: .milliseconds(2))
    }

    let presentationDocument = try XCTUnwrap(
      coordinator.readOnlyPresentationDocument
    )
    XCTAssertEqual(textView.string, "before \u{FFFC} after")
    XCTAssertFalse(textView.isEditable)
    XCTAssertTrue(textView.isSelectable)
    let expectedPresentationSelection = try XCTUnwrap(
      presentationDocument.presentationRange(forSourceRange: sourceSelection)
    )
    XCTAssertEqual(textView.selectedRange(), expectedPresentationSelection)
    XCTAssertEqual(
      presentationDocument.sourceRange(
        forPresentationRange: textView.selectedRange()
      ),
      sourceSelection
    )
    XCTAssertEqual(
      coordinator.readOnlyPresentationEditableAttributedSnapshot?.attribute(
        preservedAttribute,
        at: sourceSelection.location,
        effectiveRange: nil
      ) as? String,
      "source-highlight"
    )
    XCTAssertEqual(state.text, source)

    // Refocusing restores the captured editable attributed source before the
    // responder transition completes. Verify both source selection mapping and
    // the ability to continue editing through NSTextView's real insertion API.
    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.firstResponder === textView)
    XCTAssertTrue(textView.isEditable)
    XCTAssertTrue(textView.isSelectable)
    XCTAssertEqual(textView.string, source)
    XCTAssertEqual(textView.selectedRange(), sourceSelection)
    XCTAssertEqual(
      textView.textStorage?.attribute(
        preservedAttribute,
        at: sourceSelection.location,
        effectiveRange: nil
      ) as? String,
      "source-highlight"
    )
    XCTAssertNil(coordinator.readOnlyPresentationEditableAttributedSnapshot)

    let insertionRange = NSRange(
      location: (source as NSString).length,
      length: 0
    )
    textView.setSelectedRange(insertionRange)
    textView.insertText("!", replacementRange: insertionRange)
    XCTAssertEqual(textView.string, source + "!")
    XCTAssertTrue(textView.isEditable)
  }

  private func makeReadOnlyPresentationCoordinator(
    state: FocusLifecyclePresentationBindingState
  ) -> MacMarkdownTextView.Coordinator {
    MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { state.text },
        set: { state.text = $0 }
      ),
      bodyMarkdown: state.text,
      bodyUTF16Offset: 0,
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
      readOnlyNativePresentationEnabled: true,
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
  }

  private func makeTextView() -> DroppableMarkdownTextView {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 320, height: 180)
    )
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    return textView
  }

  private func makeSiblingResponder() -> NSView {
    FocusLifecycleTestResponderView(
      frame: NSRect(x: 0, y: 185, width: 320, height: 24)
    )
  }

  private func makeWindow(
    textView: DroppableMarkdownTextView,
    sibling: NSView
  ) -> NSWindow {
    let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
    rootView.addSubview(textView)
    rootView.addSubview(sibling)

    let window = NSWindow(
      contentRect: rootView.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = rootView
    return window
  }
}

@MainActor
private final class FocusLifecyclePresentationBindingState {
  var text: String
  var selectedRange = NSRange(location: 0, length: 0)
  var isFrontMatterSelection = false

  init(source: String) {
    text = source
  }
}

private final class FocusLifecycleTestResponderView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
