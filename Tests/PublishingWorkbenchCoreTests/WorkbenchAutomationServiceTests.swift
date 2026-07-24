import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAutomationServiceTests: XCTestCase {
  func testRegistryKeepsExternalCommandsBehindExplicitConfirmation() throws {
    let publish = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .publishOnline))
    let write = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .writeLocalRepository))
    let content = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .replaceBody))
    let preflight = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .runPreflight))

    XCTAssertTrue(publish.risk.requiresExplicitConfirmation)
    XCTAssertFalse(publish.requiresDraft)
    XCTAssertTrue(write.risk.requiresExplicitConfirmation)
    XCTAssertTrue(content.risk.requiresExplicitConfirmation)
    XCTAssertFalse(preflight.risk.requiresExplicitConfirmation)
  }

  func testPublishPlanTargetsAllPendingSiteChangesInsteadOfCurrentDraft() throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let response = """
    <workbench_automation_plan>
    {"goal":"发布全部变更","steps":[{"command":"publishOnline","arguments":{}}]}
    </workbench_automation_plan>
    """

    let parsed = WorkbenchAutomationPlanParser.parse(response, currentDraft: draft)
    let step = try XCTUnwrap(parsed.plan?.steps.first)

    XCTAssertEqual(step.command, .publishOnline)
    XCTAssertNil(step.arguments.draftID)
    XCTAssertNil(step.arguments.expectedDraftUpdatedAt)
  }

  func testParserExtractsValidatedPlanAndRemovesMachinePayloadFromVisibleReply() throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let response = """
    我可以先检查文章，再等待你确认是否修改摘要。
    <workbench_automation_plan>
    {
      "goal": "检查并补全摘要",
      "steps": [
        {"command": "runPreflight", "arguments": {"draftID": "\(draft.id.uuidString)"}},
        {"command": "updateMetadata", "arguments": {"draftID": "\(draft.id.uuidString)", "metadataField": "summary", "value": "新的文章摘要"}}
      ]
    }
    </workbench_automation_plan>
    """

    let parsed = WorkbenchAutomationPlanParser.parse(response, currentDraft: draft)
    let plan = try XCTUnwrap(parsed.plan)

    XCTAssertEqual(parsed.displayContent, "我可以先检查文章，再等待你确认是否修改摘要。")
    XCTAssertEqual(plan.goal, "检查并补全摘要")
    XCTAssertEqual(plan.steps.map(\.command), [.runPreflight, .updateMetadata])
    XCTAssertEqual(plan.steps[0].arguments.draftID, draft.id)
    XCTAssertEqual(plan.steps[1].arguments.expectedDraftUpdatedAt, draft.updatedAt)
  }

  func testParserRejectsUnknownCommandInsteadOfGuessing() throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let response = """
    <workbench_automation_plan>
    {"goal":"运行任意代码","steps":[{"command":"runShell","arguments":{"value":"rm -rf /"}}]}
    </workbench_automation_plan>
    """

    let parsed = WorkbenchAutomationPlanParser.parse(response, currentDraft: draft)

    XCTAssertNil(parsed.plan)
    XCTAssertTrue(parsed.displayContent.contains("runShell"))
  }

  func testExecutorRunsSafeStepWithoutConfirmation() async throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .runPreflight,
      arguments: WorkbenchAutomationArguments(draftID: draft.id)
    )
    let plan = WorkbenchAutomationPlan(goal: "检查文章", steps: [step])

    let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(result.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(result.record.steps.first?.status, .succeeded)
    XCTAssertEqual(store.selectedDraftID, draft.id)
  }

  func testContentMutationRequiresConfirmationAndCreatesRollbackVersion() async throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .appendToBody,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        expectedDraftUpdatedAt: draft.updatedAt,
        content: "新增段落"
      )
    )
    let plan = WorkbenchAutomationPlan(goal: "追加段落", steps: [step])

    let unconfirmed = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)
    XCTAssertEqual(unconfirmed.plan.steps.first?.status, .awaitingConfirmation)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, draft.bodyMarkdown)

    let confirmed = await WorkbenchAutomationExecutor.execute(
      plan: unconfirmed.plan,
      in: store,
      onlyStepID: step.id,
      confirmedStepIDs: Set([step.id])
    )
    XCTAssertEqual(confirmed.plan.steps.first?.status, .succeeded)
    XCTAssertTrue(store.selectedDraft?.bodyMarkdown.contains("新增段落") == true)
    XCTAssertNotNil(confirmed.record.steps.first?.rollbackVersionID)

    let restoredCount = WorkbenchAutomationExecutor.rollback(record: confirmed.record, in: store)
    XCTAssertEqual(restoredCount, 1)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, draft.bodyMarkdown)
  }

  func testExecutorRejectsContentMutationWhenDraftChangedAfterPlanning() async throws {
    let store = WorkbenchStore()
    let original = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .updateMetadata,
      arguments: WorkbenchAutomationArguments(
        draftID: original.id,
        expectedDraftUpdatedAt: original.updatedAt,
        metadataField: .summary,
        value: "计划中的摘要"
      )
    )
    let plan = WorkbenchAutomationPlan(goal: "修改摘要", steps: [step])

    var changed = original
    changed.title = "另一窗口的新标题"
    store.updateDraft(changed)

    let result = await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: store,
      confirmedStepIDs: Set([step.id])
    )

    XCTAssertEqual(result.plan.steps.first?.status, .failed)
    XCTAssertEqual(store.selectedDraft?.summary, original.summary)
    XCTAssertTrue(result.record.steps.first?.message.contains("发生变化") == true)
  }

  func testAutomationRunHistoryRoundTripsInWorkbenchSnapshot() throws {
    let store = WorkbenchStore()
    let record = WorkbenchAutomationRunRecord(
      planID: UUID(),
      goal: "保存工作台",
      startedAt: Date(),
      steps: [
        WorkbenchAutomationStepRecord(
          command: .saveWorkbench,
          status: .succeeded,
          message: "工作台已保存。"
        )
      ]
    )
    let snapshot = WorkbenchSnapshot(
      profiles: store.profiles,
      activeProfileID: store.activeProfileID,
      drafts: store.drafts,
      releaseRecords: store.releaseRecords,
      automationRunRecords: [record]
    )

    let data = try JSONEncoder.workbench.encode(snapshot)
    let decoded = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)

    XCTAssertEqual(decoded.automationRunRecords.count, 1)
    XCTAssertEqual(decoded.automationRunRecords.first?.id, record.id)
    XCTAssertEqual(decoded.automationRunRecords.first?.planID, record.planID)
    XCTAssertEqual(decoded.automationRunRecords.first?.goal, record.goal)
    XCTAssertEqual(decoded.automationRunRecords.first?.steps.map(\.command), [.saveWorkbench])
    XCTAssertEqual(decoded.formatVersion, WorkbenchSnapshot.currentFormatVersion)
  }
}
