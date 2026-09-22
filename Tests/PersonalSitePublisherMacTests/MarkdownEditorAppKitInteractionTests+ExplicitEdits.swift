import AppKit
import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionExplicitEditTests:
  MarkdownEditorAppKitInteractionTestCase
{
  func testOldEditRequestCannotOverwriteLiveTextAheadOfBindingPublication() {
    let coordinator = makeCoordinator(source: "甲乙", bodyMarkdown: "甲乙", bodyUTF16Offset: 0)
    let view = makeTextView()
    view.string = "甲丙"
    let request = MarkdownTextEditRequest(
      expectedText: "甲乙",
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 0, length: 2), replacement: "一二",
        selectedRange: NSRange(location: 0, length: 0)
      )
    )
    XCTAssertEqual(coordinator.handle(request, in: view)?.wasApplied, false)
    XCTAssertEqual(view.string, "甲丙")
  }

  func testExplicitEditMatchesActualBodyAfterFrontMatterAndRemainsUndoable() {
    let prefix = "---\ntitle: 示例\n---\n"
    let body = "甲😀乙"
    let coordinator = makeCoordinator(
      source: prefix + body, bodyMarkdown: body, bodyUTF16Offset: (prefix as NSString).length
    )
    let view = makeTextView()
    view.string = prefix + body
    view.allowsUndo = true
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    defer { window.orderOut(nil) }
    let request = MarkdownTextEditRequest(
      expectedText: body,
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 1, length: 2), replacement: "新",
        selectedRange: NSRange(location: 2, length: 0)
      )
    )
    XCTAssertEqual(coordinator.handle(request, in: view)?.wasApplied, true)
    XCTAssertEqual(view.string, prefix + "甲新乙")
    XCTAssertTrue(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(view.string, prefix + body)
  }

  func testExternalFrontMatterReplacementClearsStaleBodyUndoRanges() {
    let oldTitle = "Old"
    let prefix = "---\ntitle: \(oldTitle)\n---\n"
    let body = "Hello world"
    let coordinator = makeCoordinator(
      source: prefix + body,
      bodyMarkdown: body,
      bodyUTF16Offset: (prefix as NSString).length
    )
    let view = makeTextView()
    view.string = prefix + body
    view.allowsUndo = true
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    defer { window.orderOut(nil) }

    let bodyEnd = (view.string as NSString).length
    view.setSelectedRange(NSRange(location: bodyEnd, length: 0))
    view.insertText("X", replacementRange: view.selectedRange())
    XCTAssertTrue(view.undoManager?.canUndo == true)

    let updated = view.string.replacingOccurrences(of: oldTitle, with: "A much longer title")
    coordinator.replaceDocumentTextFromExternalUpdate(updated, in: view)

    XCTAssertEqual(view.string, updated)
    XCTAssertFalse(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(view.string, updated)
  }

  func testTerminationFlushCommitsInvalidFrontMatterThroughMountedComposerBeforeSafeStoreSnapshot()
    async throws
  {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkdownTerminationFlush-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let originalDraft = try XCTUnwrap(store.selectedDraft)
    var boundDraft = originalDraft
    let composer = MacMarkdownComposerView(
      draft: Binding(
        get: { store.draft(for: originalDraft.id) ?? boundDraft },
        set: { updated in
          boundDraft = updated
          XCTAssertTrue(store.updateDraftFromEditor(updated))
        }
      ),
      store: store
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(
      rootView:
        composer
        .environmentObject(WorkspaceSceneCommandRouter())
        .frame(width: 900, height: 700)
    )
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    let textView = try await mountedMarkdownTextView(in: window)
    let coordinator = try XCTUnwrap(textView.delegate as? MacMarkdownTextView.Coordinator)
    let source = textView.string
    let updated = "---\ntitle broken\n---\n\(originalDraft.bodyMarkdown)"
    textView.string = updated
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

    MacMarkdownEditorTerminationFlushRegistry.flushPendingWritesForTermination()

    XCTAssertEqual(
      store.markdownEditorSessionState(for: originalDraft.id).invalidFrontMatterDocument, updated)
    let terminationResult = await store.prepareForSafeTermination()
    XCTAssertEqual(terminationResult, .saved)
    let reloaded = WorkbenchStore(persistence: persistence, safeMode: true)
    XCTAssertEqual(
      reloaded.markdownEditorSessionState(for: originalDraft.id).invalidFrontMatterDocument,
      updated
    )
    XCTAssertNotEqual(source, updated)
  }

  func testMountedComposerKeepsNewestLocalTextThenAcceptsExternalRevision() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkdownComposerSynchronization-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let originalDraft = try XCTUnwrap(store.selectedDraft)
    var boundDraft = originalDraft
    let composer = MacMarkdownComposerView(
      draft: Binding(
        get: { store.draft(for: originalDraft.id) ?? boundDraft },
        set: { updated in
          boundDraft = updated
          XCTAssertTrue(store.updateDraftFromEditor(updated))
        }
      ),
      store: store
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(
      rootView:
        composer
        .environmentObject(WorkspaceSceneCommandRouter())
        .frame(width: 900, height: 700)
    )
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    let textView = try await mountedMarkdownTextView(in: window)
    textView.setSelectedRange(
      NSRange(location: (textView.string as NSString).length, length: 0)
    )
    textView.insertText("\n", replacementRange: textView.selectedRange())
    textView.insertText("/", replacementRange: textView.selectedRange())

    // Let the normal coalesced AppKit binding flush and both SwiftUI observer
    // lanes settle. The old intermediate body must not replace this final
    // document or move its caret back to the session's initial selection.
    try await Task.sleep(for: .milliseconds(400))
    let expectedLocalBody = originalDraft.bodyMarkdown + "\n/"
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: originalDraft.id).bodyMarkdown, expectedLocalBody)
    XCTAssertTrue(textView.string.hasSuffix("\n/"))
    XCTAssertEqual(
      textView.selectedRange(),
      NSRange(location: (textView.string as NSString).length, length: 0)
    )

    let localBuffer = store.draftBodyEditorBuffer(for: originalDraft.id)
    let externalBody = expectedLocalBody + "外部"
    let external = try XCTUnwrap(
      store.stageDraftBody(
        externalBody,
        for: originalDraft.id,
        baseRevision: localBuffer.revision,
        replacingBaseBody: localBuffer.bodyMarkdown,
        notifyEditorObservers: true
      )
    )
    XCTAssertTrue(external.wasAccepted)

    // A different Store revision represents another editor/window and must
    // still replace the mounted text view after the bridge has suppressed only
    // its own unflushed live revisions.
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(store.draftBodyEditorBuffer(for: originalDraft.id).bodyMarkdown, externalBody)
    XCTAssertTrue(textView.string.hasSuffix(externalBody))
  }

  func testMountedComposerReevaluatesSlashTriggerWhenCaretArrivesAfterBody() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkdownComposerSlashSelection-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let originalDraft = try XCTUnwrap(store.selectedDraft)
    var boundDraft = originalDraft
    let composer = MacMarkdownComposerView(
      draft: Binding(
        get: { store.draft(for: originalDraft.id) ?? boundDraft },
        set: { updated in
          boundDraft = updated
          XCTAssertTrue(store.updateDraftFromEditor(updated))
        }
      ),
      store: store
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(
      rootView:
        composer
        .environmentObject(WorkspaceSceneCommandRouter())
        .frame(width: 900, height: 700)
    )
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    let textView = try await mountedMarkdownTextView(in: window)
    XCTAssertTrue(window.makeFirstResponder(textView))
    XCTAssertTrue(window.firstResponder === textView)
    let coordinator = try XCTUnwrap(textView.delegate as? MacMarkdownTextView.Coordinator)
    let bodyStart =
      (textView.string as NSString).length - (originalDraft.bodyMarkdown as NSString).length
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    textView.insertText("\n/", replacementRange: textView.selectedRange())
    textView.setSelectedRange(NSRange(location: bodyStart, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView))

    // The body observer can settle while its selection observer still reports
    // the beginning of the body. Moving only the caret afterwards must reopen
    // the slash command path without another text edit.
    try await Task.sleep(for: .milliseconds(400))
    let expectedBody = originalDraft.bodyMarkdown + "\n/"
    XCTAssertEqual(store.draftBodyEditorBuffer(for: originalDraft.id).bodyMarkdown, expectedBody)
    XCTAssertEqual(textView.selectedRange(), NSRange(location: bodyStart, length: 0))
    XCTAssertEqual(textView.slashCommandKeyHandler?(.moveDown), false)

    let documentEnd = NSRange(location: (textView.string as NSString).length, length: 0)
    textView.setSelectedRange(documentEnd)
    XCTAssertEqual(
      textView.selectedRange(),
      documentEnd,
      "The native text view must receive the late caret before its delegate publishes it."
    )
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    XCTAssertEqual(
      coordinator.pendingSelectedRangeBindingValue,
      NSRange(location: (expectedBody as NSString).length, length: 0),
      "The existing selection delegate must enqueue the body-relative late caret."
    )
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(
      coordinator.selectedRange,
      NSRange(location: (expectedBody as NSString).length, length: 0),
      "The mounted editor must publish the late caret into its SwiftUI binding."
    )
    XCTAssertEqual(textView.slashCommandKeyHandler?(.moveDown), true)

    let selectEvent = try XCTUnwrap(makeKeyEvent(keyCode: 36))
    textView.keyDown(with: selectEvent)
    XCTAssertTrue(textView.string.hasSuffix("\n## "))
    XCTAssertEqual(
      textView.selectedRange(),
      NSRange(location: (textView.string as NSString).length, length: 0)
    )
    textView.insertText("NEXT_INPUT", replacementRange: textView.selectedRange())
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(textView.string.hasSuffix("\n## NEXT_INPUT"))
    XCTAssertTrue(
      store.draftBodyEditorBuffer(for: originalDraft.id).bodyMarkdown.hasSuffix("\n## NEXT_INPUT")
    )
  }

  func testMountedLongDocumentSelectionRevealKeepsMeasuredHeightCache() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkdownSelectionReveal-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json")),
      safeMode: true
    )
    var initialDraft = try XCTUnwrap(store.selectedDraft)
    initialDraft.bodyMarkdown = (0..<240).map { index in
      "第 \(index) 段：长文档中的选择移动只应布局目标光标附近，不应重新测量整篇正文高度。"
    }.joined(separator: "\n\n")
    store.updateDraft(initialDraft)
    let draft = try XCTUnwrap(store.draft(for: initialDraft.id))
    var boundDraft = draft
    let composer = MacMarkdownComposerView(
      draft: Binding(
        get: { store.draft(for: draft.id) ?? boundDraft },
        set: { updated in
          boundDraft = updated
          XCTAssertTrue(store.updateDraftFromEditor(updated))
        }
      ),
      store: store
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .titled,
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(
      rootView:
        composer
        .environmentObject(WorkspaceSceneCommandRouter())
        .frame(width: 900, height: 700)
    )
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    let textView = try await mountedMarkdownTextView(in: window)
    let scrollView = try XCTUnwrap(textView.enclosingScrollView as? MarkdownEditorScrollView)
    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    try await Task.sleep(for: .milliseconds(160))
    window.layoutIfNeeded()
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    scrollView.invalidateDocumentHeight(immediately: true)
    scrollView.layoutSubtreeIfNeeded()
    let cachedHeight = try XCTUnwrap(scrollView.cachedDocumentHeightForTesting)
    XCTAssertGreaterThan(textView.frame.height, scrollView.documentVisibleRect.height * 2)

    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let bodyStart =
      (textView.string as NSString).length - (initialDraft.bodyMarkdown as NSString).length
    let visibleRange = NSRange(location: bodyStart, length: 1)
    let visibleRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: visibleRange, in: textView)
    )
    XCTAssertTrue(scrollView.documentVisibleRect.intersects(visibleRect))
    XCTAssertTrue(window.makeFirstResponder(textView))
    textView.setSelectedRange(visibleRange)
    let coordinator = try XCTUnwrap(textView.delegate as? MacMarkdownTextView.Coordinator)
    defer { coordinator.flushPendingBindingWrites() }
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )
    scrollView.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      try XCTUnwrap(scrollView.cachedDocumentHeightForTesting),
      cachedHeight,
      accuracy: 0.01
    )
    XCTAssertTrue(scrollView.documentVisibleRect.intersects(visibleRect))
  }

  func testMountedComposerEOFInputKeepsCaretInManuallyScrolledViewport() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )
    )
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: fixture.imageURL)
    let persistence = WorkbenchPersistence(
      fileURL: fixture.root.appendingPathComponent("workbench.json")
    )
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    var initialDraft = try XCTUnwrap(store.selectedDraft)
    let longBody =
      "![cover](cover.png)\n\n"
      + "行内公式 $E = mc^2$ 与图片都在这篇跨屏文章中。\n\n"
      + "$$\nE = mc^2 + \\frac{a}{b}\n$$\n\n"
      + (0..<96).map { index in
        "第 \(index) 段：编辑器需要保留文末输入位置，避免正文同步后把已滚动到末尾的视口拉回文章开头。"
      }.joined(separator: "\n\n")
    initialDraft.title = "文末输入视口回归"
    initialDraft.bodyMarkdown = longBody
    initialDraft.attachments = [
      DraftAttachment(
        originalFilename: "cover.png",
        relativePublishPath: "cover.png",
        repositoryPath: "cover.png",
        sourceFilePath: fixture.imageURL.path
      )
    ]
    store.updateDraft(initialDraft)

    let draft = try XCTUnwrap(store.draft(for: initialDraft.id))
    var boundDraft = draft
    let composer = MacMarkdownComposerView(
      draft: Binding(
        get: { store.draft(for: draft.id) ?? boundDraft },
        set: { updated in
          boundDraft = updated
          XCTAssertTrue(store.updateDraftFromEditor(updated))
        }
      ),
      store: store
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .titled,
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(
      rootView:
        composer
        .environmentObject(WorkspaceSceneCommandRouter())
        .frame(width: 900, height: 700)
    )
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    let textView = try await mountedMarkdownTextView(in: window)
    let scrollView = try XCTUnwrap(textView.enclosingScrollView as? MarkdownEditorScrollView)
    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    // The SwiftUI host first installs the representable with a provisional
    // width, then the editor's 75ms deferred reflow applies the window width.
    // Do not treat that startup layout as the viewport under test.
    try await Task.sleep(for: .milliseconds(160))
    window.layoutIfNeeded()
    window.displayIfNeeded()
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    scrollView.invalidateDocumentHeight(immediately: true)
    scrollView.layoutSubtreeIfNeeded()

    let initialBodyOffset =
      (textView.string as NSString).length - (longBody as NSString).length
    XCTAssertGreaterThan(initialBodyOffset, 0)
    XCTAssertTrue(textView.string.contains("![cover](cover.png)"))
    XCTAssertTrue(textView.string.contains("$E = mc^2$"))
    XCTAssertGreaterThan(textView.frame.height, scrollView.documentVisibleRect.height * 2)

    let endBeforeInput = NSRange(location: (textView.string as NSString).length, length: 0)
    textView.setSelectedRange(endBeforeInput)
    let endBeforeInputRect = try XCTUnwrap(
      insertionGeometry(for: endBeforeInput, in: textView)
    )
    let viewport = scrollView.documentVisibleRect
    let maximumOriginY = max(0, textView.frame.height - viewport.height)
    scrollView.contentView.scroll(
      to: NSPoint(
        x: viewport.minX,
        y: min(maximumOriginY, max(0, endBeforeInputRect.midY - viewport.height * 0.6))
      )
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    XCTAssertTrue(scrollView.documentVisibleRect.intersects(endBeforeInputRect))
    XCTAssertGreaterThan(scrollView.documentVisibleRect.minY, 0)

    XCTAssertTrue(window.makeFirstResponder(textView))
    textView.insertText("X", replacementRange: textView.selectedRange())

    // The mounted coordinator coalesces native text and selection bindings for
    // 240ms. Wait through that production path, then let SwiftUI finish the
    // resulting document/layout update before inspecting the viewport.
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    window.displayIfNeeded()

    let expectedBody = longBody + "X"
    let expectedDocumentEnd = NSRange(
      location: (textView.string as NSString).length,
      length: 0
    )
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, expectedBody)
    XCTAssertTrue(textView.string.hasSuffix(expectedBody))
    XCTAssertEqual(textView.selectedRange(), expectedDocumentEnd)
    let viewportAfterInput = scrollView.documentVisibleRect
    let caretRect = try XCTUnwrap(
      insertionGeometry(for: expectedDocumentEnd, in: textView)
    )
    XCTAssertTrue(
      viewportAfterInput.intersects(caretRect),
      "The EOF caret must remain in the user-scrolled viewport after normal input."
    )
    XCTAssertGreaterThan(scrollView.documentVisibleRect.minY, 0)

    let frameHeightAfterSingleCharacter = textView.frame.height
    let appendedLines = "\n尾部新增第一行\n尾部新增第二行"
    textView.insertText(appendedLines, replacementRange: textView.selectedRange())
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    window.displayIfNeeded()

    let bodyAfterAppend = expectedBody + appendedLines
    let endAfterAppend = NSRange(location: (textView.string as NSString).length, length: 0)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, bodyAfterAppend)
    XCTAssertEqual(textView.selectedRange(), endAfterAppend)
    XCTAssertGreaterThan(textView.frame.height, frameHeightAfterSingleCharacter)
    let viewportAfterAppend = scrollView.documentVisibleRect
    let caretAfterAppend = try XCTUnwrap(insertionGeometry(for: endAfterAppend, in: textView))
    XCTAssertTrue(
      viewportAfterAppend.intersects(caretAfterAppend)
    )

    let appendedRange = NSRange(
      location: endAfterAppend.location - (appendedLines as NSString).length,
      length: (appendedLines as NSString).length
    )
    let frameHeightAfterAppend = textView.frame.height
    textView.setSelectedRange(appendedRange)
    textView.insertText("", replacementRange: textView.selectedRange())
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    window.displayIfNeeded()

    let endAfterDeletion = NSRange(location: (textView.string as NSString).length, length: 0)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, expectedBody)
    XCTAssertEqual(textView.selectedRange(), endAfterDeletion)
    XCTAssertLessThan(textView.frame.height, frameHeightAfterAppend)
    let viewportAfterDeletion = scrollView.documentVisibleRect
    let caretAfterDeletion = try XCTUnwrap(
      insertionGeometry(for: endAfterDeletion, in: textView)
    )
    XCTAssertTrue(
      viewportAfterDeletion.intersects(caretAfterDeletion)
    )

    var burstBody = expectedBody
    for index in 0..<8 {
      let nextLine = "\nFast input \(index)"
      textView.insertText(nextLine, replacementRange: textView.selectedRange())
      burstBody += nextLine
      // Render each input frame without waiting for a typing pause or the
      // background syntax/attachment height debounce.
      scrollView.layoutSubtreeIfNeeded()
      let burstEnd = NSRange(location: (textView.string as NSString).length, length: 0)
      let burstViewport = scrollView.documentVisibleRect
      let burstCaret = try XCTUnwrap(insertionGeometry(for: burstEnd, in: textView))
      XCTAssertTrue(
        burstViewport.intersects(burstCaret),
        "New lines must stay visible while input continues without a debounce pause."
      )
    }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let settledBurstViewport = scrollView.documentVisibleRect
    let settledBurstCaret = try XCTUnwrap(
      insertionGeometry(for: textView.selectedRange(), in: textView)
    )
    XCTAssertTrue(settledBurstViewport.intersects(settledBurstCaret))
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, burstBody)

    // Complete the input event's native viewport layout before delivering a
    // separate wheel event. Directly changing clip bounds inside insertText's
    // pending layout is not a user scroll and leaves TextKit's reveal queued.
    textView.insertText("\nUser scroll wins", replacementRange: textView.selectedRange())
    scrollView.layoutSubtreeIfNeeded()
    let originBeforeWheel = scrollView.contentView.bounds.minY
    let wheelEvent = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
        wheel1: 10_000, wheel2: 0, wheel3: 0
      ).flatMap { NSEvent(cgEvent: $0) }
    )
    // Reproduce a deferred caret reveal that a user scroll must supersede.
    scrollView.requestSelectionReveal()
    scrollView.scrollWheel(with: wheelEvent)
    // Synthetic wheel events need not run AppKit's native input tracking in
    // XCTest. Exercise our wheel cancellation path, then set the viewport
    // chosen by that user gesture independently of native event delivery.
    let requestedOrigin = max(0, originBeforeWheel - 120)
    scrollView.contentView.scroll(
      to: NSPoint(x: scrollView.contentView.bounds.minX, y: requestedOrigin)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let chosenOrigin = scrollView.contentView.bounds.minY
    XCTAssertEqual(chosenOrigin, requestedOrigin, accuracy: 1)
    XCTAssertLessThan(chosenOrigin, originBeforeWheel)
    scrollView.invalidateDocumentHeight(immediately: true)
    scrollView.layoutSubtreeIfNeeded()
    XCTAssertEqual(scrollView.contentView.bounds.minY, chosenOrigin, accuracy: 1)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown,
      burstBody + "\nUser scroll wins"
    )
  }

  private func insertionGeometry(for range: NSRange, in textView: NSTextView) -> NSRect? {
    guard range.length == 0,
      let layoutManager = textView.textLayoutManager,
      let textRange = MarkdownTextKit2RangeAdapter.textRange(for: range, in: textView)
    else { return nil }

    layoutManager.ensureLayout(for: textRange)
    var insertionRect: NSRect?
    layoutManager.enumerateTextSegments(
      in: textRange,
      type: .standard,
      options: []
    ) { _, rect, _, _ in
      // EOF insertion geometry is intentionally zero-width. Its line height
      // is still meaningful and must not be discarded as an empty NSRect.
      guard rect.height > 0 else { return true }
      insertionRect = NSRect(
        x: rect.minX + textView.textContainerOrigin.x,
        y: rect.minY + textView.textContainerOrigin.y,
        width: max(rect.width, 1),
        height: rect.height
      )
      return false
    }
    if let insertionRect { return insertionRect }

    let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
    guard screenRect.height > 0 else { return nil }
    let windowRect = textView.window?.convertFromScreen(screenRect) ?? screenRect
    let viewRect = textView.convert(windowRect, from: nil)
    return NSRect(
      x: viewRect.minX,
      y: viewRect.minY,
      width: max(viewRect.width, 1),
      height: viewRect.height
    )
  }

  private func mountedMarkdownTextView(in window: NSWindow) async throws
    -> DroppableMarkdownTextView
  {
    for _ in 0..<40 {
      if let textView = markdownTextView(in: window.contentView) {
        return textView
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(
      domain: "MarkdownEditorAppKitInteractionExplicitEditTests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Mounted Composer did not install its native text view."
      ]
    )
  }

  private func markdownTextView(in view: NSView?) -> DroppableMarkdownTextView? {
    guard let view else { return nil }
    if let textView = view as? DroppableMarkdownTextView { return textView }
    for subview in view.subviews {
      if let textView = markdownTextView(in: subview) {
        return textView
      }
    }
    return nil
  }
}

