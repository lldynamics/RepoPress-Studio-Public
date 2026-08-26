import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DraftAISuggestionStateTests: XCTestCase {
  func testNonSelectedMetadataSuggestionIsKeyedAndRestoredOnSelection() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: B 的新标题\nTAGS: Beta, AI")
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let draftA = drafts[0]
    let draftB = drafts[1]
    store.selectDraft(draftA.id)

    let suggestion = await store.generateAIMetadataSuggestions(draft: draftB)

    XCTAssertEqual(suggestion?.titles, ["B 的新标题"])
    XCTAssertEqual(store.aiMetadataSuggestion(for: draftB)?.tags, ["Beta", "AI"])
    XCTAssertEqual(store.aiMetadataSuggestionDraftID, draftA.id)
    XCTAssertNil(store.aiMetadataSuggestion)

    store.setSelectedDraftID(draftB.id)
    try await Task.sleep(for: .milliseconds(5))

    XCTAssertEqual(store.aiMetadataSuggestionDraftID, draftB.id)
    XCTAssertEqual(store.aiMetadataSuggestion?.titles, ["B 的新标题"])
  }

  func testMetadataRunningStateAggregatesUntilAllDraftsFinish() async throws {
    let transport = DraftSuggestionTransport(responses: [])
    let (store, drafts) = try makeStore(transport: transport)

    let generationA = store.aiStore.beginAIMetadataSuggestionOperation(for: drafts[0].id)
    let generationB = store.aiStore.beginAIMetadataSuggestionOperation(for: drafts[1].id)

    XCTAssertTrue(store.isAIMetadataSuggestionRunning)
    XCTAssertTrue(store.isAIMetadataSuggestionRunning(for: drafts[0]))
    XCTAssertTrue(store.isAIMetadataSuggestionRunning(for: drafts[1]))

    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[0].id,
      generation: generationA
    )
    XCTAssertTrue(store.isAIMetadataSuggestionRunning)
    XCTAssertTrue(store.isAIMetadataSuggestionRunning(for: drafts[1]))

    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[1].id,
      generation: generationB
    )
    XCTAssertFalse(store.isAIMetadataSuggestionRunning)
    XCTAssertFalse(store.isAIMetadataSuggestionRunning(for: drafts[0]))
    XCTAssertFalse(store.isAIMetadataSuggestionRunning(for: drafts[1]))
  }

  func testOlderSameDraftGenerationCannotReplaceNewerSuggestion() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: old title", delayNanoseconds: 300_000_000),
        .init(content: "TITLE: new title", delayNanoseconds: 20_000_000)
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)

    let oldTask = Task { await store.generateAIMetadataSuggestions(draft: drafts[0]) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let newTask = Task { await store.generateAIMetadataSuggestions(draft: drafts[0]) }

    let newerResult = await newTask.value
    let olderResult = await oldTask.value

    XCTAssertEqual(newerResult?.titles, ["new title"])
    XCTAssertNil(olderResult)
    XCTAssertEqual(store.aiMetadataSuggestion(for: drafts[0])?.titles, ["new title"])
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
  }

  func testReconcileRemovesOnlyDeletedDraftSuggestionState() async throws {
    let transport = DraftSuggestionTransport(responses: [])
    let (store, drafts) = try makeStore(transport: transport)
    let metadataA = AIPublishingMetadataSuggestion(titles: ["A title"])
    let metadataB = AIPublishingMetadataSuggestion(titles: ["B title"])
    let imageA = imageSuggestion(draftID: drafts[0].id, id: "a")
    let imageB = imageSuggestion(draftID: drafts[1].id, id: "b")

    let metadataGenerationA = store.aiStore.beginAIMetadataSuggestionOperation(
      for: drafts[0].id)
    XCTAssertTrue(
      store.aiStore.installAIMetadataSuggestion(
        metadataA,
        for: drafts[0].id,
        generation: metadataGenerationA
      )
    )
    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[0].id,
      generation: metadataGenerationA
    )
    let metadataGenerationB = store.aiStore.beginAIMetadataSuggestionOperation(
      for: drafts[1].id)
    XCTAssertTrue(
      store.aiStore.installAIMetadataSuggestion(
        metadataB,
        for: drafts[1].id,
        generation: metadataGenerationB
      )
    )
    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[1].id,
      generation: metadataGenerationB
    )

    let imageGenerationA = store.aiStore.beginAIImageTextSuggestionOperation(
      for: drafts[0].id)
    XCTAssertTrue(
      store.aiStore.installAIImageTextSuggestions(
        [imageA],
        for: drafts[0].id,
        generation: imageGenerationA
      )
    )
    store.aiStore.finishAIImageTextSuggestionOperation(
      for: drafts[0].id,
      generation: imageGenerationA
    )
    let imageGenerationB = store.aiStore.beginAIImageTextSuggestionOperation(
      for: drafts[1].id)
    XCTAssertTrue(
      store.aiStore.installAIImageTextSuggestions(
        [imageB],
        for: drafts[1].id,
        generation: imageGenerationB
      )
    )
    store.aiStore.finishAIImageTextSuggestionOperation(
      for: drafts[1].id,
      generation: imageGenerationB
    )

    store.selectDraft(drafts[0].id)
    store.setDrafts([drafts[1]])
    try await Task.sleep(for: .milliseconds(10))

    XCTAssertNil(store.aiStore.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertTrue(store.aiStore.aiImageTextSuggestions(for: drafts[0].id).isEmpty)
    XCTAssertEqual(store.aiStore.aiMetadataSuggestion(for: drafts[1].id), metadataB)
    XCTAssertEqual(store.aiStore.aiImageTextSuggestions(for: drafts[1].id), [imageB])
    XCTAssertNil(store.aiMetadataSuggestionDraftID)
    XCTAssertNil(store.aiMetadataSuggestion)
    XCTAssertNil(store.aiImageTextSuggestionDraftID)
    XCTAssertTrue(store.aiImageTextSuggestions.isEmpty)
    XCTAssertFalse(store.isAIMetadataSuggestionRunning)
    XCTAssertFalse(store.isAIImageTextRunning)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionsByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionsByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionGenerationsByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionGenerationsByDraftID.keys.contains(drafts[0].id))
  }

  func testReconcileCancelsDeletedDraftMetadataRequestAndPreventsReinstall() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: deleted", delayNanoseconds: 2_000_000_000)
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let task = Task { await store.generateAIMetadataSuggestions(draft: drafts[0]) }
    try await waitForTransportRequest(transport)

    store.aiStore.reconcileAIDraftSuggestionState(validDraftIDs: [drafts[1].id])
    let result = await task.value

    XCTAssertNil(result)
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertFalse(store.isAIMetadataSuggestionRunning(for: drafts[0]))
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionsByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionBaselinesByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionProfilesByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionGenerationsByDraftID.keys.contains(drafts[0].id))
  }

  func testReconcileCancelsDeletedDraftImageRequestAndClearsImageState() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: unused", delayNanoseconds: 2_000_000_000)
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    var imageDraft = try XCTUnwrap(store.draft(for: drafts[0].id))
    imageDraft.attachments = [
      DraftAttachment(
        originalFilename: "cover.png",
        relativePublishPath: "/images/cover.png",
        repositoryPath: "images/cover.png"
      )
    ]
    store.updateDraft(imageDraft)

    let task = Task {
      await store.generateAIImageTextSuggestions(draft: imageDraft)
    }
    try await waitForTransportRequest(transport)

    store.aiStore.reconcileAIDraftSuggestionState(validDraftIDs: [drafts[1].id])
    let result = await task.value

    XCTAssertTrue(result.isEmpty)
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertFalse(store.isAIImageTextRunning(for: imageDraft))
    XCTAssertTrue(store.aiImageTextSuggestions(for: imageDraft).isEmpty)
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionsByDraftID.keys.contains(imageDraft.id))
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionBaselinesByDraftID.keys.contains(imageDraft.id))
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionProfilesByDraftID.keys.contains(imageDraft.id))
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionSignaturesByDraftID.keys.contains(imageDraft.id))
    XCTAssertFalse(store.aiStore.aiImageTextSuggestionGenerationsByDraftID.keys.contains(imageDraft.id))
  }

  func testReconcileCancelsOnlyDeletedDraftWhileOtherDraftFinishes() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: deleted", delayNanoseconds: 2_000_000_000),
        .init(content: "TITLE: retained", delayNanoseconds: 50_000_000)
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let deletedTask = Task {
      await store.generateAIMetadataSuggestions(draft: drafts[0])
    }
    try await waitForTransportRequest(transport)
    let retainedTask = Task {
      await store.generateAIMetadataSuggestions(draft: drafts[1])
    }
    try await waitForTransportRequest(transport, expectedCount: 2)

    store.aiStore.reconcileAIDraftSuggestionState(validDraftIDs: [drafts[1].id])
    let deletedResult = await deletedTask.value
    let retainedResult = await retainedTask.value

    XCTAssertNil(deletedResult)
    XCTAssertEqual(retainedResult?.titles, ["retained"])
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertEqual(store.aiMetadataSuggestion(for: drafts[1].id)?.titles, ["retained"])
    XCTAssertFalse(store.isAIMetadataSuggestionRunning)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[1].id))
  }

  func testRequestUsesCurrentDraftSnapshotWhenCallerPassesStaleValue() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: current")
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let staleDraft = drafts[0]
    var currentDraft = try XCTUnwrap(store.draft(for: staleDraft.id))
    currentDraft.title = "当前版本标题"
    store.updateDraft(currentDraft)

    _ = await store.generateAIMetadataSuggestions(draft: staleDraft)

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let bodyText = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(bodyText.contains("当前版本标题"))
  }

  func testMetadataRequestFlushesOnlyItsStagedDraftBodyBeforeSnapshot() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: staged")
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let draft = drafts[1]
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    let stagedBody = "# B\n\n这是尚未回写到 Draft 的最新正文。"
    let stageResult = try XCTUnwrap(
      store.stageDraftBody(
        stagedBody,
        for: draft.id,
        baseRevision: buffer.revision,
        notifyEditorObservers: false
      )
    )
    XCTAssertTrue(stageResult.wasAccepted)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: draft.id).isDirty)

    let suggestion = await store.generateAIMetadataSuggestions(draft: draft)

    XCTAssertEqual(suggestion?.titles, ["staged"])
    XCTAssertFalse(store.draftBodyEditorBuffer(for: draft.id).isDirty)
    XCTAssertEqual(store.draft(for: draft.id)?.bodyMarkdown, stagedBody)
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("尚未回写到 Draft"))
  }

  func testDraftChangeDuringRequestRejectsResult() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: stale", delayNanoseconds: 250_000_000)
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let task = Task { await store.generateAIMetadataSuggestions(draft: drafts[0]) }
    try await Task.sleep(nanoseconds: 25_000_000)

    var changedDraft = try XCTUnwrap(store.draft(for: drafts[0].id))
    changedDraft.title = "请求期间已改变"
    store.updateDraft(changedDraft)

    let result = await task.value
    XCTAssertNil(result)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0]))
  }

  func testInstalledMetadataSuggestionInvalidatesAfterDraftChanges() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: before edit")
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let draft = drafts[0]

    _ = await store.generateAIMetadataSuggestions(draft: draft)
    XCTAssertEqual(store.aiMetadataSuggestion?.titles, ["before edit"])

    var changedDraft = try XCTUnwrap(store.draft(for: draft.id))
    changedDraft.summary = "AI 建议安装后的新摘要"
    store.updateDraft(changedDraft)
    try await Task.sleep(for: .milliseconds(5))

    XCTAssertNil(store.aiMetadataSuggestion(for: draft.id))
    XCTAssertNil(store.aiMetadataSuggestion)
  }

  func testImageApplyAndClearOnlyTouchTargetDraftCache() throws {
    let transport = DraftSuggestionTransport(responses: [])
    let (store, drafts) = try makeStore(transport: transport)
    let suggestionA = imageSuggestion(draftID: drafts[0].id, id: "a")
    let suggestionB = imageSuggestion(draftID: drafts[1].id, id: "b")

    let generationA = store.aiStore.beginAIImageTextSuggestionOperation(for: drafts[0].id)
    XCTAssertTrue(
      store.aiStore.installAIImageTextSuggestions(
        [suggestionA],
        for: drafts[0].id,
        generation: generationA
      )
    )
    store.aiStore.finishAIImageTextSuggestionOperation(
      for: drafts[0].id,
      generation: generationA
    )

    let generationB = store.aiStore.beginAIImageTextSuggestionOperation(for: drafts[1].id)
    XCTAssertTrue(
      store.aiStore.installAIImageTextSuggestions(
        [suggestionB],
        for: drafts[1].id,
        generation: generationB
      )
    )
    store.aiStore.finishAIImageTextSuggestionOperation(
      for: drafts[1].id,
      generation: generationB
    )

    store.selectDraft(drafts[0].id)
    store.applyAIImageTextSuggestions([suggestionB])
    XCTAssertEqual(store.aiImageTextSuggestions(for: drafts[0]), [suggestionA])
    XCTAssertTrue(store.aiImageTextSuggestions(for: drafts[1]).isEmpty)

    store.clearAIImageTextSuggestions()
    XCTAssertTrue(store.aiImageTextSuggestions(for: drafts[0]).isEmpty)
  }

  func testTrackedEditorFacadesReadOnlyTheirDraftSuggestion() throws {
    let transport = DraftSuggestionTransport(responses: [])
    let (store, drafts) = try makeStore(transport: transport)
    let suggestionA = AIPublishingMetadataSuggestion(titles: ["A suggestion"])
    let suggestionB = AIPublishingMetadataSuggestion(titles: ["B suggestion"])

    let generationA = store.aiStore.beginAIMetadataSuggestionOperation(for: drafts[0].id)
    XCTAssertTrue(
      store.aiStore.installAIMetadataSuggestion(
        suggestionA,
        for: drafts[0].id,
        generation: generationA
      )
    )
    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[0].id,
      generation: generationA
    )

    let generationB = store.aiStore.beginAIMetadataSuggestionOperation(for: drafts[1].id)
    XCTAssertTrue(
      store.aiStore.installAIMetadataSuggestion(
        suggestionB,
        for: drafts[1].id,
        generation: generationB
      )
    )
    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[1].id,
      generation: generationB
    )

    let editorA = WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: drafts[0].id)
    let editorB = WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: drafts[1].id)

    XCTAssertEqual(editorA.aiMetadataSuggestion, suggestionA)
    XCTAssertEqual(editorB.aiMetadataSuggestion, suggestionB)
  }

  private func makeStore(
    transport: DraftSuggestionTransport
  ) throws -> (WorkbenchStore, [ArticleDraft]) {
    var profile = SiteProfile.defaultProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "draft-suggestion-test",
      requiresAPIKey: false
    )
    let draftA = ArticleDraft(
      siteProfileID: profile.id,
      title: "A",
      slug: "a",
      bodyMarkdown: "# A"
    )
    let draftB = ArticleDraft(
      siteProfileID: profile.id,
      title: "B",
      slug: "b",
      bodyMarkdown: "# B"
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draftA, draftB],
      releaseRecords: []
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("DraftAISuggestionStateTests-\(UUID().uuidString)")
      .appendingPathExtension("json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: snapshot)),
      keychainTokenStore: KeychainTokenStore(
        service: "DraftAISuggestionStateTests.\(UUID().uuidString)",
        accountPrefix: "draft-suggestion-tests",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    store.selectDraft(draftA.id)
    return (store, [draftA, draftB])
  }

  private func imageSuggestion(draftID: UUID, id: String)
    -> AIPublishingImageTextSuggestion
  {
    AIPublishingImageTextSuggestion(
      id: id,
      draftID: draftID,
      attachmentID: UUID(),
      filename: "image-\(id).png",
      imagePath: "/images/image-\(id).png",
      altText: "alt \(id)",
      caption: "caption \(id)",
      reason: "test"
    )
  }

  private func waitForTransportRequest(
    _ transport: DraftSuggestionTransport,
    expectedCount: Int = 1
  ) async throws {
    for _ in 0..<100 {
      if await transport.requestCount() >= expectedCount {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for (expectedCount) AI suggestion request(s)")
  }
}

private actor DraftSuggestionTransport: AIChatTransport {
  struct Response: Sendable {
    let data: Data
    let delayNanoseconds: UInt64

    init(content: String, delayNanoseconds: UInt64 = 0) {
      self.data = (try? JSONSerialization.data(withJSONObject: [
        "model": "draft-suggestion-test",
        "choices": [[
          "message": [
            "role": "assistant",
            "content": content
          ]
        ]]
      ])) ?? Data()
      self.delayNanoseconds = delayNanoseconds
    }
  }

  private var responses: [Response]
  private var requestIndex = 0
  private var requests: [URLRequest] = []
  private var observedCancellationCount = 0

  init(responses: [Response]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let response = responses.isEmpty
      ? Response(content: "TITLE: unused")
      : responses[min(requestIndex, responses.count - 1)]
    requestIndex += 1
    if response.delayNanoseconds > 0 {
      do {
        try await Task.sleep(nanoseconds: response.delayNanoseconds)
      } catch {
        if error is CancellationError {
      observedCancellationCount += 1
        }
        throw error
      }
    }
    let url = request.url ?? URL(string: "http://127.0.0.1")!
    return (
      response.data,
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }

  func lastRequest() -> URLRequest? {
    requests.last
  }

  func requestCount() -> Int {
    requests.count
  }

  func cancellationCount() -> Int {
    observedCancellationCount
  }
}
