import AppKit
import Combine
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownComposerPerformanceTests: XCTestCase {
  @MainActor
  func testStatisticsStatePublishesOnlyDistinctSnapshots() {
    let state = MarkdownComposerStatisticsState()
    var publicationCount = 0
    let cancellable = state.objectWillChange.sink {
      publicationCount += 1
    }

    state.update(.empty)
    XCTAssertEqual(publicationCount, 0)

    let updated = MarkdownEditorStatistics.make(for: "正文 words")
    state.update(updated)
    XCTAssertEqual(state.value, updated)
    XCTAssertEqual(publicationCount, 1)

    state.update(updated)
    XCTAssertEqual(publicationCount, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testAIAvailabilitySnapshotUsesOneBoundedContextProjection() {
    let draftID = UUID()
    let draft = ArticleDraft(
      id: draftID,
      siteProfileID: UUID(),
      title: "标题",
      summary: "摘要",
      bodyMarkdown: String(repeating: "正文内容\n", count: 20_000)
    )
    let snapshot = MarkdownComposerAIAvailabilitySnapshot(
      draft: draft,
      selectedText: "选中的正文",
      isAIEnabled: true,
      activeAction: nil,
      isAIActionRunning: false
    )

    XCTAssertEqual(snapshot.draftID, draftID)
    XCTAssertTrue(snapshot.hasSelectedText)
    XCTAssertTrue(snapshot.hasBodyText)
    XCTAssertTrue(snapshot.hasArticleSeedText)
    XCTAssertTrue(snapshot.isAIEnabled)
    XCTAssertNil(snapshot.activeAction)
    XCTAssertFalse(snapshot.isAIActionRunning)
    XCTAssertTrue(snapshot.selectionAvailability(for: .rewriteSelection).isEnabled)
    XCTAssertTrue(snapshot.articleAvailability(for: .suggestTitles).isEnabled)
  }

  func testAIAvailabilitySnapshotPreservesActiveActionAndRunningFallback() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "标题",
      bodyMarkdown: "正文"
    )
    let activeSnapshot = MarkdownComposerAIAvailabilitySnapshot(
      draft: draft,
      selectedText: "选区",
      isAIEnabled: true,
      activeAction: .rewriteSelection,
      isAIActionRunning: false
    )
    XCTAssertEqual(activeSnapshot.activeAction, .rewriteSelection)
    XCTAssertEqual(
      activeSnapshot.selectionAvailability(for: .rewriteSelection).unavailableReason,
      "AI 正在处理"
    )
    XCTAssertEqual(
      activeSnapshot.articleAvailability(for: .suggestTitles).unavailableReason,
      "AI 正在处理"
    )

    let runningSnapshot = MarkdownComposerAIAvailabilitySnapshot(
      draft: draft,
      selectedText: "选区",
      isAIEnabled: true,
      activeAction: nil,
      isAIActionRunning: true
    )
    XCTAssertNil(runningSnapshot.activeAction)
    XCTAssertEqual(
      runningSnapshot.selectionAvailability(for: .rewriteSelection).unavailableReason,
      "AI 正在处理"
    )
    XCTAssertEqual(
      runningSnapshot.articleAvailability(for: .suggestTitles).unavailableReason,
      "AI 正在处理"
    )
  }

  func testAIAvailabilitySnapshotUsesLiveEditorBodyInsteadOfPersistedDraftBody() {
    let draft = ArticleDraft(siteProfileID: UUID(), title: "", bodyMarkdown: "")
    let snapshot = MarkdownComposerAIAvailabilitySnapshot(
      draft: draft,
      bodyMarkdown: "尚未刷新到 draft 的实时正文",
      selectedText: "",
      isAIEnabled: true,
      activeAction: nil,
      isAIActionRunning: false
    )

    XCTAssertTrue(snapshot.hasBodyText)
    XCTAssertTrue(snapshot.articleAvailability(for: .draftArticleFAQ).isEnabled)
  }

  @MainActor
  func testKnowledgeQueryCoordinatorPreservesSnapshotUntilIdleRefresh() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-query-coordinator-" + UUID().uuidString + ".json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "初始标题"
    let initialBuffer = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody(
      "初始正文",
      for: draft.id,
      baseRevision: initialBuffer.revision,
      replacingBaseBody: initialBuffer.bodyMarkdown,
      notifyEditorObservers: false
    )
    let coordinator = KnowledgeContextQueryRefreshCoordinator(
      draft: draft,
      store: store,
      debounceDuration: .milliseconds(60)
    )
    let initialRefresh = expectation(description: "initial idle query refresh")
    var cancellables = Set<AnyCancellable>()
    coordinator.$query
      .dropFirst()
      .filter { $0.contains("初始正文") }
      .sink { _ in initialRefresh.fulfill() }
      .store(in: &cancellables)

    await fulfillment(of: [initialRefresh], timeout: 2)
    let initialQuery = coordinator.query
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody(
      "停止输入后才应出现的新正文",
      for: draft.id,
      baseRevision: buffer.revision,
      replacingBaseBody: buffer.bodyMarkdown,
      notifyEditorObservers: false
    )

    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(coordinator.query, initialQuery)

    let idleRefresh = expectation(description: "updated idle query refresh")
    coordinator.$query
      .dropFirst()
      .filter { $0.contains("新正文") }
      .sink { _ in idleRefresh.fulfill() }
      .store(in: &cancellables)
    await fulfillment(of: [idleRefresh], timeout: 2)
  }

  func testSSGDerivedDataKeyUsesRevisionForConstantSizeBodyIdentity() {
    let draftID = UUID()
    let profileID = UUID()
    let base = MarkdownComposerSSGDerivedDataKey(
      bodyRevision: 7,
      draftID: draftID,
      siteProfileID: profileID,
      title: "Title",
      slug: "title",
      customSnippets: []
    )
    let same = MarkdownComposerSSGDerivedDataKey(
      bodyRevision: 7,
      draftID: draftID,
      siteProfileID: profileID,
      title: "Title",
      slug: "title",
      customSnippets: []
    )
    let changedBody = MarkdownComposerSSGDerivedDataKey(
      bodyRevision: 8,
      draftID: draftID,
      siteProfileID: profileID,
      title: "Title",
      slug: "title",
      customSnippets: []
    )

    XCTAssertEqual(base, same)
    XCTAssertNotEqual(base, changedBody)
  }

  func testScrollSyncPositionNormalizesAnchorAndProgressFallback() {
    XCTAssertEqual(
      MarkdownScrollSyncPosition(sourceLine: 45, progress: 1.4),
      MarkdownScrollSyncPosition(sourceLine: 45, progress: 1)
    )
    XCTAssertEqual(
      MarkdownScrollSyncPosition(sourceLine: 0, progress: -.infinity),
      MarkdownScrollSyncPosition(sourceLine: nil, progress: 0)
    )
  }

  func testScrollProgressCoalescerDeliversOnlyLatestProgressPerIdleBurst() {
    var coalescer = MarkdownScrollProgressCoalescer()

    XCTAssertTrue(coalescer.receive(0.10))
    XCTAssertTrue(coalescer.receive(0.35))
    XCTAssertTrue(coalescer.receive(0.80))
    XCTAssertEqual(coalescer.deliverLatest(), 0.80)
    XCTAssertNil(coalescer.deliverLatest())

    XCTAssertFalse(coalescer.receive(0.8005))
    XCTAssertNil(coalescer.deliverLatest())
    XCTAssertTrue(coalescer.receive(0.82))
    XCTAssertEqual(coalescer.deliverLatest(), 0.82)
  }

  func testScrollProgressCoalescerClampsInvalidValuesAndPreservesLastValue() {
    var coalescer = MarkdownScrollProgressCoalescer()

    XCTAssertTrue(coalescer.receive(.infinity))
    XCTAssertEqual(coalescer.deliverLatest(), 0)
    XCTAssertFalse(coalescer.receive(-1))
    XCTAssertNil(coalescer.deliverLatest())
    XCTAssertTrue(coalescer.receive(2))
    XCTAssertEqual(coalescer.deliverLatest(), 1)
  }
}
