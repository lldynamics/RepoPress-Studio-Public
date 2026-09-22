import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchFocusedObservationFacadeTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "focused-observation-" + UUID().uuidString + ".json"
      )
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }

  func testMetadataSummaryFacadePublishesOnlyRelevantState() {
    let store = makeStore()
    let facade = WorkbenchMetadataSummaryFeatureFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("流式状态")
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "流式 token")
    ])
    store.setImageActionMessage("图片处理状态")
    store.siteMaintenanceStore.setRefreshing(true)
    store.siteMaintenanceStore.setRefreshErrorMessage("维护状态")
    XCTAssertEqual(changes, 0)

    store.setAIActionMessage("摘要动作状态")
    XCTAssertEqual(changes, 1)
    store.setAIActionMessage("摘要动作状态")
    XCTAssertEqual(changes, 1)

    store.aiWorkspaceStore.isAIActionRunning = true
    XCTAssertEqual(changes, 2)
    store.setAITokenAvailability(KeychainTokenAvailability(hasToken: true))
    XCTAssertEqual(changes, 3)
    XCTAssertTrue(facade.tokenAvailability.hasToken)
    XCTAssertTrue(facade.isActionRunning)
    XCTAssertEqual(facade.actionMessage, "摘要动作状态")

    var profiles = store.profiles
    XCTAssertFalse(profiles.isEmpty)
    profiles[0].name += "-unrelated"
    store.setProfiles(profiles)
    XCTAssertEqual(changes, 3)

    profiles[0].aiProviderConfig.model += "-changed"
    store.setProfiles(profiles)
    XCTAssertEqual(changes, 4)

    withExtendedLifetime(cancellable) {}
  }

  func testActiveEditorSelectionDoesNotBroadcastThroughRootStore() throws {
    let store = makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    var rootChanges = 0
    let cancellable = store.objectWillChange.sink { rootChanges += 1 }
    let bodyLength = (draft.bodyMarkdown as NSString).length

    store.updateActiveEditorSelection(
      draftID: draft.id,
      selectedRange: NSRange(location: 0, length: 0),
      selectedText: "",
      bodyUTF16Count: bodyLength
    )

    XCTAssertEqual(rootChanges, 0)
    XCTAssertEqual(store.activeEditorSelection?.draftID, draft.id)
    withExtendedLifetime(cancellable) {}
  }

  func testDocumentStoresAreTheSingleOwnersOfDraftAndLiveEditorState() throws {
    let store = makeStore()
    let publishing = store.publishingStore
    let documents = publishing.documents
    let documentSession = publishing.documentSession
    var draft = try XCTUnwrap(documents.drafts.first)

    draft.title = "文档 Store 所有者"
    documents.drafts = [draft]
    XCTAssertEqual(publishing.drafts, [draft])
    XCTAssertEqual(store.drafts, [draft])

    let staged = DraftBodyEditorBuffer(
      draftID: draft.id,
      bodyMarkdown: "仅文档会话持有的实时正文",
      revision: 4,
      isDirty: true
    )
    documentSession.setDraftBodyEditorBuffer(
      staged,
      for: draft.id,
      notifyObservers: false
    )
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id), staged)

    let selection = ActiveEditorSelection(
      draftID: draft.id,
      range: NSRange(location: 0, length: 0),
      selectedText: "",
      bodyUTF16Count: (staged.bodyMarkdown as NSString).length
    )
    documentSession.activeEditorSelection = selection
    XCTAssertEqual(publishing.activeEditorSelection, selection)
  }

  func testLiveEditorContextFacadeTracksOnlyCurrentDraftAndDeduplicates() throws {
    let store = makeStore()
    var trackedDraft = try XCTUnwrap(store.selectedDraft)
    trackedDraft.bodyMarkdown = "当前文章"
    var otherDraft = ArticleDraft.empty(profile: store.activeProfile)
    otherDraft.bodyMarkdown = "另一篇"
    store.setDrafts([trackedDraft, otherDraft])

    let facade = WorkbenchMarkdownEditorLiveContextFeatureFacade(
      store: store,
      draftID: trackedDraft.id
    )
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.updateActiveEditorSelection(
      draftID: otherDraft.id,
      selectedRange: NSRange(location: 0, length: 2),
      selectedText: "另一",
      bodyUTF16Count: (otherDraft.bodyMarkdown as NSString).length
    )
    XCTAssertEqual(changes, 0)
    XCTAssertNil(facade.activeEditorSelection)

    store.updateActiveEditorSelection(
      draftID: trackedDraft.id,
      selectedRange: NSRange(location: 0, length: 2),
      selectedText: "当前",
      bodyUTF16Count: (trackedDraft.bodyMarkdown as NSString).length
    )
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(facade.activeEditorSelection?.draftID, trackedDraft.id)
    XCTAssertEqual(facade.validatedSelectionRange, NSRange(location: 0, length: 2))

    store.updateActiveEditorSelection(
      draftID: trackedDraft.id,
      selectedRange: NSRange(location: 0, length: 2),
      selectedText: "当前",
      bodyUTF16Count: (trackedDraft.bodyMarkdown as NSString).length
    )
    XCTAssertEqual(changes, 1)

    store.publishingStore.documentSession.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: otherDraft.id,
        bodyMarkdown: "另一篇实时正文",
        revision: 1,
        isDirty: true
      ),
      for: otherDraft.id,
      notifyObservers: false
    )
    XCTAssertEqual(changes, 1)

    store.publishingStore.documentSession.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: trackedDraft.id,
        bodyMarkdown: "当前实时正文",
        revision: 1,
        isDirty: true
      ),
      for: trackedDraft.id,
      notifyObservers: false
    )
    XCTAssertEqual(changes, 2)
    XCTAssertEqual(facade.bodyMarkdown, "当前实时正文")
    XCTAssertNil(facade.validatedSelectionRange)

    facade.trackDraft(otherDraft.id)
    XCTAssertEqual(changes, 3)
    XCTAssertEqual(facade.bodyMarkdown, "另一篇实时正文")
    XCTAssertNil(facade.activeEditorSelection)

    store.updateActiveEditorSelection(
      draftID: otherDraft.id,
      selectedRange: NSRange(location: 0, length: 2),
      selectedText: "另一",
      bodyUTF16Count: ("另一篇实时正文" as NSString).length
    )
    XCTAssertEqual(changes, 4)
    XCTAssertEqual(facade.validatedSelectionRange, NSRange(location: 0, length: 2))

    withExtendedLifetime(cancellable) {}
  }

  func testRepositoryWorkspaceObservationIgnoresUnrelatedFeatures() {
    let store = makeStore()
    let facade = WorkbenchRepositoryWorkspaceObservationFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("流式状态")
    store.siteMaintenanceStore.setRefreshing(true)
    XCTAssertEqual(changes, 0)

    store.repositoryStore.isRemoteRepositoryChecking = true
    XCTAssertEqual(changes, 1)

    withExtendedLifetime(cancellable) {}
  }

  func testReleaseHistoryObservationIgnoresEditorAndAIChanges() {
    let store = makeStore()
    let facade = WorkbenchReleaseHistoryObservationFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("流式状态")
    store.setImageActionMessage("图片状态")
    XCTAssertEqual(changes, 0)

    store.deploymentStore.isDeploymentStatusChecking = true
    XCTAssertEqual(changes, 1)

    store.repositoryStore.localRepositoryReleaseHistory = .init(
      historyAvailability: .available
    )
    XCTAssertEqual(changes, 2)

    withExtendedLifetime(cancellable) {}
  }

  func testReleaseHistoryObservationTracksDraftScopeAndBatchPlan() throws {
    let store = makeStore()
    let facade = WorkbenchReleaseHistoryObservationFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }
    var draft = try XCTUnwrap(store.drafts.first)
    store.setDrafts([draft])
    changes = 0
    draft.bodyMarkdown += "More text"
    store.setDrafts([draft])
    XCTAssertEqual(changes, 0, "Body edits do not change review eligibility")
    draft.assignToGeneralDraft()
    store.setDrafts([draft])
    XCTAssertEqual(changes, 1, "Moving a draft out of the site invalidates review")
    store.publishingStore.publishSession.batchPublishPlan = BatchPublishPlan(
      profileID: store.activeProfileID, siteName: "Test", items: []
    )
    XCTAssertEqual(changes, 2)
    store.setDrafts([])
    XCTAssertEqual(changes, 3)
    withExtendedLifetime(cancellable) {}
  }

  func testSiteStarterObservationIgnoresUnrelatedFeatures() {
    let store = makeStore()
    let facade = WorkbenchSiteStarterObservationFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("流式状态")
    store.siteMaintenanceStore.setRefreshing(true)
    XCTAssertEqual(changes, 0)

    store.publishingStore.isSiteStarterOperationRunning = true
    XCTAssertEqual(changes, 1)
    store.repositoryStore.isRemoteRepositoryChecking = true
    XCTAssertEqual(changes, 2)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    XCTAssertEqual(changes, 3)

    withExtendedLifetime(cancellable) {}
  }
}
