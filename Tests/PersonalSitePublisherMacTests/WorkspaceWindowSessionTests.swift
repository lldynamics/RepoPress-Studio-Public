import Foundation
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class WorkspaceWindowSessionTests: XCTestCase {
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