@MainActor
final class MarkdownComposerAttachmentInsertionTests: MarkdownEditorAppKitInteractionTestCase {
  private let selectionEditingService = MarkdownComposerSelectionEditingService()

  func testAttachmentAdmissionRunsOnlyAfterLiveTextValidationAndCanRejectWithoutEditing() {
    let coordinator = makeCoordinator(source: "原文", bodyMarkdown: "原文", bodyUTF16Offset: 0)
    let view = makeTextView()
    view.string = "后来的编辑"
    let edit = MarkdownSmartEdit(
      replacedRange: NSRange(location: 1, length: 0), replacement: "图片",
      selectedRange: NSRange(location: 3, length: 0)
    )
    var admissionCount = 0
    let staleOutcome = coordinator.handle(
      MarkdownTextEditRequest(expectedText: "原文", edit: edit), in: view,
      beforeApply: { _ in
        admissionCount += 1
        return true
      }
    )
    XCTAssertEqual(staleOutcome?.wasApplied, false)
    XCTAssertEqual(admissionCount, 0)
    XCTAssertEqual(view.string, "后来的编辑")

    view.string = "原文"
    let deniedOutcome = coordinator.handle(
      MarkdownTextEditRequest(expectedText: "原文", edit: edit), in: view,
      beforeApply: { _ in
        admissionCount += 1
        return false
      }
    )
    XCTAssertEqual(deniedOutcome?.wasApplied, false)
    XCTAssertEqual(admissionCount, 1)
    XCTAssertEqual(view.string, "原文")
  }

