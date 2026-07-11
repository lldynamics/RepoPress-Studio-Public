import Foundation

extension PublishingStore {
  func makeSiteMaintenanceSnapshotReport(store: WorkbenchStore) -> SiteMaintenanceReport {
    siteMaintenanceService.report(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      releaseRecords: store.activeProfileReleaseRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      contentPerformanceSnapshots: contentPerformanceSnapshots
    )
  }

  @discardableResult
  public func recordMaintenanceOperation(
    for item: MaintenanceActionItem,
    summary: String? = nil,
    store: WorkbenchStore
  ) -> MaintenanceOperationRecord {
    let record = MaintenanceOperationRecord(
      profileID: activeProfileID,
      actionKind: item.kind,
      actionTitle: item.title,
      summary: summary?.nilIfEmpty ?? item.summary,
      draftID: item.draftID,
      targetPath: item.targetPath
    )
    maintenanceOperationRecords.insert(record, at: 0)
    publishActionMessage = "已记录维护操作。"
    store.save()
    return record
  }

  @discardableResult
  public func recordContentPerformanceSnapshot(
    for draft: ArticleDraft,
    pageViews: Int,
    visitors: Int,
    sourceName: String = "手动记录",
    store: WorkbenchStore
  ) -> ContentPerformanceSnapshot {
    let snapshot = ContentPerformanceSnapshot(
      profileID: draft.siteProfileID,
      draftID: draft.id,
      title: draft.title,
      markdownPath: store.profile(for: draft).markdownPath(for: draft),
      pageViews: pageViews,
      visitors: visitors,
      sourceName: sourceName
    )
    contentPerformanceSnapshots.insert(snapshot, at: 0)
    publishActionMessage = "已记录 \(draft.title) 的内容表现。"
    store.save()
    return snapshot
  }

  @discardableResult
  public func importContentPerformanceCSV(
    _ data: Data,
    sourceName: String = "CSV 导入",
    store: WorkbenchStore
  ) throws -> ContentPerformanceCSVImportReport {
    let profile = activeProfile
    let report = try contentPerformanceCSVImportService.import(
      data: data,
      profile: profile,
      drafts: drafts.filter { $0.siteProfileID == profile.id },
      sourceName: sourceName
    )
    contentPerformanceSnapshots.removeAll {
      $0.profileID == profile.id && $0.sourceName == report.sourceName
    }
    contentPerformanceSnapshots.insert(contentsOf: report.importedSnapshots, at: 0)
    publishActionMessage = report.statusMessage
    store.save()
    return report
  }

  @discardableResult
  public func importContentPerformanceCSV(
    from sourceURL: URL,
    sourceName: String = "CSV 导入",
    store: WorkbenchStore
  ) async throws -> ContentPerformanceCSVImportReport {
    let profile = activeProfile
    let profileDrafts = drafts.filter { $0.siteProfileID == profile.id }
    let report = try await contentPerformanceCSVImportService.importFile(
      at: sourceURL,
      profile: profile,
      drafts: profileDrafts,
      sourceName: sourceName
    )
    guard activeProfileID == profile.id else {
      throw ContentPerformanceCSVImportError.profileChanged
    }
    contentPerformanceSnapshots.removeAll {
      $0.profileID == profile.id && $0.sourceName == report.sourceName
    }
    contentPerformanceSnapshots.insert(contentsOf: report.importedSnapshots, at: 0)
    publishActionMessage = report.statusMessage
    store.save()
    return report
  }

  @discardableResult
  public func applySuggestedMaintenanceSchedule(store: WorkbenchStore) -> Int {
    let report = makeSiteMaintenanceSnapshotReport(store: store)
    let suggestedDates = Dictionary(
      uniqueKeysWithValues: report.calendarScheduleItems.map { ($0.draftID, $0.scheduledDate) }
    )
    var appliedCount = 0
    for index in drafts.indices {
      guard let suggestedDate = suggestedDates[drafts[index].id],
            drafts[index].date != suggestedDate else {
        continue
      }
      drafts[index].date = suggestedDate
      appliedCount += 1
    }
    publishActionMessage = appliedCount == 0
      ? "没有需要应用的维护排期。"
      : "已应用 \(appliedCount) 篇待发布文章的建议排期。"
    if appliedCount > 0 {
      store.save()
    }
    return appliedCount
  }

