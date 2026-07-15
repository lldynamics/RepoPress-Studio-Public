import Foundation

extension WorkbenchStore {
  func setPublishPackage(_ package: PublishPackage?) {
    publishingStore.publishPackage = package
  }

  func setLocalPublishPreview(_ preview: LocalPublishPreview?) {
    publishingStore.localPublishPreview = preview
  }

  func setLocalPublishReadiness(_ readiness: LocalPublishReadiness?) {
    publishingStore.localPublishReadiness = readiness
  }

  func setBatchPublishPlan(_ plan: BatchPublishPlan?) {
    publishingStore.batchPublishPlan = plan
  }

  func setLocalSitePreviewPlan(_ plan: LocalSitePreviewPlan?) {
    publishingStore.localSitePreviewPlan = plan
  }

  func setLocalSitePreviewRuntimeStatus(_ status: LocalSitePreviewRuntimeStatus) {
    publishingStore.localSitePreviewRuntimeStatus = status
  }

  func setRemoteReviewDraft(_ draft: RemoteReviewDraft?) {
    publishingStore.remoteReviewDraft = draft
  }

  func setBatchRemoteReviewDraft(_ draft: RemoteReviewDraft?) {
    publishingStore.batchRemoteReviewDraft = draft
  }

  func setSiteStarterResult(_ result: SiteStarterResult?) {
    publishingStore.siteStarterResult = result
  }

  func setSiteStarterImportResult(_ result: SiteStarterImportResult?) {
    publishingStore.siteStarterImportResult = result
  }

  func setSiteStarterPushResult(_ result: SiteStarterPushResult?) {
    publishingStore.siteStarterPushResult = result
  }

  func setReleaseRecords(_ records: [ReleaseRecord]) {
    publishingStore.releaseRecords = records
    invalidateSiteMaintenanceSnapshot()
  }

  public func setImageActionMessage(_ message: String?) {
    publishingStore.imageActionMessage = message
  }

  public func setPublishActionMessage(_ message: String?) {
    publishingStore.publishActionMessage = message
  }

  func setMaintenanceOperationRecords(_ records: [MaintenanceOperationRecord]) {
    publishingStore.maintenanceOperationRecords = records
    invalidateSiteMaintenanceSnapshot()
  }

  func setLatestGeneralDraftReusePlan(_ plan: GeneralDraftReusePlan?) {
    publishingStore.latestGeneralDraftReusePlan = plan
  }

  func setLatestGeneralDraftBackupWriteResult(_ result: GeneralDraftBackupWriteResult?) {
    publishingStore.latestGeneralDraftBackupWriteResult = result
  }

}
