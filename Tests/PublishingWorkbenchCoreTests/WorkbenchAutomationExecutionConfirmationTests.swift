import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAutomationExecutionConfirmationTests: XCTestCase {
  func testAgentConfirmationPolicyIsStricterWhileLegacyReversibleSemanticsRemainCompatible() {
    XCTAssertFalse(WorkbenchAutomationRisk.readOnly.requiresAgentConfirmation)
    XCTAssertTrue(WorkbenchAutomationRisk.reversible.requiresAgentConfirmation)
    XCTAssertTrue(WorkbenchAutomationRisk.contentChange.requiresAgentConfirmation)
    XCTAssertTrue(WorkbenchAutomationRisk.externalEffect.requiresAgentConfirmation)

    let reversibleStep = WorkbenchAutomationStep(command: .saveWorkbench)
    let legacyPlan = WorkbenchAutomationPlan(goal: "legacy", steps: [reversibleStep])
    let agentPlan = WorkbenchAutomationPlan(
      goal: "agent",
      steps: [reversibleStep],
      source: .agentLoop
    )

    XCTAssertFalse(legacyPlan.requiresConfirmation(for: reversibleStep))
    XCTAssertTrue(agentPlan.requiresConfirmation(for: reversibleStep))

    let createDraftStep = WorkbenchAutomationStep(command: .createDraft)
    let createDraftAgentPlan = WorkbenchAutomationPlan(
      goal: "agent create",
      steps: [createDraftStep],
      source: .agentLoop
    )
    XCTAssertFalse(createDraftAgentPlan.requiresConfirmation(for: createDraftStep))
    XCTAssertFalse(
      WorkbenchAutomationPlan(
        goal: "agent read",
        steps: [WorkbenchAutomationStep(command: .showInspector)],
        source: .agentLoop
      ).requiresConfirmation(for: WorkbenchAutomationStep(command: .showInspector))
    )
  }

  func testAgentMixedPlanStopsAtConfirmationBarrierAndResumesExplicitly() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentConfirmationMixed")
    let originalDraftCount = store.drafts.count
    let readOnlyStep = WorkbenchAutomationStep(command: .showInspector)
    let reversibleStep = WorkbenchAutomationStep(command: .saveWorkbench)
    let plan = WorkbenchAutomationPlan(
      goal: "save then inspect",
      steps: [reversibleStep, readOnlyStep],
      source: .agentLoop
    )

    let safeResult = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(safeResult.plan.steps[0].status, .awaitingConfirmation)
    XCTAssertEqual(safeResult.plan.steps[1].status, .proposed)
    XCTAssertEqual(safeResult.record.steps.map(\.status), [.awaitingConfirmation])
    XCTAssertEqual(store.drafts.count, originalDraftCount)

    let stillUnconfirmed = await WorkbenchAutomationExecutor.execute(
      plan: safeResult.plan,
      in: store,
      onlyStepID: reversibleStep.id
    )
    XCTAssertEqual(stillUnconfirmed.plan.steps[0].status, .awaitingConfirmation)
    XCTAssertEqual(stillUnconfirmed.record.steps.map(\.status), [.awaitingConfirmation])
    XCTAssertEqual(store.drafts.count, originalDraftCount)

    let confirmed = await WorkbenchAutomationExecutor.execute(
      plan: stillUnconfirmed.plan,
      in: store,
      onlyStepID: reversibleStep.id,
      confirmedStepIDs: [reversibleStep.id]
    )
    XCTAssertEqual(confirmed.plan.steps[0].status, .succeeded)
    XCTAssertEqual(confirmed.record.steps.map(\.status), [.succeeded])
    XCTAssertEqual(store.drafts.count, originalDraftCount)

    let resumedReadOnly = await WorkbenchAutomationExecutor.execute(
      plan: confirmed.plan,
      in: store,
      onlyStepID: readOnlyStep.id
    )
    XCTAssertEqual(resumedReadOnly.plan.steps[1].status, .succeeded)
    XCTAssertEqual(resumedReadOnly.record.steps.map(\.status), [.succeeded])
  }

  func testAgentCreateDraftRunsWithoutConfirmationAndRemainsRollbackEligible() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentAutomaticCreate")
    let originalDraftCount = store.drafts.count
    let step = WorkbenchAutomationStep(
      command: .createDraft,
      arguments: WorkbenchAutomationArguments(value: "Automatic Agent Draft")
    )
    let plan = WorkbenchAutomationPlan(goal: "create", steps: [step], source: .agentLoop)

    let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(result.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(store.drafts.count, originalDraftCount + 1)
    XCTAssertEqual(store.selectedDraft?.title, "Automatic Agent Draft")
    XCTAssertEqual(result.record.steps.first?.targetDraftID, store.selectedDraft?.id)
    XCTAssertTrue(result.record.hasRollback)
    let createdDraftID = try XCTUnwrap(result.record.steps.first?.targetDraftID)
    let createdDraft = try XCTUnwrap(store.drafts.first { $0.id == createdDraftID })
    XCTAssertTrue(createdDraft.isGeneralDraft)
    XCTAssertNil(createdDraft.repositoryPath)
    XCTAssertNil(store.siteDraftFileSaveStates[createdDraftID])

    let rollback = WorkbenchAutomationExecutor.rollbackDetailed(
      record: result.record,
      in: store
    )

    XCTAssertEqual(rollback.restoredCount, 1)
    XCTAssertEqual(store.drafts.count, originalDraftCount)
    XCTAssertTrue(store.recycledDrafts.contains { $0.id == createdDraftID })
  }

  func testLegacyReversiblePlanStillExecutesWithoutNewPerStepConfirmation() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "LegacyConfirmationCompatibility")
    let originalDraftCount = store.drafts.count
    let step = WorkbenchAutomationStep(
      command: .createDraft,
      arguments: WorkbenchAutomationArguments(value: "Legacy Draft")
    )
    let plan = WorkbenchAutomationPlan(goal: "legacy create", steps: [step])

    let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(result.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(result.record.steps.first?.status, .succeeded)
    XCTAssertEqual(store.drafts.count, originalDraftCount + 1)
    XCTAssertFalse(store.selectedDraft?.isGeneralDraft ?? true)
  }

  func testContentMutationReusesEquivalentExistingRollbackVersion() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationExistingRollbackVersion")
    let draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertTrue(store.createManualVersion(for: draft.id))
    let existingVersion = try XCTUnwrap(store.versions(for: draft.id).first)

    let step = WorkbenchAutomationStep(
      command: .appendToBody,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        expectedDraftUpdatedAt: draft.updatedAt,
        content: "复用已有版本后的新段落"
      )
    )
    let plan = WorkbenchAutomationPlan(goal: "复用已有回滚版本", steps: [step])
    let result = await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: store,
      confirmedStepIDs: [step.id]
    )

    XCTAssertEqual(result.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(result.record.steps.first?.rollbackVersionID, existingVersion.id)
    XCTAssertEqual(store.versions(for: draft.id).count, 1)
    XCTAssertTrue(store.selectedDraft?.bodyMarkdown.contains("复用已有版本后的新段落") == true)
  }

  func testPlansDecodedWithoutSourceRemainLegacyCompatible() throws {
    let plan = WorkbenchAutomationPlan(
      goal: "old snapshot",
      steps: [WorkbenchAutomationStep(command: .createDraft)]
    )
    let encoded = try JSONEncoder.workbench.encode(plan)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "source")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchAutomationPlan.self,
      from: legacyData
    )

    XCTAssertEqual(decoded.source, .legacy)
    XCTAssertFalse(decoded.requiresConfirmation(for: decoded.steps[0]))
  }
}