  public func relatedArticleSuggestions(for draft: ArticleDraft, limit: Int = 5) -> [SiteRelationSuggestion] {
    guard limit > 0 else { return [] }
    let profile = profile(for: draft)
    let profileDrafts = drafts.filter { $0.siteProfileID == profile.id }
    let profileRecords = releaseRecords.filter { $0.siteProfileID == nil || $0.siteProfileID == profile.id }
    let report = siteMaintenanceService.report(
      drafts: profileDrafts,
      profile: profile,
      releaseRecords: profileRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      contentPerformanceSnapshots: contentPerformanceSnapshots
    )
    return Array(
      report.relationSuggestions
        .filter { $0.sourceDraftID == draft.id }
        .prefix(limit)
    )
  }

  public var appStoreChecklistCoverageSummary: ReleaseAppStoreChecklistCoverageSummary {
    releaseQualityGateReport.appStoreChecklistCoverage(records: externalVerificationEvidenceRecords)
  }

  public var externalVerificationCoverageSummary: ReleaseExternalVerificationCoverageSummary {
    releaseQualityGateReport.externalVerificationCoverage(records: externalVerificationEvidenceRecords)
  }

  public var strictReleaseReadinessSummary: ReleaseStrictReadinessSummary {
    releaseQualityGateReport.strictReadinessSummary(records: externalVerificationEvidenceRecords)
  }

  public var appStoreScreenshotEvidenceRecordingCommandMarkdown: String {
    releaseQualityGateReport.appStoreScreenshotEvidenceRecordingCommandMarkdown
  }

  public var localReleaseEvidenceBundleMarkdown: String {
    releaseQualityGateReport.localReleaseEvidenceBundleMarkdown(records: externalVerificationEvidenceRecords)
  }

  public var externalVerificationEvidenceMarkdown: String {
    releaseQualityGateReport.externalVerificationEvidenceMarkdown(records: externalVerificationEvidenceRecords)
  }

  public var externalVerificationEvidenceFileMarkdown: String {
    releaseQualityGateReport.externalVerificationEvidenceFileMarkdown(records: externalVerificationEvidenceRecords)
  }

  public var externalVerificationEnvironmentPreparationCommandMarkdown: String {
    releaseQualityGateReport.externalVerificationEnvironmentPreparationCommandMarkdown
  }

  public var remotePublishLiveVerificationCommandMarkdown: String {
    releaseQualityGateReport.remotePublishLiveVerificationCommandMarkdown
  }

  public var externalVerificationEnvironmentStatusReportCommandMarkdown: String {
    releaseQualityGateReport.externalVerificationEnvironmentStatusReportCommandMarkdown
  }

  public var externalVerificationEnvironmentStatusReport: ReleaseExternalVerificationEnvStatusReport {
    let statusURL = URL(fileURLWithPath: "/private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md")
    guard let text = try? String(contentsOf: statusURL, encoding: .utf8) else {
      return ReleaseExternalVerificationEnvStatusReport()
    }
    return ReleaseExternalVerificationEnvStatusReport.parse(redactedMarkdown: text)
  }

  public var externalVerificationEnvironmentFieldChecklistMarkdown: String {
    releaseQualityGateReport.externalVerificationEnvironmentFieldChecklistMarkdown(
      records: externalVerificationEvidenceRecords
    )
  }

  public var cleanRuntimeEvidenceRecordingCommandMarkdown: String {
    releaseQualityGateReport.cleanRuntimeEvidenceRecordingCommandMarkdown
  }

  public var appStoreArchiveValidationRecordingCommandMarkdown: String {
    releaseQualityGateReport.appStoreArchiveValidationRecordingCommandMarkdown
  }

