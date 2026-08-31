import Combine
import XCTest
@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceToolbarEditorContextTests: XCTestCase {
  func testRouterProjectsStatisticsWithoutRepublishingItsBroadPresentation() {
    let router = WorkspaceSceneCommandRouter()
    let ownerID = UUID()
    let draftID = UUID()
    let statistics = MarkdownEditorStatistics.make(for: "中文 writing context")
    var routerNotificationCount = 0
    let cancellable = router.objectWillChange.sink {
      routerNotificationCount += 1
    }

    router.registerMarkdownEditor(makeMarkdownActions(draftID: draftID), owner: ownerID)
    drainDefaultRunLoop()
    XCTAssertEqual(routerNotificationCount, 1)

    router.updateToolbarEditorContext(
      owner: ownerID,
      draftID: draftID,
      statistics: statistics
    )
    drainDefaultRunLoop()

    XCTAssertEqual(routerNotificationCount, 1)
    XCTAssertEqual(router.toolbarEditorContext.context?.ownerID, ownerID)
    XCTAssertEqual(router.toolbarEditorContext.context?.draftID, draftID)
    XCTAssertEqual(
      router.toolbarEditorContext.context?.writingUnitCount,
      statistics.writingUnitCount
    )
    XCTAssertEqual(
      router.toolbarEditorContext.context?.readingMinutes,
      statistics.readingMinutes
    )
    withExtendedLifetime(cancellable) {}
  }

  func testCurrentOwnerProjectsWritingStatistics() {
    let store = WorkspaceToolbarEditorContextStore()
    let ownerID = UUID()
    let draftID = UUID()

    store.activate(ownerID: ownerID, draftID: draftID)
    store.update(
      ownerID: ownerID,
      draftID: draftID,
      writingUnitCount: 248,
      readingMinutes: 2
    )

    XCTAssertEqual(
      store.context,
      WorkspaceToolbarEditorContext(
        ownerID: ownerID,
        draftID: draftID,
        writingUnitCount: 248,
        readingMinutes: 2
      )
    )
  }

  func testActivationUsesLoadingStatisticsInsteadOfAFalseZeroCount() {
    let store = WorkspaceToolbarEditorContextStore()
    let ownerID = UUID()
    let draftID = UUID()

    store.activate(ownerID: ownerID, draftID: draftID)

    XCTAssertNil(store.context?.writingUnitCount)
    XCTAssertNil(store.context?.readingMinutes)
  }

  func testSwitchingOwnerAndDraftRejectsStaleStatisticsAndClearsCurrentOwner() {
    let store = WorkspaceToolbarEditorContextStore()
    let staleOwnerID = UUID()
    let currentOwnerID = UUID()
    let staleDraftID = UUID()
    let currentDraftID = UUID()

    store.activate(ownerID: staleOwnerID, draftID: staleDraftID)
    store.update(
      ownerID: staleOwnerID,
      draftID: staleDraftID,
      writingUnitCount: 100,
      readingMinutes: 1
    )
    store.activate(ownerID: currentOwnerID, draftID: currentDraftID)
    store.update(
      ownerID: staleOwnerID,
      draftID: staleDraftID,
      writingUnitCount: 999,
      readingMinutes: 9
    )

    XCTAssertEqual(store.context?.ownerID, currentOwnerID)
    XCTAssertEqual(store.context?.draftID, currentDraftID)
    XCTAssertNil(store.context?.writingUnitCount)
    XCTAssertNil(store.context?.readingMinutes)

    store.clear(ownerID: staleOwnerID)
    XCTAssertEqual(store.context?.ownerID, currentOwnerID)

    store.clear(ownerID: currentOwnerID)
    XCTAssertNil(store.context)
  }

  func testEquivalentStatisticsDoNotRepublish() {
    let store = WorkspaceToolbarEditorContextStore()
    let ownerID = UUID()
    let draftID = UUID()
    var notificationCount = 0
    let cancellable = store.objectWillChange.sink {
      notificationCount += 1
    }

    store.activate(ownerID: ownerID, draftID: draftID)
    store.update(
      ownerID: ownerID,
      draftID: draftID,
      writingUnitCount: 24,
      readingMinutes: 1
    )
    store.update(
      ownerID: ownerID,
      draftID: draftID,
      writingUnitCount: 24,
      readingMinutes: 1
    )

    XCTAssertEqual(notificationCount, 2)
    withExtendedLifetime(cancellable) {}
  }

  private func makeMarkdownActions(draftID: UUID) -> MarkdownEditorCommandActions {
    MarkdownEditorCommandActions(
      draftID: draftID,
      canRewriteSelection: false,
      canUseFindReplace: false,
      showFindReplace: {},
      showKeyboardShortcuts: {},
      showSnippets: {},
      findPrevious: {},
      findNext: {},
      replaceCurrentOrNext: {},
      replaceAll: {},
      applyFormatting: { _ in },
      insertImages: {},
      runPreflight: {},
      rewriteSelection: {},
      openAIAssistant: {},
      copyAIPrompt: {}
    )
  }

  private func drainDefaultRunLoop() {
    let deadline = Date(timeIntervalSinceNow: 0.05)
    repeat {
      _ = RunLoop.main.run(mode: .default, before: deadline)
    } while Date() < deadline
  }
}