  func testEmptyMiddleSelectionPreservesItsCaretForRawReplacement() {
    let mutation = selectionEditingService.replacingRawSelection(
      in: makeDraft(body: "甲乙丙"),
      selectedRange: NSRange(location: 1, length: 0),
      with: "X"
    )

    XCTAssertEqual(mutation.draft.bodyMarkdown, "甲X乙丙")
    XCTAssertEqual(mutation.selectedRange, NSRange(location: 2, length: 0))
  }

  func testNonemptySelectionIsReplacedRatherThanAppended() {
    let mutation = selectionEditingService.replacingRawSelection(
      in: makeDraft(body: "甲乙丙"),
      selectedRange: NSRange(location: 1, length: 1),
      with: "X"
    )

    XCTAssertEqual(mutation.draft.bodyMarkdown, "甲X丙")
    XCTAssertEqual(mutation.selectedRange, NSRange(location: 2, length: 0))
  }

  func testEmptyEndSelectionStillAppends() {
    let mutation = selectionEditingService.replacingRawSelection(
      in: makeDraft(body: "甲乙丙"),
      selectedRange: NSRange(location: 3, length: 0),
      with: "X"
    )

    XCTAssertEqual(mutation.draft.bodyMarkdown, "甲乙丙X")
    XCTAssertEqual(mutation.selectedRange, NSRange(location: 4, length: 0))
  }

