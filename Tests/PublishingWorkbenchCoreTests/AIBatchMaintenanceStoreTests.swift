import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIBatchMaintenanceStoreTests: XCTestCase {
  private let summary = "这是一段根据文章内容生成的摘要，保留原文事实并说明主要内容。"

  private func makeStore() throws -> WorkbenchStore {
    WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "AIBatchMaintenanceStoreTests"),
      keychainTokenStore: KeychainTokenStore(
        service: "AIBatchMaintenanceStoreTests.\(UUID().uuidString)",
        accountPrefix: "test",
        inMemory: true
      )
    )
  }

  private func makeDrafts(store: WorkbenchStore, count: Int = 2) -> [ArticleDraft] {
    let drafts = (0..<count).map {
      ArticleDraft(
        siteProfileID: store.activeProfileID, title: "文章 \($0)", bodyMarkdown: "正文内容 \($0)")
    }
    store.setDrafts(drafts)
    return drafts
  }

  private func waitUntilIdle(_ batch: AIBatchMaintenanceStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while batch.runningSiteID != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(batch.runningSiteID)
  }

  func testPauseFinishesCurrentAndResumePreservesCompletedResults() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store)
    let siteID = store.activeProfileID
    let started = expectation(description: "first request")
    var continuation: CheckedContinuation<String, any Error>?
    var calls = 0
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in
      calls += 1
      if calls == 1 {
        return try await withCheckedThrowingContinuation {
          continuation = $0
          started.fulfill()
        }
      }
      return self.summary
    }
    XCTAssertTrue(
      batch.create(draftIDs: Set(drafts.map(\.id)), operation: .summary, siteProfileID: siteID))
    XCTAssertEqual(calls, 0)
    batch.start(siteProfileID: siteID)
    await fulfillment(of: [started], timeout: 2)
    batch.pause(siteProfileID: siteID)
    continuation?.resume(returning: summary)
    try await waitUntilIdle(batch)
    XCTAssertEqual(batch.queue(for: siteID)?.readyCount, 1)
    XCTAssertEqual(batch.queue(for: siteID)?.pendingCount, 1)
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(batch.queue(for: siteID)?.readyCount, 2)

    let reopened = AIBatchMaintenanceStore(store: store)
    XCTAssertEqual(reopened.queue(for: siteID)?.readyCount, 2)
    XCTAssertTrue(reopened.queue(for: siteID)?.isPaused == true)
  }

  func testChangedBodyAfterRequestRejectsResultAndCannotOverwriteDraft() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store, count: 1)
    let siteID = store.activeProfileID
    let batch = AIBatchMaintenanceStore(store: store) { _, draft, _ in
      var changed = draft
      changed.bodyMarkdown = "用户最新的正文内容"
      store.updateDraft(changed)
      return self.summary
    }
    XCTAssertTrue(
      batch.create(draftIDs: [drafts[0].id], operation: .summary, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)
    XCTAssertEqual(batch.queue(for: siteID)?.failedCount, 1)
    XCTAssertEqual(store.draft(for: drafts[0].id)?.summary, "")
    XCTAssertEqual(store.draft(for: drafts[0].id)?.bodyMarkdown, "用户最新的正文内容")
  }

  func testDiscardingStaleResultAndRegeneratingOneItemRetainsOtherReadyResults() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store)
    let siteID = store.activeProfileID
    var calls = 0
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in
      calls += 1
      return self.summary
    }
    XCTAssertTrue(
      batch.create(draftIDs: Set(drafts.map(\.id)), operation: .summary, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)

    let stale = try XCTUnwrap(batch.queue(for: siteID)?.items.first)
    let retained = try XCTUnwrap(batch.queue(for: siteID)?.items.last)
    var changed = try XCTUnwrap(store.draft(for: stale.draftID))
    changed.bodyMarkdown = "用户更新后的正文"
    store.updateDraft(changed)

    XCTAssertTrue(batch.discardStaleResult(itemID: stale.id, siteProfileID: siteID))
    XCTAssertEqual(
      batch.queue(for: siteID)?.items.first(where: { $0.id == stale.id })?.status, .skipped)
    XCTAssertEqual(
      batch.queue(for: siteID)?.items.first(where: { $0.id == retained.id })?.status, .ready)
    XCTAssertTrue(batch.regenerate(itemID: stale.id, siteProfileID: siteID))
    try await waitUntilIdle(batch)

    XCTAssertEqual(calls, 3)
    XCTAssertEqual(
      batch.queue(for: siteID)?.items.first(where: { $0.id == stale.id })?.status, .ready)
    XCTAssertEqual(
      batch.queue(for: siteID)?.items.first(where: { $0.id == retained.id })?.status, .ready)
  }

  func testRegeneratingOneItemCapturesNewModelWithoutRelabelingRetainedReadyResult() async throws {
    let store = try makeStore()
    let initialModel = "initial-batch-model"
    let refreshedModel = "regenerated-item-model"
    var initialConnection = store.activeAIConnectionProfile
    initialConnection.config = AIProviderConfig(
      preset: .local, baseURL: "http://localhost:11434/v1", model: initialModel,
      requiresAPIKey: false)
    XCTAssertTrue(store.updateAIConnectionProfile(initialConnection))
    let drafts = makeDrafts(store: store)
    let siteID = store.activeProfileID
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in self.summary }
    XCTAssertTrue(
      batch.create(draftIDs: Set(drafts.map(\.id)), operation: .summary, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)

    let regenerated = try XCTUnwrap(batch.queue(for: siteID)?.items.first)
    let retained = try XCTUnwrap(batch.queue(for: siteID)?.items.last)
    XCTAssertEqual(regenerated.modelName, initialModel)
    XCTAssertEqual(retained.modelName, initialModel)

    var replacementConnection = store.activeAIConnectionProfile
    replacementConnection.config.model = refreshedModel
    XCTAssertTrue(store.updateAIConnectionProfile(replacementConnection))

    XCTAssertTrue(batch.regenerate(itemID: regenerated.id, siteProfileID: siteID))
    try await waitUntilIdle(batch)

    let queue = try XCTUnwrap(batch.queue(for: siteID))
    XCTAssertEqual(queue.items.first(where: { $0.id == regenerated.id })?.modelName, refreshedModel)
    XCTAssertEqual(queue.items.first(where: { $0.id == retained.id })?.modelName, initialModel)
    XCTAssertEqual(queue.items.first(where: { $0.id == retained.id })?.status, .ready)
    XCTAssertEqual(queue.displayModelName, CoreL10n.text("多个模型"))
  }

  func testSkippingPendingItemKeepsItOutOfTheLaterRun() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store)
    let siteID = store.activeProfileID
    var calls = 0
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in
      calls += 1
      return self.summary
    }
    XCTAssertTrue(
      batch.create(draftIDs: Set(drafts.map(\.id)), operation: .summary, siteProfileID: siteID))
    let skipped = try XCTUnwrap(batch.queue(for: siteID)?.items.first)
    XCTAssertTrue(batch.skip(itemID: skipped.id, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)

    XCTAssertEqual(calls, 1)
    XCTAssertEqual(
      batch.queue(for: siteID)?.items.first(where: { $0.id == skipped.id })?.status, .skipped)
    XCTAssertEqual(batch.queue(for: siteID)?.readyCount, 1)
  }

  func testRetryFailedDoesNotDispatchUntouchedPendingArticles() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store)
    let siteID = store.activeProfileID
    var calls = 0
    var batch: AIBatchMaintenanceStore!
    batch = AIBatchMaintenanceStore(store: store) { _, _, _ in
      calls += 1
      if calls == 1 {
        batch.pause(siteProfileID: siteID)
        throw AIBatchMaintenanceError.invalidResult
      }
      return self.summary
    }
    XCTAssertTrue(
      batch.create(draftIDs: Set(drafts.map(\.id)), operation: .summary, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)
    XCTAssertEqual(batch.queue(for: siteID)?.failedCount, 1)
    XCTAssertEqual(batch.queue(for: siteID)?.pendingCount, 1)
    batch.start(siteProfileID: siteID, retryFailed: true)
    try await waitUntilIdle(batch)
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(batch.queue(for: siteID)?.readyCount, 1)
    XCTAssertEqual(batch.queue(for: siteID)?.pendingCount, 1)
  }

  func testApplyOnlyReviewedMetadataAndRetainsRecoveryVersion() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store, count: 1)
    let siteID = store.activeProfileID
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in
      "标题：不应应用的标题\nSlug: do-not-apply\n摘要：\(self.summary)\n标签：\n- 写作\n- 工程"
    }
    XCTAssertTrue(
      batch.create(draftIDs: [drafts[0].id], operation: .metadata, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)
    let item = try XCTUnwrap(batch.queue(for: siteID)?.items.first)
    XCTAssertEqual(store.draft(for: drafts[0].id)?.summary, "")
    XCTAssertTrue(batch.apply(itemID: item.id, siteProfileID: siteID))
    // Match the existing metadata parser's removal of trailing list punctuation.
    XCTAssertEqual(
      store.draft(for: drafts[0].id)?.summary, "这是一段根据文章内容生成的摘要，保留原文事实并说明主要内容")
    XCTAssertEqual(store.draft(for: drafts[0].id)?.tags, ["写作", "工程"])
    XCTAssertEqual(store.draft(for: drafts[0].id)?.title, drafts[0].title)
    XCTAssertEqual(store.draft(for: drafts[0].id)?.slug, drafts[0].slug)
    XCTAssertEqual(store.draft(for: drafts[0].id)?.bodyMarkdown, drafts[0].bodyMarkdown)
    XCTAssertTrue(
      store.draftVersions.contains { $0.draftID == drafts[0].id && $0.draft.summary.isEmpty })
    XCTAssertEqual(batch.queue(for: siteID)?.appliedCount, 1)
  }

  func testApplyRefusesDirtyEditorBufferAndChangedRules() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store, count: 1)
    let siteID = store.activeProfileID
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in self.summary }
    XCTAssertTrue(
      batch.create(draftIDs: [drafts[0].id], operation: .summary, siteProfileID: siteID))
    batch.start(siteProfileID: siteID)
    try await waitUntilIdle(batch)
    let item = try XCTUnwrap(batch.queue(for: siteID)?.items.first)
    let buffer = store.draftBodyEditorBuffer(for: drafts[0].id)
    _ = store.stageDraftBody("尚未保存的正文", for: drafts[0].id, baseRevision: buffer.revision)
    XCTAssertFalse(batch.isCurrent(item: item, siteProfileID: siteID))
    XCTAssertFalse(batch.apply(itemID: item.id, siteProfileID: siteID))
    XCTAssertTrue(store.draft(for: drafts[0].id)?.summary.isEmpty == true)
  }

  func testPrivateAndOtherSiteArticlesNeverEnterQueue() throws {
    let store = try makeStore()
    var drafts = makeDrafts(store: store)
    drafts[0].visibility = .private
    var otherProfile = SiteProfile.defaultProfile
    otherProfile.id = UUID()
    store.setProfiles(store.profiles + [otherProfile])
    let other = ArticleDraft(siteProfileID: otherProfile.id, title: "其它站点", bodyMarkdown: "不应发送")
    store.setDrafts(drafts + [other])
    let batch = AIBatchMaintenanceStore(store: store)
    XCTAssertTrue(
      batch.create(
        draftIDs: Set((drafts + [other]).map(\.id)), operation: .summary,
        siteProfileID: store.activeProfileID), batch.message ?? "")
    XCTAssertEqual(batch.queue(for: store.activeProfileID)?.items.map(\.draftID), [drafts[1].id])
  }

  func testMalformedPersistedQueueIsNotOverwritten() throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store, count: 1)
    let file = store.persistenceStore.persistence.fileURL.appendingPathExtension(
      "ai-maintenance.json")
    let corrupt = Data("incomplete file".utf8)
    try corrupt.write(to: file)
    let batch = AIBatchMaintenanceStore(store: store)
    XCTAssertNotNil(batch.message)
    XCTAssertFalse(
      batch.create(
        draftIDs: [drafts[0].id], operation: .summary, siteProfileID: store.activeProfileID))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }

  func testPromptBoundsAndReviewOnlyUsesNonPrivateSameSiteTargets() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id, title: "正文", bodyMarkdown: String(repeating: "文", count: 25_000))
    var hidden = ArticleDraft(siteProfileID: profile.id, title: "秘密文章名称", bodyMarkdown: "secret")
    hidden.visibility = .private
    let other = ArticleDraft(siteProfileID: UUID(), title: "其它站点名称", bodyMarkdown: "other")
    let messages = AIBatchMaintenanceService().messages(
      operation: .internalLinksReview, draft: draft, profile: profile,
      relatedDrafts: [hidden, other])
    let text = messages.compactMap { message -> String? in
      guard case .text(let text) = message.content else { return nil }
      return text
    }.joined()
    XCTAssertFalse(text.contains("秘密文章名称"))
    XCTAssertFalse(text.contains("其它站点名称"))
    XCTAssertTrue(text.contains("正文已截取"))
    XCTAssertFalse(text.contains(String(repeating: "文", count: 24_001)))
  }

  func testProductionRunnerUsesConfiguredTransportAndDoesNotApplyAutomatically() async throws {
    let payload: [String: Any] = [
      "choices": [["message": ["role": "assistant", "content": summary]]]
    ]
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: payload), statusCode: 200)
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      keychainTokenStore: KeychainTokenStore(
        service: "AIBatchMaintenanceStoreTests.\(UUID().uuidString)",
        accountPrefix: "test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)))
    var connection = store.activeAIConnectionProfile
    connection.config = AIProviderConfig(
      preset: .local, baseURL: "http://localhost:11434/v1", model: "batch-test-model",
      requiresAPIKey: false)
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    let drafts = makeDrafts(store: store, count: 1)
    let batch = store.aiBatchMaintenance
    XCTAssertTrue(
      batch.create(
        draftIDs: [drafts[0].id], operation: .summary, siteProfileID: store.activeProfileID))
    batch.start(siteProfileID: store.activeProfileID)
    try await waitUntilIdle(batch)
    XCTAssertEqual(batch.queue(for: store.activeProfileID)?.readyCount, 1, batch.message ?? "")
    XCTAssertEqual(store.draft(for: drafts[0].id)?.summary, "")
    let request = await transport.capturedRequest()
    let body = try XCTUnwrap(request?.httpBody)
    let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(sent["model"] as? String, "batch-test-model")
    XCTAssertEqual(request?.url?.host, "localhost")
  }

  func testAuthorizationFailurePausesBeforeOtherArticlesAreDispatched() async throws {
    let store = try makeStore()
    let drafts = makeDrafts(store: store)
    var calls = 0
    let batch = AIBatchMaintenanceStore(store: store) { _, _, _ in
      calls += 1
      throw AIPublishingAssistantError.missingAPIKey
    }
    XCTAssertTrue(
      batch.create(
        draftIDs: Set(drafts.map(\.id)), operation: .summary, siteProfileID: store.activeProfileID))
    batch.start(siteProfileID: store.activeProfileID)
    try await waitUntilIdle(batch)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(batch.queue(for: store.activeProfileID)?.failedCount, 1)
    XCTAssertEqual(batch.queue(for: store.activeProfileID)?.pendingCount, 1)
    XCTAssertTrue(batch.queue(for: store.activeProfileID)?.isPaused == true)
  }
}
