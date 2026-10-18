import Foundation

@testable import PublishingWorkbenchCore

extension WorkbenchAIAgentToolRunRecord {
  /// Builds a historical built-in tool run the way retired Agent records were stored.
  init(
    toolCallID: String,
    command: WorkbenchAutomationCommandID,
    status: WorkbenchAIAgentToolRunStatus,
    summary: String,
    automationStepID: UUID? = nil,
    targetDraftID: UUID? = nil,
    startedAt: Date,
    completedAt: Date? = nil
  ) {
    self.init(
      toolCallID: toolCallID,
      toolID: Self.toolID(for: command),
      modelToolName: command.rawValue,
      executionPolicy: .requiresConfirmation,
      catalogRevision: Self.legacyCatalogRevision,
      status: status,
      summary: summary,
      correlationID: automationStepID ?? UUID(),
      automationStepID: automationStepID,
      targetDraftID: targetDraftID,
      startedAt: startedAt,
      completedAt: completedAt
    )
  }
}
