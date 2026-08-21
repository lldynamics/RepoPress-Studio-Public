import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchAutomationRollbackSafetyServiceTests: XCTestCase {
  func testCreateDraftExactPostconditionAllowsMoveToTrash() {
    let draft = makeDraft(title: "Agent draft")

    let decision = evaluate(
      command: .createDraft,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: draft),
      currentDraft: draft
    )

    XCTAssertEqual(decision, .safeToMoveCreatedDraftToTrash)
  }

  func testCreateDraftNeverReturnsVersionRestoreDecision() {
    let draft = makeDraft(title: "Agent draft")
    let postcondition = WorkbenchAutomationRollbackPostcondition(
      draft: draft,
      rollbackVersionID: UUID()
    )

    let decision = evaluate(
      command: .createDraft,
      postcondition: postcondition,
      currentDraft: draft
    )

    XCTAssertEqual(decision, .safeToMoveCreatedDraftToTrash)
  }

  func testCreateDraftEditedAfterAgentConflictsOnFingerprint() {
    let original = makeDraft(title: "Agent draft")
    var edited = original
    edited.title = "User edit"

    let decision = evaluate(
      command: .createDraft,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: original),
      currentDraft: edited
    )

    guard case .conflict(.draftFingerprintMismatch) = decision else {
      return XCTFail("Expected fingerprint drift conflict, got \(decision)")
    }
  }

  func testCreateDraftUpdatedAtDriftConflictsWhenRecorded() {
    let original = makeDraft(title: "Agent draft")
    var edited = original
    edited.updatedAt = original.updatedAt.addingTimeInterval(1)

    let decision = evaluate(
      command: .createDraft,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: original),
      currentDraft: edited
    )

    guard case .conflict(.draftUpdatedAtMismatch) = decision else {
      return XCTFail("Expected updatedAt drift conflict, got \(decision)")
    }
  }

  func testCreateDraftMissingPostconditionFailsClosed() {
    let draft = makeDraft()

    let decision = evaluate(
      command: .createDraft,
      postcondition: nil,
      currentDraft: draft
    )

    XCTAssertEqual(decision, .conflict(.missingPostcondition))
  }

  func testTimestampOnlyPostconditionFailsClosed() {
    let draft = makeDraft()
    let postcondition = WorkbenchAutomationRollbackPostcondition(
      draftID: draft.id,
      updatedAt: draft.updatedAt
    )

    let decision = evaluate(
      command: .createDraft,
      postcondition: postcondition,
      currentDraft: draft
    )

    XCTAssertEqual(decision, .conflict(.missingPostMutationFingerprint))
  }

  func testCreateDraftMissingCurrentDraftConflicts() {
    let draft = makeDraft()

    let decision = evaluate(
      command: .createDraft,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: draft),
      currentDraft: nil
    )

    XCTAssertEqual(decision, .conflict(.missingCurrentDraft))
  }

  func testReplacedDraftWithDifferentIdentityConflicts() {
    let original = makeDraft(title: "Agent draft")
    let replacement = makeDraft(title: original.title)

    let decision = evaluate(
      command: .createDraft,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: original),
      currentDraft: replacement
    )

    guard case .conflict(.draftIdentityMismatch) = decision else {
      return XCTFail("Expected identity mismatch conflict, got \(decision)")
    }
  }

  func testContentMutationExactPostconditionAllowsVersionRestore() {
    let draft = makeDraft(title: "Edited article")
    let postcondition = WorkbenchAutomationRollbackPostcondition(
      draft: draft,
      rollbackVersionID: UUID()
    )

    let decision = evaluate(
      command: .appendToBody,
      postcondition: postcondition,
      currentDraft: draft
    )

    XCTAssertEqual(decision, .safeToRestoreVersion)
  }

  func testContentMutationMissingVersionConflicts() {
    let draft = makeDraft()

    let decision = evaluate(
      command: .replaceBody,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: draft),
      currentDraft: draft
    )

    XCTAssertEqual(decision, .conflict(.missingRollbackVersionID))
  }

  func testContentMutationFingerprintDriftConflicts() {
    let original = makeDraft(title: "Agent article")
    var edited = original
    edited.bodyMarkdown += "\n\nUser edit"
    let postcondition = WorkbenchAutomationRollbackPostcondition(
      draft: original,
      rollbackVersionID: UUID()
    )

    let decision = evaluate(
      command: .appendToBody,
      postcondition: postcondition,
      currentDraft: edited
    )

    guard case .conflict(.draftFingerprintMismatch) = decision else {
      return XCTFail("Expected fingerprint drift conflict, got \(decision)")
    }
  }

  func testUnknownCommandConflicts() {
    let draft = makeDraft()

    let decision = WorkbenchAutomationRollbackSafetyService.evaluate(
      rawCommand: "permanentlyDeleteDraft",
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: draft),
      currentDraft: draft
    )

    XCTAssertEqual(
      decision,
      .conflict(.unknownCommand("permanentlyDeleteDraft"))
    )
  }

  func testKnownUnsupportedCommandConflictsClosed() {
    let draft = makeDraft()

    let decision = evaluate(
      command: .openSection,
      postcondition: WorkbenchAutomationRollbackPostcondition(draft: draft),
      currentDraft: draft
    )

    XCTAssertEqual(decision, .conflict(.unsupportedCommand(.openSection)))
  }

  private func evaluate(
    command: WorkbenchAutomationCommandID,
    postcondition: WorkbenchAutomationRollbackPostcondition?,
    currentDraft: ArticleDraft?
  ) -> WorkbenchAutomationRollbackDecision {
    WorkbenchAutomationRollbackSafetyService.evaluate(
      command: command,
      postcondition: postcondition,
      currentDraft: currentDraft
    )
  }

  private func makeDraft(
    id: UUID = UUID(),
    title: String = "Test article"
  ) -> ArticleDraft {
    let profileID = UUID()
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    return ArticleDraft(
      id: id,
      siteProfileID: profileID,
      title: title,
      date: timestamp,
      slug: "test-article",
      summary: "Summary",
      bodyMarkdown: "# " + title + "\n\nBody",
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }
}
