import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAutomationExecutionConfirmationTests: XCTestCase {
  func testAgentConfirmationPolicyIsStricterWhileLegacyReversibleSemanticsRemainCompatible() {
    XCTAssertFalse(WorkbenchAutomationRisk.readOnly.requiresAgentConfirmation)
    XCTAssertTrue(WorkbenchAutomationRisk.reversible.requiresAgentConfirmation)
    XCTAssertTrue(WorkbenchAutomationRisk.contentChange.requiresAgentConfirmation)
    XCTAssertTrue(WorkbenchAutomationRisk.externalEffect.requiresAgentConfirmation)

    let reversibleStep = WorkbenchAutomationStep(command: .createDraft)
    let legacyPlan = WorkbenchAutomationPlan(goal: "legacy", steps: [reversibleStep])
    let agentPlan = WorkbenchAutomationPlan(
      goal: "agent",
      steps: [reversibleStep],
      source: .agentLoop
    )

    XCTAssertFalse(legacyPlan.requiresConfirmation(for: reversibleStep))
    XCTAssertTrue(agentPlan.requiresConfirmation(for: reversibleStep))
  }

  func testAgentMixedPlanExecutesOnlyReadOnlyStepUntilReversibleStepIsConfirmed() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentConfirmationMixed")
    let originalDraftCount = store.drafts.count
    let readOnlyStep = WorkbenchAutomationStep(command: .showInspector)
    let reversibleStep = WorkbenchAutomationStep(
      command: .createDraft,
      arguments: WorkbenchAutomationArguments(value: "Confirmed Agent Draft")
    )
    let plan = WorkbenchAutomationPlan(
      goal: "inspect then create",
      steps: [reversibleStep, readOnlyStep],
      source: .agentLoop
    )

    let safeResult = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(safeResult.plan.steps[0].status, .awaitingConfirmation)
    XCTAssertEqual(safeResult.plan.steps[1].status, .succeeded)
    XCTAssertEqual(safeResult.record.steps.map(\.status), [.awaitingConfirmation, .succeeded])
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
    XCTAssertEqual(store.drafts.count, originalDraftCount + 1)
    XCTAssertEqual(store.selectedDraft?.title, "Confirmed Agent Draft")
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
