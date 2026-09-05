import Foundation

extension WorkbenchStore {
  public var operationLogEntries: [WorkbenchOperationLogEntry] {
    WorkbenchOperationLogService().entries(
      releaseRecords: releaseRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      automationRunRecords: automationRunRecords,
      aiMetadataApplicationRecords: aiMetadataApplicationRecords,
      deploymentStatusSnapshots: Array(deploymentStatusSnapshots.values),
      operationEvents: operationHistory.records,
      visibleSince: operationHistory.visibleCutoff(),
      profiles: profiles,
      drafts: drafts
    )
  }

  public var operationLogRetentionPolicy: WorkbenchOperationLogRetentionPolicy {
    operationHistory.retentionPolicy
  }

  public var operationLogStatusMessage: String? {
    operationHistory.lastErrorMessage ?? operationHistory.recoveryMessage
  }

  @discardableResult
  public func recordOperationEvent(_ record: WorkbenchOperationEventRecord) -> Bool {
    // `true` means the event is immediately projected in memory and queued.
    // It is not a disk-durability acknowledgement; await
    // `flushOperationLogPersistence()` when a durable snapshot is required.
    operationHistory.record(record)
  }

  @discardableResult
  public func setOperationLogRetentionPolicy(
    _ policy: WorkbenchOperationLogRetentionPolicy
  ) -> Bool {
    operationHistory.setRetentionPolicy(policy)
  }

  @discardableResult
  public func clearOperationLog() -> Bool {
    operationHistory.clearHistory()
  }

  public func dismissOperationLogStatusMessage() {
    operationHistory.dismissMessages()
  }

  public func flushOperationLogPersistence() async -> WorkbenchOperationLedgerDocument? {
    await operationHistory.flush()
  }
}