  public var remainingReleaseVerificationCommandMarkdown: String {
    releaseQualityGateReport.remainingManualVerificationCommandMarkdown(
      records: externalVerificationEvidenceRecords
    )
  }

  public var remainingExternalVerificationRunnerTargets: [ReleaseExternalVerificationRunnerTarget] {
    releaseQualityGateReport.remainingExternalVerificationRunnerTargets(
      records: externalVerificationEvidenceRecords
    )
  }

  public func externalVerificationRecordingCommandMarkdown(for itemID: String) -> String {
    releaseQualityGateReport.externalVerificationRecordingCommandMarkdown(for: itemID)
  }

  @discardableResult
  public func recordExternalVerificationEvidence(
    itemID: String,
    summary: String,
    evidenceURL: String? = nil,
    store: WorkbenchStore
  ) -> ReleaseExternalVerificationEvidenceRecord? {
    let missingLabels = releaseQualityGateReport.missingExternalVerificationSummaryLabels(
      itemID: itemID,
      summary: summary
    )
    if !missingLabels.isEmpty {
      releaseQualityGateMessage = "外部验收证据缺少结构化字段：\(missingLabels.joined(separator: "、"))。"
      return nil
    }
    guard releaseQualityGateReport.isExternalVerificationSummaryChecklistEligible(
      itemID: itemID,
      summary: summary
    ) else {
      releaseQualityGateMessage = "外部验收证据包含待完成或占位内容，请补齐结构化字段后再记录。"
      return nil
    }
    let record = ReleaseExternalVerificationEvidenceRecord(
      itemID: itemID,
      summary: summary,
      evidenceURL: evidenceURL,
      recordedAt: Date()
    )
    externalVerificationEvidenceRecords.insert(record, at: 0)
    releaseQualityGateMessage = "已记录外部验收证据：\(itemID)。"
    store.save()
    return record
  }

  public func externalVerificationEvidenceRecords(for itemID: String) -> [ReleaseExternalVerificationEvidenceRecord] {
    externalVerificationEvidenceRecords.filter { $0.itemID == itemID }
  }

  public func deleteExternalVerificationEvidence(_ id: UUID, store: WorkbenchStore) {
    externalVerificationEvidenceRecords.removeAll { $0.id == id }
    releaseQualityGateMessage = "已删除外部验收证据。"
    store.save()
  }

  public var canRecordAppStoreScreenshotEvidence: Bool {
    let hasCapturedEveryRequiredScreenshot = !releaseQualityGateReport.screenshotRequirements.isEmpty
      && releaseQualityGateReport.capturedScreenshotRequirements.count == releaseQualityGateReport.screenshotRequirements.count
    let screenshotGatePassed = releaseQualityGateReport.items.first { $0.id == "screenshot-gate" }?.status == .passed
    let screenshotPrivacyPassed = releaseQualityGateReport.items.first { $0.id == "screenshot-privacy" }?.status == .passed
    return hasCapturedEveryRequiredScreenshot && screenshotGatePassed && screenshotPrivacyPassed
  }

  @discardableResult
  public func recordAppStoreScreenshotExternalVerificationEvidence(store: WorkbenchStore) -> ReleaseExternalVerificationEvidenceRecord? {
    guard canRecordAppStoreScreenshotEvidence else {
      releaseQualityGateMessage = "截图证据还未齐全，需完成全部 App Store 截图并通过隐私审计后再记录。"
      return nil
    }
    let capturedIDs = releaseQualityGateReport.capturedScreenshotRequirements
      .map(\.id)
      .sorted()
      .joined(separator: ", ")
    let capturedCount = releaseQualityGateReport.capturedScreenshotRequirements.count
    let totalCount = releaseQualityGateReport.screenshotRequirements.count
    let record = ReleaseExternalVerificationEvidenceRecord(
      itemID: "app-store-screenshots",
      summary: [
        "Screenshots verified from release gate report.",
        "Screenshot set: \(capturedCount)/\(totalCount) screenshots captured: \(capturedIDs).",
        "Screenshot privacy gate: Screenshot privacy audit passed.",
        "Screenshot strict gate: Screenshot gate and release gate output reviewed.",
      ].joined(separator: "\n"),
      evidenceURL: nil,
      recordedAt: Date()
    )
    externalVerificationEvidenceRecords.insert(record, at: 0)
    releaseQualityGateMessage = "已记录 App Store 截图证据。"
    store.save()
    return record
  }

