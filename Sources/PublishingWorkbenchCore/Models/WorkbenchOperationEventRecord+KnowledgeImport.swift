import PublishingKnowledgeCore

extension WorkbenchOperationEventRecord {
  init(knowledgeImport event: KnowledgeImportEvent) {
    let outcome: WorkbenchOperationLogOutcome
    switch event.outcome {
    case .succeeded: outcome = .succeeded
    case .partial: outcome = .partial
    case .failed: outcome = .failed
    case .cancelled: outcome = .cancelled
    case .recorded: outcome = .recorded
    }
    self.init(
      id: event.id,
      kind: .knowledgeImport,
      outcome: outcome,
      occurredAt: event.occurredAt,
      createdItemCount: event.createdItemCount,
      updatedItemCount: event.updatedItemCount,
      skippedItemCount: event.skippedItemCount
    )
  }
}
