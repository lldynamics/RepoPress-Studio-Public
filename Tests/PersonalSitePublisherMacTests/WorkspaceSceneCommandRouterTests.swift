import Combine
import XCTest
@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceSceneCommandRouterTests: XCTestCase {
  func testCoalescesMultiplePresentationChangesIntoOneDefaultRunLoopNotification() {
    let router = WorkspaceSceneCommandRouter()
    var notificationCount = 0
    let cancellable = router.objectWillChange.sink {
      notificationCount += 1
    }

    router.registerWritingDrafts(makeWritingDraftActions(), owner: UUID())
    router.registerKnowledgeLibrary(makeKnowledgeLibraryActions(), owner: UUID())
    router.registerRSSReader(makeRSSActions(canActOnArticle: true), owner: UUID())

    drainDefaultRunLoop()

    XCTAssertEqual(notificationCount, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testEquivalentPresentationUsesLatestActionWithoutRepublishing() {
    let router = WorkspaceSceneCommandRouter()
    let owner = UUID()
    let draftID = UUID()
    var invokedAction = 0
    var notificationCount = 0
    let cancellable = router.objectWillChange.sink {
      notificationCount += 1
    }

    router.registerMarkdownEditor(
      makeMarkdownActions(draftID: draftID) { invokedAction = 1 },
      owner: owner
    )
    drainDefaultRunLoop()
    XCTAssertEqual(notificationCount, 1)

    router.registerMarkdownEditor(
      makeMarkdownActions(draftID: draftID) { invokedAction = 2 },
      owner: owner
    )
    drainDefaultRunLoop()

    router.markdownEditorCommandActions?.showFindReplace()
    XCTAssertEqual(invokedAction, 2)
    XCTAssertEqual(notificationCount, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testStaleOwnerCannotUnregisterNewerContext() {
    let router = WorkspaceSceneCommandRouter()
    let staleOwner = UUID()
    let currentOwner = UUID()
    let currentDraftID = UUID()
    var notificationCount = 0
    let cancellable = router.objectWillChange.sink {
      notificationCount += 1
    }

    router.registerMarkdownEditor(
      makeMarkdownActions(draftID: currentDraftID) {},
      owner: staleOwner
    )
    drainDefaultRunLoop()
    XCTAssertEqual(notificationCount, 1)

    router.registerMarkdownEditor(
      makeMarkdownActions(draftID: currentDraftID) {},
      owner: currentOwner
    )
    drainDefaultRunLoop()
    XCTAssertEqual(notificationCount, 2)

    router.unregisterMarkdownEditor(owner: staleOwner)
    XCTAssertEqual(router.markdownEditorCommandActions?.draftID, currentDraftID)
    drainDefaultRunLoop()
    XCTAssertEqual(notificationCount, 2)

    router.unregisterMarkdownEditor(owner: currentOwner)
    XCTAssertNil(router.markdownEditorCommandActions)
    drainDefaultRunLoop()
    XCTAssertEqual(notificationCount, 3)
    withExtendedLifetime(cancellable) {}
  }

  func testClearAllReleasesRootAndContextActions() {
    let router = WorkspaceSceneCommandRouter()
    router.updateRoot(
      publishDrawerCommandAction: PublishDrawerCommandAction { _ in },
      localSitePreviewCommandAction: LocalSitePreviewCommandAction {},
      workspaceCommandPaletteAction: WorkspaceCommandPaletteAction(
        open: {},
        openMaintenance: {},
        openReleaseHistory: {}
      ),
      workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction(open: {}),
      settingsWorkspaceCommandAction: SettingsWorkspaceCommandAction(
        isPresented: false,
        open: { _ in },
        close: {}
      ),
      draftFullTextSearchAction: DraftFullTextSearchAction(open: {}),
      workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction(
        isActive: false,
        canToggle: true,
        toggle: {}
      ),
      repositorySourceSessionCommandActions: RepositorySourceSessionCommandActions(
        hasUnsavedChanges: false,
        save: { true },
        lastErrorMessage: { nil }
      )
    )
    router.registerMarkdownEditor(
      makeMarkdownActions(draftID: UUID()) {},
      owner: UUID()
    )
    router.registerKnowledgeLibrary(makeKnowledgeLibraryActions(), owner: UUID())

    router.clearAll()

    XCTAssertNil(router.publishDrawerCommandAction)
    XCTAssertNil(router.localSitePreviewCommandAction)
    XCTAssertNil(router.workspaceCommandPaletteAction)
    XCTAssertNil(router.workspaceFirstRunSetupCommandAction)
    XCTAssertNil(router.settingsWorkspaceCommandAction)
    XCTAssertNil(router.draftFullTextSearchAction)
    XCTAssertNil(router.workspaceFocusModeCommandAction)
    XCTAssertNil(router.repositorySourceSessionCommandActions)
    XCTAssertNil(router.markdownEditorCommandActions)
    XCTAssertNil(router.knowledgeLibraryCommandActions)
  }

  private func drainDefaultRunLoop() {
    let deadline = Date(timeIntervalSinceNow: 0.05)
    repeat {
      _ = RunLoop.main.run(mode: .default, before: deadline)
    } while Date() < deadline
  }

  private func makeMarkdownActions(
    draftID: UUID,
    showFindReplace: @escaping () -> Void
  ) -> MarkdownEditorCommandActions {
    MarkdownEditorCommandActions(
      draftID: draftID,
      canRewriteSelection: false,
      canUseFindReplace: true,
      showFindReplace: showFindReplace,
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

  private func makeWritingDraftActions() -> WritingDraftCommandActions {
    WritingDraftCommandActions(
      createDraft: {},
      focusSearch: {},
      openVersionHistory: {},
      selectPreviousDraft: {},
      selectNextDraft: {}
    )
  }

  private func makeKnowledgeLibraryActions() -> KnowledgeLibraryCommandActions {
    KnowledgeLibraryCommandActions(
      focusSearch: {},
      importSources: {},
      selectPreviousDocument: {},
      selectNextDocument: {}
    )
  }

  private func makeRSSActions(canActOnArticle: Bool) -> RSSReaderCommandActions {
    RSSReaderCommandActions(
      canNavigatePrevious: false,
      canNavigateNext: false,
      canActOnArticle: canActOnArticle,
      focusSearch: {},
      navigatePrevious: {},
      navigateNext: {},
      toggleStarred: {},
      toggleRead: {},
      openOriginal: {},
      createHighlight: {},
      addNote: {},
      editTags: {}
    )
  }
}
