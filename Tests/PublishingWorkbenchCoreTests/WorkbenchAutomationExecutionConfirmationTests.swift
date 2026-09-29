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

  func testRetiredAgentMixedPlanStaysReadOnlyEvenWhenConfirmed() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "RetiredAgentConfirmation")
    let originalDraftCount = store.drafts.count
    let plan = WorkbenchAutomationPlan(
      goal: "save then inspect",
      steps: [
        WorkbenchAutomationStep(command: .saveWorkbench),
        WorkbenchAutomationStep(command: .showInspector),
      ],
      source: .agentLoop
    )
    for stepID in [nil] + plan.steps.map({ Optional($0.id) }) {
      let result = await WorkbenchAutomationExecutor.execute(
        plan: plan, in: store, onlyStepID: stepID,
        confirmedStepIDs: Set(plan.steps.map(\.id))
      )
      XCTAssertEqual(result.plan, plan)
      XCTAssertTrue(result.record.steps.allSatisfy { $0.status == .cancelled })
      XCTAssertFalse(result.record.hasRollback)
      XCTAssertEqual(store.drafts.count, originalDraftCount)
    }
  }

  func testRetiredAgentCreateDraftCannotRunOrCreateRollbackRecord() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "RetiredAgentCreate")
    let originalDraftIDs = store.drafts.map(\.id)
    let step = WorkbenchAutomationStep(
      command: .createDraft,
      arguments: WorkbenchAutomationArguments(value: "Retired Agent Draft")
    )
    let plan = WorkbenchAutomationPlan(goal: "create", steps: [step], source: .agentLoop)
    let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)
    XCTAssertEqual(result.plan, plan)
    XCTAssertEqual(result.record.steps.map(\.status), [.cancelled])
    XCTAssertEqual(store.drafts.map(\.id), originalDraftIDs)
    XCTAssertFalse(result.record.hasRollback)
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