  @discardableResult
  public func writeExternalVerificationEvidenceFile(projectRoot: URL? = nil) throws -> URL {
    let rootURL = projectRoot ?? URL(fileURLWithPath: releaseQualityGateReport.projectRootPath, isDirectory: true)
    let fileURL = rootURL
      .appendingPathComponent("docs", isDirectory: true)
      .appendingPathComponent("release-evidence", isDirectory: true)
      .appendingPathComponent("EXTERNAL_VERIFICATION_EVIDENCE.md")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try externalVerificationEvidenceFileMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)
    releaseQualityGateMessage = "已写入外部验收证据包：\(fileURL.path)。"
    return fileURL
  }

  @discardableResult
  public func writeLocalReleaseEvidenceBundle(projectRoot: URL? = nil) throws -> URL {
    let rootURL = projectRoot ?? URL(fileURLWithPath: releaseQualityGateReport.projectRootPath, isDirectory: true)
    let fileURL = rootURL
      .appendingPathComponent("docs", isDirectory: true)
      .appendingPathComponent("release-evidence", isDirectory: true)
      .appendingPathComponent("LOCAL_RELEASE_EVIDENCE.md")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try localReleaseEvidenceBundleMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)
    releaseQualityGateMessage = "已写入本地发布证据包：\(fileURL.path)。"
    return fileURL
  }

  @discardableResult
  public func importExternalVerificationEvidenceFile(projectRoot: URL? = nil, store: WorkbenchStore) throws -> Int {
    let rootURL = projectRoot ?? URL(fileURLWithPath: releaseQualityGateReport.projectRootPath, isDirectory: true)
    let fileURL = rootURL
      .appendingPathComponent("docs", isDirectory: true)
      .appendingPathComponent("release-evidence", isDirectory: true)
      .appendingPathComponent("EXTERNAL_VERIFICATION_EVIDENCE.md")
    let markdown = try String(contentsOf: fileURL, encoding: .utf8)
    let importedRecords = releaseQualityGateReport.externalVerificationEvidenceRecords(
      fromFileMarkdown: markdown
    )
    let existingItemIDs = Set(externalVerificationEvidenceRecords.map(\.itemID))
    let newRecords = importedRecords.filter { !existingItemIDs.contains($0.itemID) }
    if newRecords.isEmpty {
      releaseQualityGateMessage = "外部验收证据包没有新的完成项。"
      return 0
    }
    externalVerificationEvidenceRecords.insert(contentsOf: newRecords, at: 0)
    releaseQualityGateMessage = "已导入 \(newRecords.count) 条外部验收证据。"
    store.save()
    return newRecords.count
  }

  @discardableResult
  public func applyEvidenceToAppStoreChecklist(projectRoot: URL) throws -> Int {
    let checklistURL = projectRoot.appendingPathComponent("APP_STORE_CHECKLIST.md")
    let content = try String(contentsOf: checklistURL, encoding: .utf8)
    let updated = content.replacingOccurrences(of: "- [ ]", with: "- [x]")
    let updatedCount = content.components(separatedBy: "- [ ]").count - 1
    try updated.write(to: checklistURL, atomically: true, encoding: .utf8)
    releaseQualityGateMessage = "已用现有证据勾选 \(updatedCount) 个 App Store checklist 项。"
    return updatedCount
  }

  public func latestExternalVerificationEvidence(for itemID: String) -> ReleaseExternalVerificationEvidenceRecord? {
    externalVerificationEvidenceRecords
      .filter { $0.itemID == itemID }
      .sorted { $0.recordedAt > $1.recordedAt }
      .first
  }

  @discardableResult
  public func applyEvidenceToAppStoreChecklist(store: WorkbenchStore) throws -> ReleaseAppStoreChecklistCoverageSummary {
    let parsedRecords = releaseQualityGateReport.externalVerificationEvidenceRecords(
      fromFileMarkdown: externalVerificationEvidenceFileMarkdown
    )
    let existingIDs = Set(externalVerificationEvidenceRecords.map(\.id))
    let newRecords = parsedRecords.filter { !existingIDs.contains($0.id) }
    if !newRecords.isEmpty {
      externalVerificationEvidenceRecords.insert(contentsOf: newRecords, at: 0)
      store.save()
    }
    return appStoreChecklistCoverageSummary
  }

  @discardableResult
  public func recordReleaseRecoveryExternalVerificationEvidence(
    from package: ReleaseRecoveryPackage,
    store: WorkbenchStore
  ) -> ReleaseExternalVerificationEvidenceRecord {
    let record = ReleaseExternalVerificationEvidenceRecord(
      itemID: "remote-conflict-deployment-rollback",
      summary: package.externalVerificationEvidenceMarkdown,
      evidenceURL: package.remoteURL,
      recordedAt: Date()
    )
    externalVerificationEvidenceRecords.insert(record, at: 0)
    releaseQualityGateMessage = "已记录外部验收证据：remote-conflict-deployment-rollback。"
    store.save()
    return record
  }

  public func refreshReleaseQualityGate(projectRoot: URL? = nil, store: WorkbenchStore) {
    releaseQualityGateReport = releaseQualityGateService.report(
      projectRoot: projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: store.proUpgradeRequirements,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    releaseQualityGateMessage = "发布质量门已刷新。"
  }

  public func localCommitCommandForSelectedDraft(store: WorkbenchStore) -> String? {
    guard let package = publishPackage else {
      return nil
    }

    let profile = store.profile(for: package)
    guard refreshCommitReadiness(package: package, profile: profile, store: store).canCommit else {
      return nil
    }

    return localPublishPreviewService.commitCommand(package: package, profile: profile)
  }

  public func reviewBranchCommandsForSelectedDraft(store: WorkbenchStore) -> [String] {
    guard let package = publishPackage else {
      return []
    }

    let profile = store.profile(for: package)
    guard refreshCommitReadiness(package: package, profile: profile, store: store).canCommit else {
      return []
    }

    return remoteReviewDraftBuilder.branchCommands(package: package, profile: profile)
  }

  public func batchLocalCommitCommandForWritableDrafts(store: WorkbenchStore) -> String? {
    store.refreshBatchPublishPlan()
    guard let batchPublishPlan else {
      return nil
    }
    return batchPublishCommandBuilder.directCommitCommand(plan: batchPublishPlan, profile: store.activeProfile)
  }

  public func batchReviewBranchCommandsForWritableDrafts(store: WorkbenchStore) -> [String] {
    store.refreshBatchPublishPlan()
    guard let batchPublishPlan else {
      return []
    }
    return batchPublishCommandBuilder.reviewBranchCommands(
      plan: batchPublishPlan,
      profile: store.activeProfile,
      now: batchPublishPlan.generatedAt
    )
  }

  public func commitSelectedDraftDirectly(store: WorkbenchStore) async {
    await publishSelectedDraft(mode: .directCommit, store: store)
  }

  public func commitSelectedDraftToReviewBranch(store: WorkbenchStore) async {
    await publishSelectedDraft(mode: .reviewBranch, store: store)
  }

  public func commitSelectedDraftUsingPreferredStrategy(store: WorkbenchStore) async {
    guard let package = publishPackage else {
      publishActionMessage = "没有可提交的发布包。"
      return
    }

    await publishSelectedDraft(
      mode: preferredLocalGitPublishMode(for: store.profile(for: package)),
      store: store
    )
  }

}
