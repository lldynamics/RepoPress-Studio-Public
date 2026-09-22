import Foundation

extension WorkbenchStore {
  public var publishExecutionRecords: [PublishExecutionRecord] {
    publishingStore.publishSession.executionRecords
  }

  public func verifyPublishExecution(_ id: UUID) async {
    await publishingStore.verifyPublishExecution(id, store: self)
  }
}
