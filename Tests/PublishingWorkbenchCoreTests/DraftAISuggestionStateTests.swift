import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingKnowledgeCore
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

    let suggestion = await generateMetadataSuggestion(store, draft: draftB)

    XCTAssertEqual(suggestion?.titles, ["B 的新标题"])
    XCTAssertEqual(store.aiMetadataSuggestion(for: draftB.id)?.tags, ["Beta", "AI"])
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
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[1].id))

    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[0].id,
      generation: generationA
    )
    XCTAssertTrue(store.isAIMetadataSuggestionRunning)
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[1].id))

    store.aiStore.finishAIMetadataSuggestionOperation(
      for: drafts[1].id,
      generation: generationB
    )
    XCTAssertFalse(store.isAIMetadataSuggestionRunning)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[1].id))
  }

  func testOlderSameDraftGenerationCannotReplaceNewerSuggestion() async throws {
    let transport = SupersededSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)

    let oldTask = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }
    await transport.waitForFirstRequest()
    let newTask = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    let newerResult = await newTask.value
    let olderResult = await oldTask.value

    XCTAssertEqual(newerResult?.titles, ["new title"])
    XCTAssertNil(olderResult)
    XCTAssertEqual(store.aiMetadataSuggestion(for: drafts[0].id)?.titles, ["new title"])
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
  }

  func testCancelledMetadataSuccessDoesNotInstallOrPublishMessage() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    await transport.waitForRequest(1)
    task.cancel()
    await transport.complete(1, with: .success("TITLE: cancelled metadata"))
    let result = await task.value

    XCTAssertNil(result)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertNil(store.aiActionMessage)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
  }

  func testCancelledMetadataFailureDoesNotPublishMessage() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    await transport.waitForRequest(1)
    task.cancel()
    await transport.complete(1, with: .httpFailure(statusCode: 500, message: "cancelled metadata"))
    let result = await task.value

    XCTAssertNil(result)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertNil(store.aiActionMessage)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
  }

  func testCancellationClearsLoadingBeforeReleaseAndStaleFinalizerKeepsNewerLoading() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let olderTask = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    await transport.waitForRequest(1)
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    olderTask.cancel()
    await waitForCondition {
      !store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id)
    }
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))

    let newerTask = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }
    await transport.waitForRequest(2)
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))

    await transport.complete(1, with: .success("TITLE: stale after cancellation"))
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))

    await transport.complete(2, with: .success("TITLE: current after cancellation"))
    let newerResult = await newerTask.value

    XCTAssertEqual(newerResult?.titles, ["current after cancellation"])
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
  }

  func testExplicitCancellationInvalidatesPendingMetadataSuccess() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    store.aiStore.aiActionResult = AIPublishingActionResult(
      kind: .draftConclusion,
      content: "retained result"
    )
    store.aiStore.aiActionMessage = "retained message"
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    await transport.waitForRequest(1)
    store.aiStore.cancelAIGenerationRequests()
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))

    await transport.complete(1, with: .success("TITLE: cancelled request"))
    let result = await task.value

    XCTAssertNil(result)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertEqual(store.aiActionResult?.content, "retained result")
    XCTAssertEqual(store.aiActionMessage, "retained message")
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
  }

  func testOlderNonMetadataActionCannotReplaceNewerResultOrMessage() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let olderTask = Task {
      await store.performAIAction(.draftConclusion, draft: drafts[0])
    }
    await transport.waitForRequest(1)
    let newerTask = Task {
      await store.performAIAction(.draftConclusion, draft: drafts[0])
    }
    await transport.waitForRequest(2)

    await transport.complete(2, with: .success("newer conclusion"))
    let newerResult = await newerTask.value
    XCTAssertEqual(newerResult?.content, "newer conclusion")
    XCTAssertFalse(store.isAIActionRunning)
    let newerMessage = store.aiActionMessage
    XCTAssertNotNil(newerMessage)

    await transport.complete(1, with: .success("older conclusion"))
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertEqual(store.aiActionResult?.content, "newer conclusion")
    XCTAssertEqual(store.aiActionMessage, newerMessage)
    XCTAssertFalse(store.isAIActionRunning)
  }

  func testMetadataActionSupersedesPendingNonMetadataAction() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let olderTask = Task {
      await store.performAIAction(.draftConclusion, draft: drafts[0])
    }
    await transport.waitForRequest(1)
    let newerTask = Task {
      await store.performAIAction(.suggestTitles, draft: drafts[0])
    }
    await transport.waitForRequest(2)

    await transport.complete(2, with: .success("current title"))
    let newerResult = await newerTask.value
    XCTAssertEqual(newerResult?.content, "current title")
    XCTAssertFalse(store.isAIActionRunning)

    let newerMessage = store.aiActionMessage
    await transport.complete(1, with: .success("older conclusion"))
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertEqual(store.aiActionResult?.content, "current title")
    XCTAssertEqual(store.aiActionMessage, newerMessage)
    XCTAssertFalse(store.isAIActionRunning)
  }

  func testOlderMetadataActionCannotReplaceNewerResultOrSuggestion() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let olderTask = Task {
      await store.performAIAction(.suggestTitles, draft: drafts[0])
    }
    await transport.waitForRequest(1)
    let newerTask = Task {
      await store.performAIAction(.suggestTitles, draft: drafts[0])
    }
    await transport.waitForRequest(2)

    await transport.complete(2, with: .success("newer title"))
    let newerResult = await newerTask.value
    XCTAssertEqual(newerResult?.content, "newer title")
    XCTAssertEqual(store.aiMetadataSuggestion(for: drafts[0].id)?.titles, ["newer title"])
    let newerMessage = store.aiActionMessage
    XCTAssertNotNil(newerMessage)

    await transport.complete(1, with: .success("TITLE: older title"))
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertEqual(store.aiActionResult?.content, "newer title")
    XCTAssertEqual(store.aiMetadataSuggestion(for: drafts[0].id)?.titles, ["newer title"])
    XCTAssertEqual(store.aiActionMessage, newerMessage)
  }

  func testLateNonMetadataActionFailureDoesNotOverwriteNewerCompletionMessage() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let olderTask = Task {
      await store.performAIAction(.draftConclusion, draft: drafts[0])
    }
    await transport.waitForRequest(1)
    let newerTask = Task {
      await store.performAIAction(.draftConclusion, draft: drafts[0])
    }
    await transport.waitForRequest(2)

    await transport.complete(2, with: .success("retained conclusion"))
    let newerResult = await newerTask.value
    XCTAssertEqual(newerResult?.content, "retained conclusion")
    let newerMessage = store.aiActionMessage
    XCTAssertNotNil(newerMessage)

    await transport.complete(1, with: .httpFailure(statusCode: 500, message: "late failure"))
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertEqual(store.aiActionResult?.content, "retained conclusion")
    XCTAssertEqual(store.aiActionMessage, newerMessage)
    XCTAssertFalse(store.isAIActionRunning)
  }

  func testDeletedAndReinsertedDraftIDRejectsFirstMetadataRequest() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let originalDraft = drafts[0]
    let olderTask = Task {
      await generateMetadataSuggestion(store, draft: originalDraft)
    }
    await transport.waitForRequest(1)

    store.setDrafts([drafts[1]])
    store.setDrafts([originalDraft, drafts[1]])
    let newerTask = Task {
      await generateMetadataSuggestion(store, draft: originalDraft)
    }
    await transport.waitForRequest(2)

    await transport.complete(1, with: .success("TITLE: stale after reinsertion"))
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertNil(store.aiMetadataSuggestion(for: originalDraft.id))
    XCTAssertNil(store.aiActionMessage)
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(originalDraft.id))

    await transport.complete(2, with: .success("TITLE: current after reinsertion"))
    let newerResult = await newerTask.value

    XCTAssertEqual(newerResult?.titles, ["current after reinsertion"])
    XCTAssertEqual(
      store.aiMetadataSuggestion(for: originalDraft.id)?.titles,
      ["current after reinsertion"]
    )
  }

  func testReconcileRemovesOnlyDeletedDraftSuggestionState() async throws {
    let transport = DraftSuggestionTransport(responses: [])
    let (store, drafts) = try makeStore(transport: transport)
    let metadataA = AIPublishingMetadataSuggestion(titles: ["A title"])
    let metadataB = AIPublishingMetadataSuggestion(titles: ["B title"])

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

    store.selectDraft(drafts[0].id)
    store.setDrafts([drafts[1]])
    try await Task.sleep(for: .milliseconds(10))

    XCTAssertNil(store.aiStore.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertEqual(store.aiStore.aiMetadataSuggestion(for: drafts[1].id), metadataB)
    XCTAssertNil(store.aiMetadataSuggestionDraftID)
    XCTAssertNil(store.aiMetadataSuggestion)
    XCTAssertFalse(store.isAIMetadataSuggestionRunning)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionsByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(
      store.aiStore.aiMetadataSuggestionGenerationsByDraftID.keys.contains(drafts[0].id))
  }

  func testReconcileCancelsDeletedDraftMetadataRequestAndPreventsReinstall() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: deleted", delayNanoseconds: 2_000_000_000)
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }
    try await waitForTransportRequest(transport)

    store.aiStore.reconcileAIDraftSuggestionState(validDraftIDs: [drafts[1].id])
    let result = await task.value

    XCTAssertNil(result)
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionsByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionBaselinesByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionProfilesByDraftID.keys.contains(drafts[0].id))
    XCTAssertFalse(
      store.aiStore.aiMetadataSuggestionGenerationsByDraftID.keys.contains(drafts[0].id))
  }

  func testReconcileCancelsOnlyDeletedDraftWhileOtherDraftFinishes() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: deleted", delayNanoseconds: 2_000_000_000),
        .init(content: "TITLE: retained", delayNanoseconds: 50_000_000),
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let deletedTask = Task {
      await generateMetadataSuggestion(store, draft: drafts[0])
    }
    try await waitForTransportRequest(transport)
    let retainedTask = Task {
      await generateMetadataSuggestion(store, draft: drafts[1])
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

    _ = await generateMetadataSuggestion(store, draft: staleDraft)

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

    let suggestion = await generateMetadataSuggestion(store, draft: draft)

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
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }
    try await Task.sleep(nanoseconds: 25_000_000)

    var changedDraft = try XCTUnwrap(store.draft(for: drafts[0].id))
    changedDraft.title = "请求期间已改变"
    store.updateDraft(changedDraft)

    let result = await task.value
    XCTAssertNil(result)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
  }

  func testInstalledMetadataSuggestionInvalidatesAfterDraftChanges() async throws {
    let transport = DraftSuggestionTransport(
      responses: [
        .init(content: "TITLE: before edit")
      ]
    )
    let (store, drafts) = try makeStore(transport: transport)
    let draft = drafts[0]

    _ = await generateMetadataSuggestion(store, draft: draft)
    XCTAssertEqual(store.aiMetadataSuggestion?.titles, ["before edit"])

    var changedDraft = try XCTUnwrap(store.draft(for: draft.id))
    changedDraft.summary = "AI 建议安装后的新摘要"
    store.updateDraft(changedDraft)
    try await Task.sleep(for: .milliseconds(5))

    XCTAssertNil(store.aiMetadataSuggestion(for: draft.id))
    XCTAssertNil(store.aiMetadataSuggestion)
  }

  func testMetadataApplyRejectsStaleDraftAndPreservesOtherDraftCache() throws {
    let (store, drafts) = try makeStore(transport: DraftSuggestionTransport(responses: []))
    let staleSuggestion = AIPublishingMetadataSuggestion(titles: ["过期标题"])
    let retainedSuggestion = AIPublishingMetadataSuggestion(titles: ["另一篇标题"])
    installMetadataSuggestion(staleSuggestion, for: drafts[0], store: store)
    installMetadataSuggestion(retainedSuggestion, for: drafts[1], store: store)

    var changed = try XCTUnwrap(store.draft(for: drafts[0].id))
    changed.summary = "建议生成后被作者修改的摘要"
    store.updateDraft(changed)

    XCTAssertNil(store.aiStore.applyAIMetadataSuggestion(staleSuggestion, draft: changed))
    XCTAssertEqual(store.aiActionMessage, "AI 元数据建议已过期，未应用。")
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
    XCTAssertEqual(store.aiMetadataSuggestion(for: drafts[1].id), retainedSuggestion)
    XCTAssertEqual(store.draft(for: drafts[0].id)?.title, drafts[0].title)
  }

  func testMetadataApplyRejectsProfileDrift() throws {
    let (store, drafts) = try makeStore(transport: DraftSuggestionTransport(responses: []))
    let suggestion = AIPublishingMetadataSuggestion(summary: "AI 生成的摘要需要保留完整的版本身份。")
    installMetadataSuggestion(suggestion, for: drafts[0], store: store)

    var changedProfile = try XCTUnwrap(store.profiles.first)
    changedProfile.name = "已变更的站点配置"
    store.setProfiles([changedProfile])

    XCTAssertNil(store.aiStore.applyAIMetadataSuggestion(suggestion, draft: drafts[0]))
    XCTAssertEqual(store.aiActionMessage, "AI 元数据建议已过期，未应用。")
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
  }

  func testValidPartialMetadataApplicationUsesCurrentDraftAndRecordsEachField() throws {
    let (store, drafts) = try makeStore(transport: DraftSuggestionTransport(responses: []))
    let retained = AIPublishingMetadataSuggestion(
      titles: ["AI 标题"],
      summary: "AI 生成的摘要可单独保留，供作者选择应用。"
    )
    installMetadataSuggestion(retained, for: drafts[0], store: store)

    let updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(field: .title, value: "AI 标题", draft: drafts[0])
    )
    XCTAssertEqual(updated.title, "AI 标题")
    XCTAssertEqual(updated.summary, drafts[0].summary)
    let titleRecord = try XCTUnwrap(
      store.aiStore.aiMetadataApplicationRecords.first { $0.draftID == updated.id })
    XCTAssertEqual(titleRecord.fields, [.title])
    XCTAssertEqual(
      store.aiMetadataSuggestion(for: updated.id),
      AIPublishingMetadataSuggestion(summary: retained.summary)
    )

    let summaryApplied = try XCTUnwrap(
      store.applyAIMetadataSuggestion(
        field: .summary,
        value: try XCTUnwrap(retained.summary),
        draft: updated
      )
    )
    XCTAssertEqual(summaryApplied.summary, retained.summary)
    XCTAssertNil(store.aiMetadataSuggestion(for: summaryApplied.id))

    let summaryRecord = try XCTUnwrap(
      store.aiStore.aiMetadataApplicationRecords.first { $0.draftID == summaryApplied.id })
    XCTAssertEqual(summaryRecord.fields, [.summary])
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

  func testPublishingKnowledgeAuthorizationRejectsChangesBeforeSending() async throws {
    for change in ["permission", "policy", "pin"] {
      try await exercisePublishingKnowledgeAuthorization(change: change)
    }
  }

  func testPublishingKnowledgeAuthorizationAllowsUnchangedContext() async throws {
    try await exercisePublishingKnowledgeAuthorization(change: nil)
  }

  func testPublishingKnowledgeAuthorizationRevalidatesAtTransport() async throws {
    for change: String? in [nil, "permission", "policy", "pin"] {
      try await exercisePublishingKnowledgeAuthorization(change: change, atTransport: true)
    }
  }

  func testRemoteAuthorizationRevocationDuringKnowledgeWaitPreventsFirstPOST() async throws {
    for change in ["remoteMaster", "remoteConsent", "remoteKey", "remoteConfig", "remoteBinding"] {
      try await exercisePublishingKnowledgeAuthorization(change: change)
    }
  }

  func testRemoteAuthorizationRevocationAtTransportPreventsFirstPOST() async throws {
    for change in ["remoteMaster", "remoteConsent", "remoteKey", "remoteConfig", "remoteBinding"] {
      try await exercisePublishingKnowledgeAuthorization(change: change, atTransport: true)
    }
  }

  func testRemoteMasterSwitchDoesNotCancelLocalMetadataGeneration() async throws {
    let transport = DraftSuggestionTransport(responses: [.init(content: "TITLE: local")])
    let (store, drafts) = try makeStore(transport: transport)
    store.aiStore.setRemoteAIEnabled(true)
    store.aiStore.setRemoteAIEnabled(false)

    let suggestion = await generateMetadataSuggestion(store, draft: drafts[0])
    let requestCount = await transport.requestCount()

    XCTAssertEqual(suggestion?.titles, ["local"])
    XCTAssertEqual(requestCount, 1)
  }

  func testRemoteMasterSwitchKeepsAlreadyRunningLocalRequest() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport)
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    await transport.waitForRequest(1)
    store.aiStore.setRemoteAIEnabled(true)
    store.aiStore.setRemoteAIEnabled(false)
    XCTAssertTrue(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    await transport.complete(1, with: .success("TITLE: local survived"))
    let result = await task.value
    let requestCount = await transport.numberOfRequests()

    XCTAssertEqual(result?.titles, ["local survived"])
    XCTAssertEqual(requestCount, 1)
  }

  func testRemoteRevocationImmediatelyCancelsNonCooperativeMetadataRequest() async throws {
    let transport = NonCooperativeSuggestionTransport()
    let (store, drafts) = try makeStore(transport: transport, remote: true)
    let task = Task { await generateMetadataSuggestion(store, draft: drafts[0]) }

    await transport.waitForRequest(1)
    store.aiStore.revokeAIDataSharingConsent()
    XCTAssertFalse(store.aiStore.aiMetadataSuggestionRunningDraftIDs.contains(drafts[0].id))
    await transport.complete(1, with: .success("TITLE: stale remote"))
    let result = await task.value

    XCTAssertNil(result)
    XCTAssertNil(store.aiMetadataSuggestion(for: drafts[0].id))
  }

  func testRemoteAuthorizationIsRecheckedBeforeActualRetryPOST() async throws {
    let (store, _) = try makeStore(
      transport: DraftSuggestionTransport(responses: []), remote: true
    )
    let lane = AIGenerationLane.action
    let generation = store.aiStore.beginAIRequest(lane)
    defer { store.aiStore.finishAIRequest(lane, generation: generation) }
    let profile = store.activeProfile
    let binding = store.aiStore.bindNonStreamingAuthorization(lane, profile: profile)
    let apiKey = try store.aiStore.aiChatAvailableAPIKey(for: profile)
    let transport = RetryAuthorizationTransport()
    let gate = RetryAuthorizationGate()
    let aiStore = store.aiStore
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 2,
        resourceTimeout: 4,
        maximumAutomaticRetryCount: 1,
        automaticRetryBaseDelay: 0
      )
    ).authorizingNonStreamingRequests { @MainActor in
      await gate.beforeAuthorization()
      try aiStore.checkNonStreamingAuthorization(
        binding, apiKey: apiKey, lane: lane, generation: generation
      )
    }
    let request = Task {
      try await client.complete(
        request: AIChatCompletionRequest(
          model: binding.config.normalizedModel,
          messages: [AIChatMessage(role: "user", content: "fixture")]
        ),
        config: binding.config,
        apiKey: apiKey,
        purpose: .connectionTest
      )
    }

    await gate.waitForSecondAuthorization()
    store.aiStore.revokeAIDataSharingConsent()
    await gate.releaseSecondAuthorization()
    do {
      _ = try await request.value
      XCTFail("Revoked retry unexpectedly completed")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  private func exercisePublishingKnowledgeAuthorization(
    change: String?, atTransport: Bool = false
  )
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PublishingKnowledgeGate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = PublishingKnowledgeSearchGate()
    let library = KnowledgeLibraryService(
      rootURL: root.appendingPathComponent("library"),
      semanticEmbeddingService: KnowledgeSemanticEmbeddingService(providers: [gate]),
      searchCancellationCheck: { try Task.checkCancellation() }
    )
    let content = "标题 摘要 标签 元数据 A 审稿 正文 auditsecretknowledge"
    let hash = KnowledgeChunkingService.contentHash(for: content)
    let imported = try await library.commit(
      KnowledgeImportPreview(
        sourceName: "fixture",
        candidates: [
          KnowledgeImportCandidate(
            kind: .markdown, title: "A", sourceName: "a.md", allowsRemoteAIUse: true,
            originalContentHash: hash, normalizedText: content, normalizedContentHash: hash,
            sections: [KnowledgeExtractedSection(headingPath: "A", text: content)]
          )
        ]
      )
    )
    let documentID = try XCTUnwrap(imported.documentIDs.first)
    try library.setPinned(true, documentID: documentID)
    let transport = DraftSuggestionTransport(responses: [.init(content: "TITLE: accepted")])
    let beforeTransport: (@Sendable () async throws -> Void)?
    if atTransport {
      beforeTransport = { await Task.detached { gate.pauseTransport() }.value }
    } else {
      beforeTransport = nil
    }
    let (store, drafts) = try makeStore(
      transport: transport, knowledgeLibraryService: library,
      beforeTransport: beforeTransport,
      remote: change?.hasPrefix("remote") == true
    )
    await store.knowledge.reload()
    store.setAIChatKnowledgePolicy(change == "pin" ? .pinnedOnly : .automatic)
    let query = store.aiStore.knowledgeQuery(
      draft: drafts[0],
      instruction: AIPublishingActionKind.draftFrontMatterPack.displayName
    )
    XCTAssertFalse(
      try library.database().search(query: query, limit: 16, onlyRemoteAIAllowed: true).isEmpty
    )
    if !atTransport { gate.arm(query: query) }
    let operation = Task {
      await store.performAIAction(.draftFrontMatterPack, draft: drafts[0]) != nil
    }
    let started = await Task.detached { gate.waitForCapturedSearch() }.value
    guard started else {
      gate.release()
      operation.cancel()
      _ = await operation.value
      return XCTFail("Knowledge retrieval did not reach its captured-result checkpoint")
    }
    switch change {
    case "permission": try library.setAllowsRemoteAIUse(false, documentID: documentID)
    case "policy": store.setAIChatKnowledgePolicy(.off)
    case "pin": try library.setPinned(false, documentID: documentID)
    case "remoteMaster": store.aiStore.setRemoteAIEnabled(false)
    case "remoteConsent": store.aiStore.revokeAIDataSharingConsent()
    case "remoteKey":
      XCTAssertTrue(store.aiStore.saveAIAPIKey("rotated-fixture-key"))
    case "remoteConfig":
      var connection = store.activeAIConnectionProfile
      connection.config.model = "changed-fixture-model"
      XCTAssertTrue(store.updateAIConnectionProfile(connection))
    case "remoteBinding":
      let other = store.createAIConnectionProfile(named: "other-fixture", preset: .local)
      XCTAssertTrue(store.selectAIConnectionProfile(other.id))
    default: break
    }
    gate.release()
    let succeeded = await operation.value
    let count = await transport.requestCount()
    XCTAssertEqual(count, change == nil ? 1 : 0, "change=\(change ?? "none")")
    XCTAssertEqual(succeeded, change == nil)
    if change == nil {
      let request = await transport.lastRequest()
      let body = try XCTUnwrap(request?.httpBody)
      XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("auditsecretknowledge"))
    }
  }

  private func makeStore<Transport: AIChatTransport>(
    transport: Transport,
    knowledgeLibraryService: KnowledgeLibraryService? = nil,
    beforeTransport: (@Sendable () async throws -> Void)? = nil,
    remote: Bool = false
  ) throws -> (WorkbenchStore, [ArticleDraft]) {
    var profile = SiteProfile.defaultProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: remote ? .openAICompatible : .local,
      baseURL: remote ? "https://ai-fixture.example/v1" : "http://127.0.0.1:11434/v1",
      model: "draft-suggestion-test",
      requiresAPIKey: remote
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
    var client = AIChatCompletionClient(transport: transport)
    if let beforeTransport { client = client.authorizingNonStreamingRequests(beforeTransport) }
    let consentDefaults = UserDefaults(suiteName: "DraftAISuggestionConsent-\(UUID().uuidString)")!
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: snapshot)),
      knowledgeLibraryService: knowledgeLibraryService
        ?? KnowledgeLibraryService(
          rootURL: persistenceURL.deletingPathExtension().appendingPathComponent("library")
        ),
      keychainTokenStore: KeychainTokenStore(
        service: "DraftAISuggestionStateTests.\(UUID().uuidString)",
        accountPrefix: "draft-suggestion-tests",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: client
      ),
      aiDataSharingConsentStore: AIDataSharingConsentStore(defaults: consentDefaults)
    )
    if remote {
      let connection = store.activeAIConnectionProfile
      store.aiStore.grantAIDataSharingConsent(
        for: connection.config, enablingRemoteAI: true
      )
      XCTAssertTrue(store.aiStore.saveAIAPIKey("initial-fixture-key"))
    }
    store.selectDraft(draftA.id)
    return (store, [draftA, draftB])
  }

  private func installMetadataSuggestion(
    _ suggestion: AIPublishingMetadataSuggestion,
    for draft: ArticleDraft,
    store: WorkbenchStore
  ) {
    let generation = store.aiStore.beginAIMetadataSuggestionOperation(for: draft.id)
    XCTAssertTrue(
      store.aiStore.installAIMetadataSuggestion(suggestion, for: draft.id, generation: generation)
    )
    store.aiStore.finishAIMetadataSuggestionOperation(for: draft.id, generation: generation)
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

  private func waitForCondition(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
  }

  /// Drives the metadata lane through the production AI action entry point.
  @discardableResult
  private func generateMetadataSuggestion(
    _ store: WorkbenchStore,
    draft: ArticleDraft
  ) async -> AIPublishingMetadataSuggestion? {
    guard await store.performAIAction(.draftFrontMatterPack, draft: draft) != nil else {
      return nil
    }
    return store.aiMetadataSuggestion(for: draft.id)
  }
}

