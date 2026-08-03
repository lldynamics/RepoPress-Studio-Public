import Foundation

extension WorkbenchStore {
  func setPublishPackage(_ package: PublishPackage?) {
    publishingStore.publishPackage = package
  }

  func setReleaseRecords(_ records: [ReleaseRecord]) {
    publishingStore.releaseRecords = ReleaseRecord.limitedHistory(records)
    invalidateSiteMaintenanceSnapshot()
  }

  public func setImageActionMessage(_ message: String?) {
    publishingStore.imageActionMessage = message
  }

  public func setPublishActionMessage(
    _ message: String?,
    status: PublishActionMessageStatus = .information
  ) {
    publishingStore.setPublishActionMessage(message, status: status)
  }

}
