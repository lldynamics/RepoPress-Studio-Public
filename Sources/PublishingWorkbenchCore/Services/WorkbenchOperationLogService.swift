import Foundation

/// A non-persistent, privacy-aware projection over existing workbench records.
/// It intentionally does not surface source free text such as messages, paths,
/// URLs, AI value diffs, or article bodies.
public struct WorkbenchOperationLogService: Sendable {
  public static let maximumEntryCount = 500

  public init() {}

  public func entries(
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord],
    automationRunRecords: [WorkbenchAutomationRunRecord],
    aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord],
    deploymentStatusSnapshots: [DeploymentStatusSnapshot],
    operationEvents: [WorkbenchOperationEventRecord] = [],
    visibleSince: Date? = nil,
    profiles: [SiteProfile],
    drafts: [ArticleDraft],
    maximumEntryCount: Int = Self.maximumEntryCount
  ) -> [WorkbenchOperationLogEntry] {
    let profileNames = Dictionary(
      profiles.map { ($0.id, $0.name) },
      uniquingKeysWith: { current, _ in current }
    )
    let draftTitles = Dictionary(
      drafts.map { ($0.id, $0.title) },
      uniquingKeysWith: { current, _ in current }
    )
    let draftProfileIDs = Dictionary(
      drafts.map { ($0.id, $0.siteProfileID) },
      uniquingKeysWith: { current, _ in current }
    )
    let releaseRecordsByID = Dictionary(
      releaseRecords.map { ($0.id, $0) },
      uniquingKeysWith: { current, candidate in
        current.createdAt >= candidate.createdAt ? current : candidate
      }
    )

    var projected: [WorkbenchOperationLogEntry] = []
    projected.reserveCapacity(
      releaseRecords.count
        + maintenanceOperationRecords.count
        + automationRunRecords.count
        + aiMetadataApplicationRecords.count
        + deploymentStatusSnapshots.count
        + operationEvents.count
    )
    projected.append(
      contentsOf: releaseRecords.map {
        releaseEntry($0, profileNames: profileNames, draftTitles: draftTitles)
      })
    projected.append(
      contentsOf: maintenanceOperationRecords.map {
        maintenanceEntry($0, profileNames: profileNames, draftTitles: draftTitles)
      })
    projected.append(
      contentsOf: automationRunRecords.map {
        automationEntry(
          $0,
          profileNames: profileNames,
          draftTitles: draftTitles,
          draftProfileIDs: draftProfileIDs
        )
      })
    projected.append(
      contentsOf: aiMetadataApplicationRecords.map {
        aiMetadataEntry($0, profileNames: profileNames, draftTitles: draftTitles)
      })
    projected.append(
      contentsOf: deploymentStatusSnapshots.compactMap {
        deploymentEntry(
          $0,
          releaseRecordsByID: releaseRecordsByID,
          profileNames: profileNames,
          draftTitles: draftTitles
        )
      })
    projected.append(
      contentsOf: operationEvents.map {
        operationEventEntry(
          $0,
          profileNames: profileNames,
          draftTitles: draftTitles
        )
      })

    var seenEntryIDs = Set<String>()
    return Array(
      projected.filter { entry in
        visibleSince.map { entry.occurredAt > $0 } ?? true
      }.sorted {
        if $0.occurredAt != $1.occurredAt {
          return $0.occurredAt > $1.occurredAt
        }
        return $0.id < $1.id
      }
      .filter { seenEntryIDs.insert($0.id).inserted }
      .prefix(max(0, maximumEntryCount))
    )
  }

  private func operationEventEntry(
    _ record: WorkbenchOperationEventRecord,
    profileNames: [UUID: String],
    draftTitles: [UUID: String]
  ) -> WorkbenchOperationLogEntry {
    WorkbenchOperationLogEntry(
      sourceReference: .init(kind: .operationEvent, id: record.id),
      category: record.kind.category,
      outcome: record.outcome,
      actor: record.actor,
      title: operationEventTitle(record.kind),
      summary: operationEventSummary(record),
      profileID: record.profileID,
      draftID: record.draftID,
      targetLabel: targetLabel(
        draftID: record.draftID,
        profileID: record.profileID,
        draftTitles: draftTitles,
        profileNames: profileNames
      ),
      occurredAt: record.occurredAt,
      systemImage: operationEventSystemImage(record.kind)
    )
  }

  private func operationEventTitle(_ kind: WorkbenchOperationEventKind) -> String {
    switch kind {
    case .localContentImport:
      CoreL10n.text("本地内容导入")
    case .remoteContentImport:
      CoreL10n.text("远程内容导入")
    case .contentMigration:
      CoreL10n.text("内容迁移")
    case .siteImport:
      CoreL10n.text("站点导入")
    case .knowledgeImport:
      CoreL10n.text("资料导入")
    case .imagePrivacySanitization:
      CoreL10n.text("图片隐私清理")
    case .imageJPEGOptimization:
      CoreL10n.text("JPEG 优化")
    case .imageWebPConversion:
      CoreL10n.text("WebP 转换")
    case .imageSVGOptimization:
      CoreL10n.text("SVG 优化")
    case .imageResize:
      CoreL10n.text("大图缩放")
    case .imageCoverCrop:
      CoreL10n.text("封面裁剪")
    case .workspaceBackupCreated:
      CoreL10n.text("工作区备份")
    case .workspaceRestorePrepared:
      CoreL10n.text("工作区恢复已准备")
    case .workspaceRestoreCompleted:
      CoreL10n.text("工作区恢复")
    }
  }

  private func operationEventSummary(_ record: WorkbenchOperationEventRecord) -> String {
    switch record.kind {
    case .localContentImport, .remoteContentImport, .contentMigration, .siteImport,
      .knowledgeImport:
      guard
        record.createdItemCount != nil || record.updatedItemCount != nil
          || record.skippedItemCount != nil
      else {
        return CoreL10n.format("操作结果：%@", record.outcome.displayName)
      }
      return CoreL10n.format(
        "新增 %d 项 · 更新 %d 项 · 跳过 %d 项",
        record.createdItemCount ?? 0,
        record.updatedItemCount ?? 0,
        record.skippedItemCount ?? 0
      )
    case .imagePrivacySanitization, .imageJPEGOptimization, .imageWebPConversion,
      .imageSVGOptimization, .imageResize, .imageCoverCrop:
      guard
        record.processedItemCount != nil || record.skippedItemCount != nil
          || record.savedByteCount != nil
      else {
        return CoreL10n.format("操作结果：%@", record.outcome.displayName)
      }
      let processed = record.processedItemCount ?? 0
      let skipped = record.skippedItemCount ?? 0
      guard let savedByteCount = record.savedByteCount, savedByteCount > 0 else {
        return CoreL10n.format("处理 %d 张 · 跳过 %d 张", processed, skipped)
      }
      let saved = ByteCountFormatter.string(fromByteCount: savedByteCount, countStyle: .file)
      return CoreL10n.format("处理 %d 张 · 跳过 %d 张 · 节省 %@", processed, skipped, saved)
    case .workspaceBackupCreated, .workspaceRestorePrepared, .workspaceRestoreCompleted:
      guard record.draftCount != nil || record.draftVersionCount != nil else {
        return CoreL10n.format("操作结果：%@", record.outcome.displayName)
      }
      return CoreL10n.format(
        "草稿 %d 篇 · 历史版本 %d 个",
        record.draftCount ?? 0,
        record.draftVersionCount ?? 0
      )
    }
  }

  private func operationEventSystemImage(_ kind: WorkbenchOperationEventKind) -> String {
    switch kind {
    case .localContentImport: "doc.badge.arrow.down"
    case .remoteContentImport: "icloud.and.arrow.down"
    case .contentMigration: "arrow.left.arrow.right"
    case .siteImport: "globe.badge.chevron.backward"
    case .knowledgeImport: "books.vertical"
    case .imagePrivacySanitization: "hand.raised"
    case .imageJPEGOptimization: "photo.badge.checkmark"
    case .imageWebPConversion: "arrow.triangle.2.circlepath"
    case .imageSVGOptimization: "wand.and.stars"
    case .imageResize: "arrow.down.right.and.arrow.up.left"
    case .imageCoverCrop: "crop"
    case .workspaceBackupCreated: "externaldrive.badge.timemachine"
    case .workspaceRestorePrepared: "arrow.counterclockwise.circle"
    case .workspaceRestoreCompleted: "checkmark.arrow.trianglehead.counterclockwise"
    }
  }

  private func releaseEntry(
    _ record: ReleaseRecord,
    profileNames: [UUID: String],
    draftTitles: [UUID: String]
  ) -> WorkbenchOperationLogEntry {
    let requiresRemoteRecovery =
      record.kind == .remotePublishFailure
      && record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
    let targetLabel = targetLabel(
      draftID: record.draftID,
      draftTitle: record.draftTitle,
      profileID: record.siteProfileID,
      siteName: record.siteName,
      draftTitles: draftTitles,
      profileNames: profileNames
    )
    return WorkbenchOperationLogEntry(
      sourceReference: .init(kind: .releaseRecord, id: record.id),
      category: .publishing,
      outcome: requiresRemoteRecovery
        ? .partial
        : (record.kind == .remotePublishFailure ? .failed : .succeeded),
      actor: .user,
      title: CoreL10n.text("发布活动"),
      summary: requiresRemoteRecovery
        ? CoreL10n.text("远端发布部分完成后中断；需要确认远端 commit、Review 或回滚方案。")
        : CoreL10n.format(
          "发布类型：%@ · 文件：%lld",
          record.kind.displayName,
          Int64(record.changedPaths.count)
        ),
      profileID: record.siteProfileID,
      draftID: record.draftID,
      targetLabel: targetLabel,
      occurredAt: record.createdAt,
      systemImage: record.kind.systemImage
    )
  }

  private func maintenanceEntry(
    _ record: MaintenanceOperationRecord,
    profileNames: [UUID: String],
    draftTitles: [UUID: String]
  ) -> WorkbenchOperationLogEntry {
    WorkbenchOperationLogEntry(
      sourceReference: .init(kind: .maintenanceOperation, id: record.id),
      category: .maintenance,
      outcome: .recorded,
      actor: .user,
      title: CoreL10n.text("维护活动"),
      summary: CoreL10n.format("维护类型：%@", record.actionKind.displayName),
      profileID: record.profileID,
      draftID: record.draftID,
      targetLabel: targetLabel(
        draftID: record.draftID,
        profileID: record.profileID,
        draftTitles: draftTitles,
        profileNames: profileNames
      ),
      occurredAt: record.createdAt,
      systemImage: record.actionKind.systemImage
    )
  }

  private func automationEntry(
    _ record: WorkbenchAutomationRunRecord,
    profileNames: [UUID: String],
    draftTitles: [UUID: String],
    draftProfileIDs: [UUID: UUID]
  ) -> WorkbenchOperationLogEntry {
    let draftID = record.steps.compactMap(\.targetDraftID).first
    let profileID = draftID.flatMap { draftProfileIDs[$0] }
    let counts = automationCounts(record.steps)
    return WorkbenchOperationLogEntry(
      sourceReference: .init(kind: .automationRun, id: record.id),
      category: .automation,
      outcome: automationOutcome(for: record.steps),
      actor: .automation,
      title: CoreL10n.text("自动化活动"),
      summary: CoreL10n.format(
        "自动化步骤：%lld 成功，%lld 失败，%lld 已取消，%lld 待处理",
        Int64(counts.succeeded),
        Int64(counts.failed),
        Int64(counts.cancelled),
        Int64(counts.pending)
      ),
      profileID: profileID,
      draftID: draftID,
      targetLabel: targetLabel(
        draftID: draftID,
        profileID: profileID,
        draftTitles: draftTitles,
        profileNames: profileNames
      ),
      occurredAt: record.completedAt
    )
  }

  private func aiMetadataEntry(
    _ record: AIPublishingMetadataApplicationRecord,
    profileNames: [UUID: String],
    draftTitles: [UUID: String]
  ) -> WorkbenchOperationLogEntry {
    WorkbenchOperationLogEntry(
      sourceReference: .init(kind: .aiMetadataApplication, id: record.id),
      category: .ai,
      outcome: .succeeded,
      actor: .automation,
      title: CoreL10n.text("AI 元数据应用"),
      summary: CoreL10n.format("AI 已应用 %lld 项元数据", Int64(record.fields.count)),
      profileID: record.siteProfileID,
      draftID: record.draftID,
      targetLabel: targetLabel(
        draftID: record.draftID,
        draftTitle: record.draftTitle,
        profileID: record.siteProfileID,
        draftTitles: draftTitles,
        profileNames: profileNames
      ),
      occurredAt: record.createdAt
    )
  }

  private func deploymentEntry(
    _ snapshot: DeploymentStatusSnapshot,
    releaseRecordsByID: [UUID: ReleaseRecord],
    profileNames: [UUID: String],
    draftTitles: [UUID: String]
  ) -> WorkbenchOperationLogEntry? {
    let outcome: WorkbenchOperationLogOutcome
    switch snapshot.level {
    case .success:
      outcome = .observed
    case .failed:
      outcome = .failed
    case .running, .unknown:
      return nil
    }

    let releaseRecord = snapshot.releaseRecordID.flatMap { releaseRecordsByID[$0] }
    let draftID = releaseRecord?.draftID
    return WorkbenchOperationLogEntry(
      sourceReference: .init(kind: .deploymentStatus, id: snapshot.id),
      category: .deployment,
      outcome: outcome,
      actor: .background,
      title: CoreL10n.text("部署状态"),
      summary: CoreL10n.format("部署提供商：%@", snapshot.provider.displayName),
      profileID: snapshot.profileID,
      draftID: draftID,
      targetLabel: targetLabel(
        draftID: draftID,
        draftTitle: releaseRecord?.draftTitle,
        profileID: snapshot.profileID,
        siteName: releaseRecord?.siteName,
        draftTitles: draftTitles,
        profileNames: profileNames
      ),
      occurredAt: snapshot.checkedAt,
      systemImage: snapshot.provider.systemImage
    )
  }

  private func automationOutcome(
    for steps: [WorkbenchAutomationStepRecord]
  ) -> WorkbenchOperationLogOutcome {
    let hasPendingStep = steps.contains { !$0.status.isTerminal }
    let terminalStatuses = steps.map(\.status).filter(\.isTerminal)
    guard !terminalStatuses.isEmpty else { return .recorded }

    let succeeded = terminalStatuses.filter { $0 == .succeeded }.count
    let failed = terminalStatuses.filter { $0 == .failed }.count
    let cancelled = terminalStatuses.filter { $0 == .cancelled }.count

    if hasPendingStep { return .partial }
    if succeeded > 0, failed > 0 || cancelled > 0 { return .partial }
    if failed > 0 { return .failed }
    if cancelled > 0 { return .cancelled }
    return .succeeded
  }

  private func automationCounts(
    _ steps: [WorkbenchAutomationStepRecord]
  ) -> (succeeded: Int, failed: Int, cancelled: Int, pending: Int) {
    (
      steps.filter { $0.status == .succeeded }.count,
      steps.filter { $0.status == .failed }.count,
      steps.filter { $0.status == .cancelled }.count,
      steps.filter { !$0.status.isTerminal }.count
    )
  }

  private func targetLabel(
    draftID: UUID?,
    draftTitle: String? = nil,
    profileID: UUID?,
    siteName: String? = nil,
    draftTitles: [UUID: String],
    profileNames: [UUID: String]
  ) -> String? {
    if let draftTitle, !draftTitle.isEmpty { return draftTitle }
    if let draftID, let draftTitle = draftTitles[draftID], !draftTitle.isEmpty { return draftTitle }
    if let siteName, !siteName.isEmpty { return siteName }
    if let profileID, let profileName = profileNames[profileID], !profileName.isEmpty {
      return profileName
    }
    return nil
  }
}