  func testAttachmentSnapshotUsesOriginalSelectionAfterLaterCaretMove() {
    let snapshot = MarkdownComposerAttachmentInsertionSnapshot(
      bodyMarkdown: "甲乙丙",
      selectedRange: NSRange(location: 1, length: 0),
      bodyRevision: 7,
      editorMetadataRevision: 3,
      selectionEditingService: selectionEditingService
    )
    let mutation = snapshot.replacingSelection(
      in: makeDraft(body: "甲乙丙"),
      with: "![图](image.png)",
      selectionEditingService: selectionEditingService
    )

    XCTAssertEqual(mutation.draft.bodyMarkdown, "甲\n![图](image.png)\n乙丙")
    XCTAssertEqual(
      mutation.selectedRange,
      NSRange(location: ("甲\n![图](image.png)\n" as NSString).length, length: 0)
    )
  }

  func testAttachmentSnapshotRejectsChangedBodyOrRevision() {
    let snapshot = MarkdownComposerAttachmentInsertionSnapshot(
      bodyMarkdown: "正文",
      selectedRange: NSRange(location: 1, length: 0),
      bodyRevision: 7,
      editorMetadataRevision: 3,
      selectionEditingService: selectionEditingService
    )

    XCTAssertTrue(
      snapshot.matches(bodyMarkdown: "正文", bodyRevision: 7, editorMetadataRevision: 3)
    )
    XCTAssertFalse(
      snapshot.matches(bodyMarkdown: "新正文", bodyRevision: 7, editorMetadataRevision: 3)
    )
    XCTAssertFalse(
      snapshot.matches(bodyMarkdown: "正文", bodyRevision: 8, editorMetadataRevision: 3)
    )
    XCTAssertFalse(
      snapshot.matches(bodyMarkdown: "正文", bodyRevision: 7, editorMetadataRevision: 4)
    )
  }

