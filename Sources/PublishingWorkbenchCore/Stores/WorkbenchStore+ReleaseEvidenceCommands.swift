import Foundation

extension WorkbenchStore {
  public var appStoreChecklistCoverageSummary: ReleaseAppStoreChecklistCoverageSummary {
    publishingStore.appStoreChecklistCoverageSummary
  }

  public var externalVerificationCoverageSummary: ReleaseExternalVerificationCoverageSummary {
    publishingStore.externalVerificationCoverageSummary
  }

  public var strictReleaseReadinessSummary: ReleaseStrictReadinessSummary {
    publishingStore.strictReleaseReadinessSummary
  }

  public var appStoreScreenshotEvidenceRecordingCommandMarkdown: String {
    publishingStore.appStoreScreenshotEvidenceRecordingCommandMarkdown
  }

  public var localReleaseEvidenceBundleMarkdown: String {
    publishingStore.localReleaseEvidenceBundleMarkdown
  }

  public var externalVerificationEvidenceMarkdown: String {
    publishingStore.externalVerificationEvidenceMarkdown
  }

  public var externalVerificationEvidenceFileMarkdown: String {
    publishingStore.externalVerificationEvidenceFileMarkdown
  }

  public var externalVerificationEnvironmentPreparationCommandMarkdown: String {
    publishingStore.externalVerificationEnvironmentPreparationCommandMarkdown
  }

  public var remotePublishLiveVerificationCommandMarkdown: String {
    publishingStore.remotePublishLiveVerificationCommandMarkdown
  }

  public var externalVerificationEnvironmentStatusReportCommandMarkdown: String {
    publishingStore.externalVerificationEnvironmentStatusReportCommandMarkdown
  }

  public var externalVerificationEnvironmentStatusReport: ReleaseExternalVerificationEnvStatusReport {
    publishingStore.externalVerificationEnvironmentStatusReport
  }

  public var externalVerificationEnvironmentFieldChecklistMarkdown: String {
    publishingStore.externalVerificationEnvironmentFieldChecklistMarkdown
  }

  public var cleanRuntimeEvidenceRecordingCommandMarkdown: String {
    publishingStore.cleanRuntimeEvidenceRecordingCommandMarkdown
  }

  public var appStoreArchiveValidationRecordingCommandMarkdown: String {
    publishingStore.appStoreArchiveValidationRecordingCommandMarkdown
  }

  public var remainingReleaseVerificationCommandMarkdown: String {
    publishingStore.remainingReleaseVerificationCommandMarkdown
  }

  public var remainingExternalVerificationRunnerTargets: [ReleaseExternalVerificationRunnerTarget] {
    publishingStore.remainingExternalVerificationRunnerTargets
  }

  public func externalVerificationRecordingCommandMarkdown(for itemID: String) -> String {
    publishingStore.externalVerificationRecordingCommandMarkdown(for: itemID)
  }

  @discardableResult
  public func recordExternalVerificationEvidence(
    itemID: String,
    summary: String,
    evidenceURL: String? = nil
  ) -> ReleaseExternalVerificationEvidenceRecord? {
    publishingStore.recordExternalVerificationEvidence(
      itemID: itemID,
      summary: summary,
      evidenceURL: evidenceURL,
      store: self
    )
  }

  public func externalVerificationEvidenceRecords(
    for itemID: String
  ) -> [ReleaseExternalVerificationEvidenceRecord] {
    publishingStore.externalVerificationEvidenceRecords(for: itemID)
  }

  public func deleteExternalVerificationEvidence(_ id: UUID) {
    publishingStore.deleteExternalVerificationEvidence(id, store: self)
  }

  public var canRecordAppStoreScreenshotEvidence: Bool {
    publishingStore.canRecordAppStoreScreenshotEvidence
  }

  @discardableResult
  public func recordAppStoreScreenshotExternalVerificationEvidence() -> ReleaseExternalVerificationEvidenceRecord? {
    publishingStore.recordAppStoreScreenshotExternalVerificationEvidence(store: self)
  }

  @discardableResult
  public func writeExternalVerificationEvidenceFile(projectRoot: URL? = nil) throws -> URL {
    try publishingStore.writeExternalVerificationEvidenceFile(projectRoot: projectRoot)
  }

  @discardableResult
  public func writeLocalReleaseEvidenceBundle(projectRoot: URL? = nil) throws -> URL {
    try publishingStore.writeLocalReleaseEvidenceBundle(projectRoot: projectRoot)
  }

  @discardableResult
  public func importExternalVerificationEvidenceFile(projectRoot: URL? = nil) throws -> Int {
    try publishingStore.importExternalVerificationEvidenceFile(projectRoot: projectRoot, store: self)
  }

  @discardableResult
  public func applyEvidenceToAppStoreChecklist(projectRoot: URL) throws -> Int {
    try publishingStore.applyEvidenceToAppStoreChecklist(projectRoot: projectRoot)
  }

  public func latestExternalVerificationEvidence(
    for itemID: String
  ) -> ReleaseExternalVerificationEvidenceRecord? {
    publishingStore.latestExternalVerificationEvidence(for: itemID)
  }

  @discardableResult
  public func applyEvidenceToAppStoreChecklist() throws -> ReleaseAppStoreChecklistCoverageSummary {
    try publishingStore.applyEvidenceToAppStoreChecklist(store: self)
  }

  @discardableResult
  public func recordReleaseRecoveryExternalVerificationEvidence(
    from package: ReleaseRecoveryPackage
  ) -> ReleaseExternalVerificationEvidenceRecord {
    publishingStore.recordReleaseRecoveryExternalVerificationEvidence(from: package, store: self)
  }
}