/// The first transport attempt cannot finish on a timer: only cancellation of
/// its task releases it. This pins the old generation before the new one starts.
private actor SupersededSuggestionTransport: AIChatTransport {
  private var requestCount = 0
  private var firstRequestSuspended = false
  private var firstRequestWaiter: CheckedContinuation<Void, Never>?
  private var suspendedFirst: CheckedContinuation<(Data, URLResponse), Error>?
  private var observedCancellationCount = 0

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCount += 1
    if requestCount == 1 {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          suspendedFirst = continuation
          firstRequestSuspended = true
          firstRequestWaiter?.resume()
          firstRequestWaiter = nil
        }
      } onCancel: {
        Task { await self.cancelFirstRequest() }
      }
    }
    let data = Data(
      #"{"model":"draft-suggestion-test","choices":[{"message":{"role":"assistant","content":"TITLE: new title"}}]}"#
        .utf8
    )
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    return (data, response)
  }

  func waitForFirstRequest() async {
    if firstRequestSuspended { return }
    await withCheckedContinuation { firstRequestWaiter = $0 }
  }

  private func cancelFirstRequest() {
    guard let suspendedFirst else { return }
    self.suspendedFirst = nil
    observedCancellationCount += 1
    suspendedFirst.resume(throwing: CancellationError())
  }

  func cancellationCount() -> Int { observedCancellationCount }
}