  func testAttachmentSnapshotInsertionUsesNativeUndoPath() throws {
    let originalBody = "甲乙丙"
    let body = originalBody + "Z"
    let snapshot = MarkdownComposerAttachmentInsertionSnapshot(
      bodyMarkdown: body,
      selectedRange: NSRange(location: 1, length: 0),
      bodyRevision: 0,
      editorMetadataRevision: 0,
      selectionEditingService: selectionEditingService
    )
    let mutation = snapshot.replacingSelection(
      in: makeDraft(body: body),
      with: "![图](image.png)",
      selectionEditingService: selectionEditingService
    )
    let coordinator = makeCoordinator(
      source: originalBody,
      bodyMarkdown: originalBody,
      bodyUTF16Offset: 0
    )
    let view = makeTextView()
    view.string = originalBody
    view.allowsUndo = true
    view.delegate = coordinator
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    defer { window.orderOut(nil) }

    let undoManager = try XCTUnwrap(view.undoManager)
    // Typing and an asynchronous import finish in separate user events.
    // Model those event groups explicitly in this synchronous AppKit fixture.
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    view.setSelectedRange(NSRange(location: (originalBody as NSString).length, length: 0))
    view.insertText("Z", replacementRange: view.selectedRange())
    undoManager.endUndoGrouping()
    XCTAssertEqual(view.string, body)
    XCTAssertTrue(view.undoManager?.canUndo == true)
    view.breakUndoCoalescing()

    let edit = try XCTUnwrap(
      MarkdownTextMutationService.edit(
        from: body,
        to: mutation.draft.bodyMarkdown,
        selectedRange: mutation.selectedRange
      )
    )
    let request = MarkdownTextEditRequest(
      expectedText: body,
      edit: edit
    )

    undoManager.beginUndoGrouping()
    XCTAssertEqual(coordinator.handle(request, in: view)?.wasApplied, true)
    undoManager.endUndoGrouping()
    XCTAssertEqual(view.string, mutation.draft.bodyMarkdown)
    XCTAssertEqual(view.selectedRange(), mutation.selectedRange)
    XCTAssertTrue(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(view.string, body)
    XCTAssertTrue(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(view.string, originalBody)
  }

  private func makeDraft(body: String) -> ArticleDraft {
    ArticleDraft(siteProfileID: UUID(), title: "附件插入", bodyMarkdown: body)
  }
}
