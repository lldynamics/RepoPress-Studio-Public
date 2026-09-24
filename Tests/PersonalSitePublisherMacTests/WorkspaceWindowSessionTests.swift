import Foundation
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class WorkspaceWindowSessionTests: XCTestCase {
  func testWritingListRestorationKeepsFiltersAndFolderExpansionPerWindow() {
    let firstListState = WritingListWindowPresentationState()
    let secondListState = WritingListWindowPresentationState()
    let first = WorkspaceWindowSession(
      selectedSection: .writing,
      writingListState: firstListState
    )
    let second = WorkspaceWindowSession(
      selectedSection: .writing,
      writingListState: secondListState
    )

    _ = first.writingListState.restoreStorageIfNeeded(
      searchText: "发布计划",
      filterRawValue: DraftListFilter.ready.rawValue,
      displayModeRawValue: WritingDraftListDisplayMode.folders.rawValue,
      sortOrderRawValue: WritingDraftSortOrder.titleAscending.rawValue,
      expandedFolderIDsData: "[\"posts\",\"posts/2026\"]"
    )
    _ = second.writingListState.restoreStorageIfNeeded(
      searchText: "",
      filterRawValue: DraftListFilter.privateArticles.rawValue,
      displayModeRawValue: WritingDraftListDisplayMode.flat.rawValue,
      sortOrderRawValue: WritingDraftSortOrder.updatedNewest.rawValue,
      expandedFolderIDsData: "[\"private\"]"
    )

    XCTAssertEqual(first.writingListState.searchText, "发布计划")
    XCTAssertEqual(first.writingListState.filter, .ready)
    XCTAssertEqual(first.writingListState.displayMode, .folders)
    XCTAssertEqual(first.writingListState.sortOrder, .titleAscending)
    XCTAssertEqual(first.writingListState.userExpandedFolderIDs, ["posts", "posts/2026"])
    XCTAssertTrue(first.writingListState.hasPersistedFolderExpansion)
    XCTAssertEqual(second.writingListState.filter, .privateArticles)
    XCTAssertEqual(second.writingListState.userExpandedFolderIDs, ["private"])
  }

  func testWritingListRestorationRejectsInvalidLegacyValuesWithoutOverwritingLaterState() {
    let state = WritingListWindowPresentationState()
    _ = state.restoreStorageIfNeeded(
      searchText: "保留查询",
      filterRawValue: "retired-filter",
      displayModeRawValue: "retired-display",
      sortOrderRawValue: "retired-sort",
      expandedFolderIDsData: "not-json"
    )
    _ = state.restoreStorageIfNeeded(
      searchText: "不应覆盖",
      filterRawValue: DraftListFilter.ready.rawValue,
      displayModeRawValue: WritingDraftListDisplayMode.folders.rawValue,
      sortOrderRawValue: WritingDraftSortOrder.titleAscending.rawValue,
      expandedFolderIDsData: "[\"later\"]"
    )

    XCTAssertEqual(state.searchText, "保留查询")
    XCTAssertEqual(state.filter, .all)
    XCTAssertEqual(state.displayMode, .flat)
    XCTAssertEqual(state.sortOrder, .updatedNewest)
    XCTAssertTrue(state.userExpandedFolderIDs.isEmpty)
    XCTAssertFalse(state.hasPersistedFolderExpansion)
    XCTAssertEqual(state.restorationRevision, 1)
  }

  func testRestoresStableWindowIdentityAndSectionFromSceneStorage() throws {
    let expectedWindowID = UUID()
    let expectedDraftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .writing)

    let restored = session.restoreStorageIfNeeded(
      windowIDRawValue: expectedWindowID.uuidString,
      selectedSectionRawValue: WorkspaceSection.library.rawValue,
      fallbackSection: .writing,
      selectedDraftIDRawValue: expectedDraftID.uuidString
    )

    XCTAssertEqual(session.windowID, expectedWindowID)
    XCTAssertEqual(session.selectedSection, .library)
    XCTAssertEqual(session.selectedDraftID, expectedDraftID)
    XCTAssertEqual(restored.windowIDRawValue, expectedWindowID.uuidString)
    XCTAssertEqual(restored.selectedSectionRawValue, WorkspaceSection.library.rawValue)
    XCTAssertEqual(restored.selectedDraftIDRawValue, expectedDraftID.uuidString)
  }

  func testRetiredSiteStarterSceneStorageFallsBackToRepositoryWorkspace() {
    let session = WorkspaceWindowSession(selectedSection: .writing)

    let restored = session.restoreStorageIfNeeded(
      windowIDRawValue: UUID().uuidString,
      selectedSectionRawValue: "siteStarter",
      fallbackSection: .sync
    )

    XCTAssertEqual(session.selectedSection, .sync)
    XCTAssertEqual(restored.selectedSectionRawValue, WorkspaceSection.sync.rawValue)
  }

  func testInvalidSceneStorageFallsBackWithoutReplacingGeneratedIdentityLater() {
    let generatedWindowID = UUID()
    let session = WorkspaceWindowSession(
      windowID: generatedWindowID,
      selectedSection: .writing
    )

    let restored = session.restoreStorageIfNeeded(
      windowIDRawValue: "not-a-uuid",
      selectedSectionRawValue: "retired-section",
      fallbackSection: .rss
    )
    _ = session.restoreStorageIfNeeded(
      windowIDRawValue: UUID().uuidString,
      selectedSectionRawValue: WorkspaceSection.sync.rawValue,
      fallbackSection: .writing
    )

    XCTAssertEqual(session.windowID, generatedWindowID)
    XCTAssertEqual(session.selectedSection, .rss)
    XCTAssertEqual(restored.windowIDRawValue, generatedWindowID.uuidString)
  }

  func testOnlyKeyWindowReceivesSharedChangesAndReactivatesItsOwnSection() {
    let first = WorkspaceWindowSession(selectedSection: .writing)
    let second = WorkspaceWindowSession(selectedSection: .library)
    var sharedSection = WorkspaceSection.writing

    first.setKeyWindow(true) { section, _ in sharedSection = section }
    first.selectSection(.sync) { sharedSection = $0 }
    second.receiveSharedSection(sharedSection)

    XCTAssertEqual(first.selectedSection, .sync)
    XCTAssertEqual(second.selectedSection, .library)
    XCTAssertEqual(sharedSection, .sync)

    first.setKeyWindow(false) { section, _ in sharedSection = section }
    second.setKeyWindow(true) { section, _ in sharedSection = section }

    XCTAssertEqual(sharedSection, .library)
    XCTAssertEqual(first.selectedSection, .sync)
    XCTAssertEqual(second.selectedSection, .library)

    first.receiveSharedSection(.contentHealth)
    second.receiveSharedSection(.contentHealth)

    XCTAssertEqual(first.selectedSection, .sync)
    XCTAssertEqual(second.selectedSection, .contentHealth)
  }

  func testInactiveSelectionWaitsUntilWindowBecomesKeyBeforeActivation() {
    let session = WorkspaceWindowSession(selectedSection: .writing)
    var activations: [WorkspaceSection] = []

    session.selectSection(.images) { activations.append($0) }
    XCTAssertTrue(activations.isEmpty)

    session.setKeyWindow(true) { section, _ in activations.append(section) }
    XCTAssertEqual(activations, [.images])
  }

  func testInactiveDraftSelectionWaitsUntilWindowBecomesKeyBeforeActivation() {
    let draftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .writing)
    var activations: [UUID?] = []

    session.selectDraft(draftID) { activations.append($0) }

    XCTAssertEqual(session.selectedDraftID, draftID)
    XCTAssertTrue(activations.isEmpty)

    session.setKeyWindow(true) { _, selectedDraftID in
      activations.append(selectedDraftID)
    }

    XCTAssertEqual(activations, [draftID])
  }

  func testPaletteCreatedDraftRemainsThePresentingWindowIntentAfterSheetDismissal() {
    let originalDraftID = UUID()
    let createdDraftID = UUID()
    let secondDraftID = UUID()
    let first = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: originalDraftID
    )
    let second = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: secondDraftID
    )
    var activatedByFirst: (WorkspaceSection, UUID?)?

    first.setKeyWindow(false) { _, _ in }
    // This is the sheet path used by WorkspaceCommandPalette after
    // createDraft() has updated the shared compatibility Store.
    first.selectContext(section: .writing, draftID: createdDraftID) { _, _ in
      XCTFail("A sheet-presenting non-key window must not activate the shared Store early.")
    }
    second.setKeyWindow(true) { _, _ in }

    first.setKeyWindow(true) { section, draftID in
      activatedByFirst = (section, draftID)
    }

    XCTAssertEqual(first.selectedDraftID, createdDraftID)
    XCTAssertEqual(second.selectedDraftID, secondDraftID)
    XCTAssertEqual(activatedByFirst?.0, .writing)
    XCTAssertEqual(activatedByFirst?.1, createdDraftID)
  }

  func testSheetSearchFocusIsDeliveredOnlyOnceToItsPresentingWindow() {
    let delivery = WorkspaceEditorFocusRequestDelivery()
    let targetDraftID = UUID()
    let requestID = UUID()
    let presenting = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: UUID(),
      editorFocusRequestDelivery: delivery
    )
    let otherWindow = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: targetDraftID,
      editorFocusRequestDelivery: delivery
    )
    var restoredContext: (WorkspaceSection, UUID?)?

    // Full-text search updates the presenting window before it creates the
    // shared request, while the sheet has made that window non-key.
    presenting.selectContext(section: .writing, draftID: targetDraftID) { _, _ in
      XCTFail("The sheet-presenting window is not key yet.")
    }
    presenting.registerEditorFocusRequest(requestID)

    otherWindow.setKeyWindow(true) { _, _ in }
    XCTAssertFalse(
      otherWindow.consumeEditorFocusRequest(requestID),
      "Another key window on the same draft must not steal the request."
    )

    presenting.setKeyWindow(true) { section, draftID in
      restoredContext = (section, draftID)
    }
    XCTAssertEqual(restoredContext?.0, .writing)
    XCTAssertEqual(restoredContext?.1, targetDraftID)
    XCTAssertTrue(presenting.consumeEditorFocusRequest(requestID))
    XCTAssertFalse(
      presenting.consumeEditorFocusRequest(requestID),
      "Re-mounting the presenting editor must not restore an old selection."
    )
    XCTAssertFalse(otherWindow.consumeEditorFocusRequest(requestID))
  }

  func testLegacyFocusRequestCanRetryWhenItsEditorBecomesKey() {
    let delivery = WorkspaceEditorFocusRequestDelivery()
    let requestID = UUID()
    let session = WorkspaceWindowSession(
      selectedSection: .writing,
      editorFocusRequestDelivery: delivery
    )

    XCTAssertFalse(
      session.consumeEditorFocusRequest(requestID),
      "A legacy request must remain available while its editor is behind a sheet."
    )
    session.setKeyWindow(true) { _, _ in }
    XCTAssertTrue(session.consumeEditorFocusRequest(requestID))
    XCTAssertFalse(
      session.consumeEditorFocusRequest(requestID),
      "The retry consumes the request exactly once."
    )
  }

  func testFocusRequestDeliveryLedgerRetainsAtMost128Entries() {
    let delivery = WorkspaceEditorFocusRequestDelivery()
    let session = WorkspaceWindowSession(
      selectedSection: .writing,
      editorFocusRequestDelivery: delivery
    )

    for _ in 0...128 {
      session.registerEditorFocusRequest(UUID())
    }

    XCTAssertEqual(delivery.entryCount, 128)
  }

  func testContextSelectionActivatesSectionAndDraftAtomicallyForKeyWindow() {
    let draftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .writing)
    var activations: [(WorkspaceSection, UUID?)] = []

    session.setKeyWindow(true) { section, selectedDraftID in
      activations.append((section, selectedDraftID))
    }
    session.selectContext(
      section: .sync,
      draftID: draftID
    ) { section, selectedDraftID in
      activations.append((section, selectedDraftID))
    }

    XCTAssertEqual(session.selectedSection, .sync)
    XCTAssertEqual(session.selectedDraftID, draftID)
    XCTAssertEqual(activations.count, 2)
    XCTAssertEqual(activations.last?.0, .sync)
    XCTAssertEqual(activations.last?.1, draftID)
  }

  func testKeyWindowsRememberIndependentDraftsAndReactivateTheirOwnContext() {
    let draftA = UUID()
    let draftB = UUID()
    let first = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: draftA
    )
    let second = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: draftB
    )
    var sharedDraftID: UUID?

    first.setKeyWindow(true) { _, draftID in sharedDraftID = draftID }
    second.receiveSharedDraft(sharedDraftID)
    XCTAssertEqual(sharedDraftID, draftA)
    XCTAssertEqual(second.selectedDraftID, draftB)

    first.setKeyWindow(false) { _, draftID in sharedDraftID = draftID }
    second.setKeyWindow(true) { _, draftID in sharedDraftID = draftID }
    XCTAssertEqual(sharedDraftID, draftB)
    XCTAssertEqual(first.selectedDraftID, draftA)
  }

  func testDeletedRememberedDraftFallsBackBeforeWindowActivation() {
    let deletedDraftID = UUID()
    let fallbackDraftID = UUID()
    let session = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: deletedDraftID
    )
    var activatedDraftID: UUID?

    session.reconcileDraftSelection(
      validDraftIDs: [fallbackDraftID],
      fallbackDraftID: fallbackDraftID
    )
    session.setKeyWindow(true) { _, draftID in activatedDraftID = draftID }

    XCTAssertEqual(session.selectedDraftID, fallbackDraftID)
    XCTAssertEqual(activatedDraftID, fallbackDraftID)
  }

  func testAIInspectorDraftResolverKeepsEachWindowSelectionIndependent() {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("window-inspector-\(UUID().uuidString).json")
      ),
      safeMode: true
    )
    let first = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "窗口 A",
      slug: "window-a"
    )
    let second = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "窗口 B",
      slug: "window-b"
    )
    store.setDrafts([first, second])
    store.selectDraft(second.id)

    XCTAssertEqual(
      AIChatInspectorDraftResolver.resolve(
        selectedDraftID: first.id,
        usesWindowDraftSelection: true,
        ai: store.ai
      )?.id,
      first.id
    )
    XCTAssertEqual(
      AIChatInspectorDraftResolver.resolve(
        selectedDraftID: second.id,
        usesWindowDraftSelection: true,
        ai: store.ai
      )?.id,
      second.id
    )
    XCTAssertNil(
      AIChatInspectorDraftResolver.resolve(
        selectedDraftID: nil,
        usesWindowDraftSelection: true,
        ai: store.ai
      )
    )
  }

  func testGeneralInspectorCanPresentWithoutAnyWindowOrSharedDraftSelection() {
    XCTAssertTrue(
      AIChatInspectorContextPresentationPolicy.canPresentConversation(
        mode: .general,
        hasDraft: false
      )
    )
    XCTAssertFalse(
      AIChatInspectorContextPresentationPolicy.canPresentConversation(
        mode: .site,
        hasDraft: false
      )
    )
  }

  func testGeneralInspectorStateKeepsHistoryWhenWindowAndSharedDraftSelectionsAreNil() {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("general-inspector-state-\(UUID().uuidString).json")
      ),
      safeMode: true
    )
    store.setDrafts([])
    store.setSelectedDraftID(nil)
    XCTAssertNil(store.selectedDraftID)
    XCTAssertNil(store.ai.selectedChatDraft)
    store.setAIChatContextMode(.general)

    let conversation = AIConversation(
      scope: .general,
      connectionProfileID: store.activeAIConnectionProfile.id,
      messages: [
        AIPublishingChatMessage(role: .user, content: "没有文章时仍可提问", contextMode: .general),
        AIPublishingChatMessage(role: .assistant, content: "通用历史仍会显示", contextMode: .general),
      ]
    )
    store.aiStore.aiConversations = [conversation]
    store.aiStore.activeAIConversationIDsByScope = [
      AIConversationScope.general.storageKey: conversation.id
    ]

    let inspector = AIChatContextInspectorView(
      store: store,
      selectedDraftID: nil,
      usesWindowDraftSelection: true,
      surfaceState: .constant(
        AIChatSurfaceState(surface: .inspector, selectedConversationID: conversation.id)
      ),
      operationSession: AIChatSurfaceOperationSession()
    )

    XCTAssertNil(inspector.inspectorDraft)
    XCTAssertNil(inspector.state.conversation?.draft)
    XCTAssertEqual(
      inspector.state.conversation?.messages.map(\.content),
      ["没有文章时仍可提问", "通用历史仍会显示"]
    )
  }
}