private actor DraftSuggestionTransport: AIChatTransport {
  struct Response: Sendable {
    let data: Data
    let delayNanoseconds: UInt64

    init(content: String, delayNanoseconds: UInt64 = 0) {
      self.data =
        (try? JSONSerialization.data(withJSONObject: [
          "model": "draft-suggestion-test",
          "choices": [
            [
              "message": [
                "role": "assistant",
                "content": content,
              ]
            ]
          ],
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
    let response =
      responses.isEmpty
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

private actor NonCooperativeSuggestionTransport: AIChatTransport {
  enum Completion: Sendable {
    case success(String)
    case httpFailure(statusCode: Int, message: String)
  }

  private var requestCount = 0
  private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var completions: [Int: CheckedContinuation<Completion, Never>] = [:]

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCount += 1
    let requestNumber = requestCount
    resumeRequestWaiters()
    let completion = await withCheckedContinuation { continuation in
      completions[requestNumber] = continuation
    }
    let url = request.url ?? URL(string: "http://127.0.0.1")!
    switch completion {
    case .success(let content):
      let data = try JSONSerialization.data(withJSONObject: [
        "model": "draft-suggestion-test",
        "choices": [
          [
            "message": [
              "role": "assistant",
              "content": content,
            ]
          ]
        ],
      ])
      return (
        data,
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    case .httpFailure(let statusCode, let message):
      return (
        try JSONSerialization.data(withJSONObject: ["error": message]),
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
      )
    }
  }

  func numberOfRequests() -> Int { requestCount }

  func waitForRequest(_ count: Int) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append((count: count, continuation: continuation))
    }
  }

  func complete(_ requestNumber: Int, with completion: Completion) {
    completions.removeValue(forKey: requestNumber)?.resume(returning: completion)
  }

  private func resumeRequestWaiters() {
    let ready = requestWaiters.filter { $0.count <= requestCount }
    requestWaiters.removeAll { $0.count <= requestCount }
    for waiter in ready { waiter.continuation.resume() }
  }
}

/// Search computes the query embedding after capturing its lexical results.
/// Gate only the exact request query, so startup maintenance cannot consume it.
private final class PublishingKnowledgeSearchGate: KnowledgeSemanticEmbeddingProvider,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var expectedQuery: String?
  private let captured = DispatchSemaphore(value: 0)
  private let resumed = DispatchSemaphore(value: 0)

  var descriptor: KnowledgeSemanticEmbeddingDescriptor {
    .init(
      modelIdentifier: "publishing-test-gate", dimension: 1, minimumSimilarity: 0,
      maximumTokenCount: 512, weightsVersion: "test", preprocessingVersion: "test"
    )
  }

  func arm(query: String) {
    lock.lock()
    expectedQuery = query
    lock.unlock()
  }

  func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector? {
    guard input.role == .query else { return nil }
    lock.lock()
    let shouldWait = expectedQuery == input.text
    if shouldWait { expectedQuery = nil }
    lock.unlock()
    if shouldWait {
      captured.signal()
      _ = resumed.wait(timeout: .now() + 10)
    }
    return nil
  }

  func waitForCapturedSearch() -> Bool {
    captured.wait(timeout: .now() + 10) == .success
  }

  func pauseTransport() {
    captured.signal()
    _ = resumed.wait(timeout: .now() + 10)
  }

  func release() { resumed.signal() }
}

private actor RetryAuthorizationGate {
  private var authorizationCount = 0
  private var secondEntered: CheckedContinuation<Void, Never>?
  private var releaseSecond: CheckedContinuation<Void, Never>?

  func beforeAuthorization() async {
    authorizationCount += 1
    guard authorizationCount == 2 else { return }
    secondEntered?.resume()
    secondEntered = nil
    await withCheckedContinuation { releaseSecond = $0 }
  }

  func waitForSecondAuthorization() async {
    if authorizationCount >= 2 { return }
    await withCheckedContinuation { secondEntered = $0 }
  }

  func releaseSecondAuthorization() {
    releaseSecond?.resume()
    releaseSecond = nil
  }
}

private actor RetryAuthorizationTransport: AIChatTransport {
  private var count = 0

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    count += 1
    if count == 1 { throw URLError(.timedOut) }
    let data = Data(
      #"{"model":"fixture","choices":[{"message":{"role":"assistant","content":"unexpected retry"}}]}"#
        .utf8
    )
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    return (data, response)
  }

  func requestCount() -> Int { count }
}
