import AppKit
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
