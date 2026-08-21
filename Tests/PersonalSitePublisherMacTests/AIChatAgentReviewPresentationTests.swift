import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class AIChatAgentReviewPresentationTests: XCTestCase {
  func testReviewAccessibilityIdentifiersAreStable() {
    XCTAssertEqual(
      AIChatAgentReviewPresentation.sheetAccessibilityIdentifier,
      "ai-agent-review-sheet"
    )
    XCTAssertEqual(
      AIChatAgentReviewPresentation.laterAccessibilityIdentifier,
      "ai-agent-review-later"
    )
    XCTAssertEqual(
      AIChatAgentReviewPresentation.rejectAccessibilityIdentifier,
      "ai-agent-review-reject"
    )
    XCTAssertEqual(
      AIChatAgentReviewPresentation.acceptAccessibilityIdentifier,
      "ai-agent-review-accept"
    )
  }

  func testOnlyAgentContentChangesUseReviewPolicy() {
    let contentStep = WorkbenchAutomationStep(
      command: .appendToBody,
      arguments: WorkbenchAutomationArguments(content: "新增正文")
    )
    let agentPlan = WorkbenchAutomationPlan(
      goal: "更新文章",
      steps: [contentStep],
      source: .agentLoop
    )
    let legacyPlan = WorkbenchAutomationPlan(
      goal: "更新文章",
      steps: [contentStep],
      source: .legacy
    )

    XCTAssertTrue(
      AIChatAgentReviewPresentation.isContentChangeReview(
        plan: agentPlan,
        step: contentStep
      )
    )
    XCTAssertFalse(
      AIChatAgentReviewPresentation.isContentChangeReview(
        plan: legacyPlan,
        step: contentStep
      )
    )
  }

  func testAgentReadOnlyStepDoesNotUseReviewPolicy() {
    let readOnlyStep = WorkbenchAutomationStep(command: .auditContent)
    let plan = WorkbenchAutomationPlan(
      goal: "检查文章",
      steps: [readOnlyStep],
      source: .agentLoop
    )

    XCTAssertFalse(
      AIChatAgentReviewPresentation.isContentChangeReview(
        plan: plan,
        step: readOnlyStep
      )
    )
  }

  func testDeliveryUncertainPresentationOffersOnlySafeResolutionActions() {
    XCTAssertEqual(
      AIChatAgentReviewPresentation.deliveryUncertainAbandonTitle,
      "结束续跑并保留记录"
    )
    XCTAssertEqual(
      AIChatAgentReviewPresentation.deliveryUncertainBranchTitle,
      "从这里新建对话"
    )
    XCTAssertTrue(
      AIChatAgentReviewPresentation.deliveryUncertainWarning.contains(
        "续跑结果不确定，系统没有自动重试"
      )
    )
    XCTAssertFalse(
      [
        AIChatAgentReviewPresentation.deliveryUncertainAbandonTitle,
        AIChatAgentReviewPresentation.deliveryUncertainBranchTitle,
      ].joined(separator: " ").contains("重试")
    )
  }

  func testDeliveryUncertainStatusAndTerminalStateAreExplicit() {
    XCTAssertEqual(
      AIChatAgentReviewPresentation.deliveryUncertainWarning,
      "续跑结果不确定，系统没有自动重试"
    )
    XCTAssertEqual(
      AIChatAgentReviewPresentation.deliveryUncertainEndedTitle,
      "已结束，记录保留"
    )
    XCTAssertTrue(
      AIChatAgentReviewPresentation.isDeliveryUncertain(
        phase: .deliveryUncertain
      )
    )
    XCTAssertFalse(
      AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(
        phase: .deliveryUncertain
      )
    )
    XCTAssertTrue(
      AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(
        phase: .abandonedAfterDeliveryUncertain
      )
    )
  }

  func testDeliveryUncertainActionsRespectBusyAndConversationGates() {
    XCTAssertTrue(
      AIChatAgentReviewPresentation.canResolveDeliveryUncertain(
        phase: .deliveryUncertain,
        isBusy: false,
        conversationID: UUID()
      )
    )
    XCTAssertFalse(
      AIChatAgentReviewPresentation.canResolveDeliveryUncertain(
        phase: .deliveryUncertain,
        isBusy: true,
        conversationID: UUID()
      )
    )
    XCTAssertFalse(
      AIChatAgentReviewPresentation.canResolveDeliveryUncertain(
        phase: .deliveryUncertain,
        isBusy: false,
        conversationID: nil
      )
    )
    XCTAssertFalse(
      AIChatAgentReviewPresentation.canResolveDeliveryUncertain(
        phase: .abandonedAfterDeliveryUncertain,
        isBusy: false,
        conversationID: UUID()
      )
    )
  }

  func testRollbackActionIsHiddenWhileDeliveryDispositionIsPendingOrClosed() {
    XCTAssertFalse(
      AIChatAgentReviewPresentation.allowsRollbackAction(
        phase: .deliveryUncertain
      )
    )
    XCTAssertFalse(
      AIChatAgentReviewPresentation.allowsRollbackAction(
        phase: .abandonedAfterDeliveryUncertain
      )
    )
    XCTAssertTrue(
      AIChatAgentReviewPresentation.allowsRollbackAction(phase: nil)
    )
  }
}
