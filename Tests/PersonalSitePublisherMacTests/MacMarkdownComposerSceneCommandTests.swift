import AppKit
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

/// Menu commands reach the editor only through the window's scene router, so a
/// mounted composer must publish its actions there and withdraw them on unmount.
@MainActor
final class MacMarkdownComposerSceneCommandTests: XCTestCase {
  func testMountedComposerRegistersEditorCommandsAndRemovesThemOnDisappear() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkdownComposerSceneCommands-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json")),
      safeMode: true
    )
    let originalDraft = try XCTUnwrap(store.selectedDraft)
    var boundDraft = originalDraft
    let router = WorkspaceSceneCommandRouter()
    let composer = MacMarkdownComposerView(
      draft: Binding(
        get: { store.draft(for: originalDraft.id) ?? boundDraft },
        set: { boundDraft = $0 }
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
      rootView: composer.environmentObject(router).frame(width: 900, height: 700)
    )
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    let registered = await waitUntil { router.markdownEditorCommandActions != nil }
    XCTAssertTrue(registered, "A mounted composer must register its editor commands.")

    window.contentView = NSHostingView(rootView: EmptyView())

    let removed = await waitUntil { router.markdownEditorCommandActions == nil }
    XCTAssertTrue(removed, "An unmounted composer must remove its editor commands.")
  }

  private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}
