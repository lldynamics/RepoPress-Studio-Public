import AppKit
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionCoordinatorTests: MarkdownEditorAppKitInteractionTestCase
{
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
      onScrollPositionChanged: { _ in },
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

  func testLiveEditsCoalesceBindingsButCallLiveBodyObserverImmediately() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    var selectionWriteCount = 0
    var frontMatterWriteCount = 0
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
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
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text

    for updatedText in ["正文一", "正文二"] {
      textView.string = updatedText
      coordinator.textDidChange(
        Notification(name: NSText.didChangeNotification, object: textView)
      )
    }
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(text, "正文")
    XCTAssertEqual(selectedRange, NSRange(location: 0, length: 0))
    XCTAssertEqual(textWriteCount, 0)
    XCTAssertEqual(selectionWriteCount, 0)
    XCTAssertEqual(frontMatterWriteCount, 0)
    XCTAssertEqual(
      liveBodyChanges.map { $0.0 },
      ["正文", "正文一"]
    )
    XCTAssertEqual(
      liveBodyChanges.map { $0.1 },
      ["正文一", "正文二"]
    )

    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "正文二")
    XCTAssertEqual(selectedRange, NSRange(location: 2, length: 0))
    XCTAssertEqual(textWriteCount, 1)
    XCTAssertEqual(selectionWriteCount, 1)
    XCTAssertEqual(frontMatterWriteCount, 0)
  }

  func testMarkedTextCompositionSkipsPairingAndStagesCommittedBodyWithoutStaleBindingEcho() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
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
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    // This models an IME preedit. The delegate must not turn a marked "(" into
    // "()" while the input method is still composing.
    textView.setMarkedText(
      "n",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0)
    )
    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.markedRange(), NSRange(location: 0, length: 1))
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: textView.markedRange(),
        replacementString: "("
      )
    )
    XCTAssertEqual(textView.string, "n正文")
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(liveBodyChanges.last?.1, "n正文")
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)

    // Committing the preedit replaces only its marked range and clears the
    // marked state. textDidChange must publish this committed body immediately
    // to the live channel while the SwiftUI binding remains coalesced.
    textView.insertText("你", replacementRange: textView.markedRange())
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "你正文")
    XCTAssertEqual(liveBodyChanges.last?.1, "你正文")
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)

    coordinator.flushPendingBindingWrites()
    XCTAssertEqual(text, "你正文")
    XCTAssertEqual(textWriteCount, 1)
  }

  func testSimulatedIMEPreeditUpdatesReplacePreviousMarkedTextAndCommitSelection() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
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
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    // This is a deterministic NSTextInputClient lifecycle simulation. It
    // exercises NSTextView's public marked-text calls, but does not prove a
    // live keyboard/input-source session in the real editor window.
    // Starting with a punctuation preedit also proves that automatic pairing
    // is disabled before the first marked-text update reaches the coordinator.
    textView.setMarkedText(
      "(",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: selectedRange
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "(正文")
    XCTAssertEqual(textView.markedRange(), NSRange(location: 0, length: 1))
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))

    // Updating a preedit replaces the prior marked range rather than inserting
    // a second copy into the document.
    textView.setMarkedText(
      "ni",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: textView.markedRange()
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")
    XCTAssertEqual(textView.markedRange(), NSRange(location: 0, length: 2))
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

    // Candidate submission is the NSTextInputClient commit path: insertText
    // replaces the marked range, clears composition state, and leaves the
    // caret after the committed candidate. AppKit synchronously delivers the
    // resulting textDidChange notification, so do not dispatch a duplicate.
    textView.insertText("你", replacementRange: textView.markedRange())

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "你正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(
      liveBodyChanges.map { $0.1 },
      ["(正文", "ni正文", "你正文"]
    )

    // A SwiftUI update carrying the old body/caret must not overwrite the
    // live committed NSTextView state before the trailing binding flush.
    XCTAssertFalse(coordinator.updateRepresentedText("正文"))
    XCTAssertFalse(
      coordinator.shouldApplyRepresentedSelection(
        selectedRange: NSRange(location: 0, length: 0),
        isFrontMatterSelection: false,
        in: textView
      )
    )
    XCTAssertEqual(textView.string, "你正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(selectedRange, NSRange(location: 0, length: 0))
    XCTAssertEqual(textWriteCount, 0)

    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "你正文")
    XCTAssertEqual(selectedRange, NSRange(location: 1, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
    XCTAssertEqual(textWriteCount, 1)
  }

  func testSimulatedIMECancelAndUnmarkPathsClearMarkedStateWithoutBindingEcho() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
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
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    // Build a preedit, then exercise NSTextInputClient's unmarkText path.
    textView.setMarkedText(
      "ni",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: selectedRange
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")

    // AppKit synchronously delivers textDidChange while unmarking, so this
    // call exercises the real notification path without a duplicate dispatch.
    textView.unmarkText()

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)

    // A cancelled composition is represented by replacing the marked range
    // with an empty string. This is separate from unmarkText: cancellation
    // must restore the original body and caret, with no stale binding echo.
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    textView.setMarkedText(
      "hao",
      selectedRange: NSRange(location: 5, length: 0),
      replacementRange: NSRange(location: 2, length: 0)
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "nihao正文")

    let cancellationRange = textView.markedRange()
    textView.setMarkedText(
      "",
      // NSTextView interprets selectedRange relative to replacementRange for
      // an empty marked-text cancellation, so zero means the range's start.
      selectedRange: NSRange(location: 0, length: 0),
      replacementRange: cancellationRange
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")
    XCTAssertEqual(
      textView.selectedRange(),
      NSRange(location: cancellationRange.location, length: 0)
    )
    XCTAssertFalse(coordinator.updateRepresentedText("正文"))
    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "ni正文")
    XCTAssertEqual(selectedRange, NSRange(location: cancellationRange.location, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
    XCTAssertEqual(textWriteCount, 1)
  }

  func testFrontMatterSelectionBindingCoalescesUntilExplicitFlush() {
    var text = "---\n正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var selectionWriteCount = 0
    var frontMatterWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: "正文",
      bodyUTF16Offset: 4,
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
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertFalse(isFrontMatterSelection)
    XCTAssertEqual(frontMatterWriteCount, 0)
    coordinator.flushPendingBindingWrites()

    XCTAssertTrue(isFrontMatterSelection)
    XCTAssertEqual(selectionWriteCount, 0)
    XCTAssertEqual(frontMatterWriteCount, 1)
  }

  func testEditorBindingAndStatisticsPublishOnSeparateIdleEdges() async throws {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var deliveredStatistics: [MarkdownEditorStatistics] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
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
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { deliveredStatistics.append($0) },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = "正文一"
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(text, "正文")
    XCTAssertTrue(deliveredStatistics.isEmpty)

    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(text, "正文一")
    XCTAssertTrue(deliveredStatistics.isEmpty)

    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(deliveredStatistics.last?.characterCount, 3)
  }

  func testStaleSwiftUIEchoDoesNotReplaceLiveTextButExternalTextCancelsPendingWrite() {
    var text = "正文"
    var textWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(get: { NSRange(location: 0, length: 0) }, set: { _ in }),
      isFrontMatterSelection: Binding(get: { false }, set: { _ in }),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = "正文*"
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(coordinator.updateRepresentedText("正文"))
    XCTAssertFalse(coordinator.updateRepresentedText("正文*"))
    XCTAssertTrue(coordinator.updateRepresentedText("外部正文"))
    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)
  }

  func testDismantleFlushesLastLiveTextBinding() {
    var text = "正文"
    var textWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(get: { NSRange(location: 0, length: 0) }, set: { _ in }),
      isFrontMatterSelection: Binding(get: { false }, set: { _ in }),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = "正文最后一个字"
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    let scrollView = NSScrollView()
    scrollView.documentView = textView

    MacMarkdownTextView.dismantleNSView(scrollView, coordinator: coordinator)

    XCTAssertEqual(text, "正文最后一个字")
    XCTAssertEqual(textWriteCount, 1)
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
      onScrollPositionChanged: { _ in },
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
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(
      coordinator.pendingSelectedRangeBindingValue,
      NSRange(location: 1, length: 0)
    )
    coordinator.flushPendingBindingWrites()
    XCTAssertEqual(selectedRange, NSRange(location: 1, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
  }

  func testAutomaticPairingRegistersOneUndoStepAndRestoresOriginalSelection() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
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
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 640, height: 480)
    )
    textView.allowsUndo = true
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = textView
    window.makeFirstResponder(textView)
    defer { window.orderOut(nil) }

    // Go through NSTextView's real insertion route so the delegate callback,
    // paired insertion, and AppKit undo registration are exercised together.
    textView.insertText("(", replacementRange: selectedRange)
    XCTAssertEqual(textView.string, "()正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertTrue(textView.undoManager?.canUndo == true)

    textView.undoManager?.undo()

    XCTAssertEqual(textView.string, "正文")
    XCTAssertEqual(textView.selectedRange(), selectedRange)
    XCTAssertFalse(textView.undoManager?.canUndo == true)
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
      onScrollPositionChanged: { _ in },
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

  func testInvalidFrontMatterSuppressesLiveBodyChangesUntilDocumentIsValidated() {
    let source = "---\ntitle: Old\n---\n\n正文"
    let sourceText = source as NSString
    let originalBodyRange = sourceText.range(of: "正文")
    var boundText = source
    var selectedRange = NSRange(location: originalBodyRange.location, length: 0)
    var isFrontMatterSelection = false
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      bodyMarkdown: "正文",
      bodyUTF16Offset: originalBodyRange.location,
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
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = source
    textView.delegate = coordinator

    let closingDelimiterRange = sourceText.range(of: "---", options: .backwards)
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: closingDelimiterRange,
        replacementString: "--x"
      )
    )
    let invalidDocument = sourceText.replacingCharacters(
      in: closingDelimiterRange,
      with: "--x"
    )
    textView.string = invalidDocument
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(coordinator.hasValidDocumentBodyMapping)
    XCTAssertTrue(coordinator.isAwaitingDocumentValidation)
    XCTAssertEqual(coordinator.bodyMarkdown, "正文")
    XCTAssertTrue(liveBodyChanges.isEmpty)

    coordinator.flushPendingBindingWrites()
    coordinator.updateDocumentContext(
      bodyMarkdown: "正文",
      bodyUTF16Offset: originalBodyRange.location,
      allowsLiveBodyChanges: false,
      attachments: [],
      in: textView
    )

    let invalidSource = invalidDocument as NSString
    let invalidBodyRange = invalidSource.range(of: "正文")
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: invalidBodyRange,
        replacementString: "新正文"
      )
    )
    let invalidDocumentWithEditedBody = invalidSource.replacingCharacters(
      in: invalidBodyRange,
      with: "新正文"
    )
    textView.string = invalidDocumentWithEditedBody
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(coordinator.bodyMarkdown, "正文")
    XCTAssertTrue(liveBodyChanges.isEmpty)

    coordinator.flushPendingBindingWrites()
    coordinator.updateDocumentContext(
      bodyMarkdown: "正文",
      bodyUTF16Offset: originalBodyRange.location,
      allowsLiveBodyChanges: false,
      attachments: [],
      in: textView
    )

    let recoverableSource = invalidDocumentWithEditedBody as NSString
    let brokenDelimiterRange = recoverableSource.range(of: "--x", options: .backwards)
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: brokenDelimiterRange,
        replacementString: "---"
      )
    )
    let recoveredDocument = recoverableSource.replacingCharacters(
      in: brokenDelimiterRange,
      with: "---"
    )
    textView.string = recoveredDocument
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertTrue(coordinator.hasValidDocumentBodyMapping)
    XCTAssertEqual(coordinator.bodyMarkdown, "新正文")
    XCTAssertTrue(liveBodyChanges.isEmpty)

    coordinator.flushPendingBindingWrites()
    let recoveredBodyRange = (recoveredDocument as NSString).range(of: "新正文")
    coordinator.updateDocumentContext(
      bodyMarkdown: "新正文",
      bodyUTF16Offset: recoveredBodyRange.location,
      allowsLiveBodyChanges: true,
      attachments: [],
      in: textView
    )

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: recoveredBodyRange,
        replacementString: "已恢复正文"
      )
    )
    textView.string = (recoveredDocument as NSString).replacingCharacters(
      in: recoveredBodyRange,
      with: "已恢复正文"
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(liveBodyChanges.count, 1)
    XCTAssertEqual(liveBodyChanges.first?.0, "新正文")
    XCTAssertEqual(liveBodyChanges.first?.1, "已恢复正文")
    coordinator.invalidateHighlightedTextCache()
  }

}
