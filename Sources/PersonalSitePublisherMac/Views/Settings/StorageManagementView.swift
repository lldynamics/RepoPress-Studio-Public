import AppKit
import PublishingBackupCore
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

enum StorageManagementPresentation {
  case standalone
  case embedded
}

enum StorageManagementScope {
  case all
  case storageAndCleanup
  case backupAndRestore
}

@MainActor
struct StorageManagementView: View {
  @ObservedObject private var dataManagement: WorkbenchDataManagementFeatureFacade
  @ObservedObject var rssStore: RSSReaderStore
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  @ObservedObject var backupScheduler: WorkspaceBackupScheduler
  let presentation: StorageManagementPresentation
  let scope: StorageManagementScope

  @AppStorage(RSSReaderStore.retentionDaysDefaultsKey)
  private var retentionDays = RSSReaderStore.defaultRetentionDays
  @State private var usageSnapshot: WorkbenchStorageUsageSnapshot?
  @State private var usageError: String?
  @State private var isLoadingUsage = false
  @State private var isCleaningKnowledge = false
  @State private var isKnowledgeCleanupConfirmationPresented = false
  @State private var isRSSCleanupConfirmationPresented = false
  @State private var pendingRelocationParentURL: URL?
  @State private var isRelocationConfirmationPresented = false
  @State private var isRelocating = false
  @State private var knowledgeBackupPreview: KnowledgeLibraryBackupPreview?
  @State private var operationMessage: String?
  @State private var operationError: String?
  @State private var isPerformingBackupOperation = false
  @State private var selectiveRestorePreview: WorkspaceBackupSelectiveRestorePreview?
  @State private var isSelectiveRestorePreviewPresented = false
  @State private var selectiveRestoreStagingDirectory: URL?

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    coordinator: WorkbenchLaunchCoordinator,
    backupScheduler: WorkspaceBackupScheduler,
    presentation: StorageManagementPresentation = .standalone,
    scope: StorageManagementScope = .all
  ) {
    _dataManagement = ObservedObject(wrappedValue: store.dataManagement)
    self.rssStore = rssStore
    self.coordinator = coordinator
    self.backupScheduler = backupScheduler
    self.presentation = presentation
    self.scope = scope
  }

  var body: some View {
    Group {
      if presentation == .embedded {
        storageSections
      } else {
        Form {
          storageSections
        }
        .formStyle(.grouped)
        .padding(WorkbenchSpacing.content)
      }
    }
    .task(id: coordinator.dataRootPath) {
      await refreshUsage()
      await backupScheduler.refreshRecentBackups()
    }
    .sheet(item: $knowledgeBackupPreview) { preview in
      KnowledgeLibraryRestorePreviewView(knowledge: dataManagement.knowledge, preview: preview)
    }
    .sheet(isPresented: $isSelectiveRestorePreviewPresented) {
      if let selectiveRestorePreview {
        SelectiveWorkspaceBackupPreviewSheet(
          preview: selectiveRestorePreview,
          dataManagement: dataManagement
        ) { categories in
          try await prepareSelectiveRestore(
            categories: categories, from: selectiveRestorePreview.backupPreview.backupURL)
        }
      }
    }
    .onChange(of: isSelectiveRestorePreviewPresented) { _, presented in
      guard !presented else { return }
      cleanupRestoreStaging()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      backupScheduler.refreshCloudUploadStatus()
    }
    .alert(
      String(localized: "清空资料库回收站？"),
      isPresented: $isKnowledgeCleanupConfirmationPresented
    ) {
      Button(String(localized: "永久删除"), role: .destructive) {
        cleanKnowledgeRecycleBin()
      }
      Button(String(localized: "取消"), role: .cancel) {}
    } message: {
      Text("回收站中的资料、检索索引和应用内保存的本地副本将被永久删除。此操作无法撤销。")
    }
    .alert(
      String(localized: "清理 RSS 历史文章？"),
      isPresented: $isRSSCleanupConfirmationPresented
    ) {
      Button(String(localized: "立即清理"), role: .destructive) {
        cleanRSSHistory()
      }
      Button(String(localized: "取消"), role: .cancel) {}
    } message: {
      Text(
        String(
          format: String(localized: "将清理 %@ 天前的已读文章；未读、稍后阅读和带高亮的文章会保留。"),
          retentionDays.formatted()
        )
      )
    }
    .alert(
      String(localized: "复制并切换存储位置？"),
      isPresented: $isRelocationConfirmationPresented
    ) {
      Button(String(localized: "复制并切换")) {
        relocateDataRoot()
      }
      Button(String(localized: "取消"), role: .cancel) {
        pendingRelocationParentURL = nil
      }
    } message: {
      Text(relocationConfirmationMessage)
    }
    .accessibilityIdentifier("storage-management-settings")
  }

  @ViewBuilder
  private var storageSections: some View {
    switch scope {
    case .all:
      currentLocationSection
      knowledgeSection
      rssSection
      backupSection
      relocationSection
    case .storageAndCleanup:
      currentLocationSection
      knowledgeSection
      relocationSection
    case .backupAndRestore:
      backupSection
    }
  }

  private var currentLocationSection: some View {
    Section(String(localized: "当前存储位置")) {
      if let rootURL {
        LabeledContent(String(localized: "文件夹")) {
          Text(rootURL.path)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        if let usageSnapshot {
          LabeledContent(
            String(localized: "总占用"),
            value: formattedByteCount(usageSnapshot.totalByteCount)
          )
          LabeledContent(
            String(localized: "本地文件"),
            value: usageSnapshot.regularFileCount.formatted()
          )
          storageBreakdown(snapshot: usageSnapshot)
        } else if isLoadingUsage {
          ProgressView(String(localized: "正在计算存储空间…"))
            .controlSize(.small)
        }

        HStack {
          Button(String(localized: "在 Finder 中显示"), systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
          }
          Button(String(localized: "重新计算"), systemImage: "arrow.clockwise") {
            Task { await refreshUsage() }
          }
          .disabled(isLoadingUsage || isRelocating)
        }
      } else {
        Text("当前数据文件夹尚未准备完成。")
          .foregroundStyle(.secondary)
      }

      if let usageError {
        AccessibleStatusMessage(message: usageError, severity: .error)
          .textSelection(.enabled)
      }
      if let operationMessage {
        AccessibleStatusMessage(
          message: operationMessage,
          severity: .success,
          announcesNonUrgentStatus: true
        )
        .textSelection(.enabled)
      }
      if let operationError {
        AccessibleStatusMessage(message: operationError, severity: .error)
          .textSelection(.enabled)
      }
      if let dataRootMessage = coordinator.dataRootMessage {
        Text(dataRootMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder
  private func storageBreakdown(snapshot: WorkbenchStorageUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      storageVisualCapacityBar(snapshot: snapshot)
      storageLegend(snapshot: snapshot)
    }
    .padding(.vertical, 4)

    LabeledContent(
      String(localized: "资料库"),
      value: formattedByteCount(snapshot.knowledgeLibraryByteCount)
    )
    LabeledContent(
      String(localized: "RSS"),
      value: formattedByteCount(snapshot.rssReaderByteCount)
    )
    LabeledContent(
      String(localized: "应用内附件"),
      value: formattedByteCount(snapshot.managedAttachmentsByteCount)
    )
    LabeledContent(
      String(localized: "自动备份"),
      value: formattedByteCount(snapshot.automaticBackupsByteCount)
    )
    LabeledContent(
      String(localized: "其他工作台数据"),
      value: formattedByteCount(snapshot.otherByteCount)
    )
  }

  private func storageVisualCapacityBar(snapshot: WorkbenchStorageUsageSnapshot) -> some View {
    let total = max(1, Double(snapshot.totalByteCount))
    let knowledgeFrac = Double(snapshot.knowledgeLibraryByteCount) / total
    let rssFrac = Double(snapshot.rssReaderByteCount) / total
    let attachFrac = Double(snapshot.managedAttachmentsByteCount) / total
    let backupFrac = Double(snapshot.automaticBackupsByteCount) / total
    let otherFrac = Double(snapshot.otherByteCount) / total

    return GeometryReader { geo in
      HStack(spacing: 2) {
        if knowledgeFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.blue)
            .frame(width: max(4, geo.size.width * CGFloat(knowledgeFrac)))
        }
        if rssFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.orange)
            .frame(width: max(4, geo.size.width * CGFloat(rssFrac)))
        }
        if attachFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.purple)
            .frame(width: max(4, geo.size.width * CGFloat(attachFrac)))
        }
        if backupFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.green)
            .frame(width: max(4, geo.size.width * CGFloat(backupFrac)))
        }
        if otherFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.5))
            .frame(width: max(4, geo.size.width * CGFloat(otherFrac)))
        }
      }
    }
    .frame(height: 10)
    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(String(localized: "存储空间占用比例图"))
  }

  private func storageLegend(snapshot: WorkbenchStorageUsageSnapshot) -> some View {
    HStack(spacing: 12) {
      legendItem(title: String(localized: "资料库"), color: .blue)
      legendItem(title: String(localized: "RSS"), color: .orange)
      legendItem(title: String(localized: "附件"), color: .purple)
      legendItem(title: String(localized: "备份"), color: .green)
      legendItem(title: String(localized: "其他"), color: .secondary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func legendItem(title: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(title)
    }
  }

  private var knowledgeSection: some View {
    Section(String(localized: "资料库清理")) {
      LabeledContent(
        String(localized: "资料"),
        value: dataManagement.knowledgeDocumentCount.formatted()
      )
      LabeledContent(
        String(localized: "回收站"),
        value: dataManagement.knowledgeRecycledDocumentCount.formatted()
      )
      Text("只清空已经移入资料库回收站的内容；仍在资料库中的正文和原始外部文件不会被删除。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "清空资料库回收站"), systemImage: "trash", role: .destructive) {
        isKnowledgeCleanupConfirmationPresented = true
      }
      .disabled(
        dataManagement.knowledgeRecycledDocumentCount == 0
          || dataManagement.isKnowledgeBusy
          || isCleaningKnowledge
          || isRelocating
      )
    }
  }

  private var rssSection: some View {
    Section(String(localized: "RSS 清理")) {
      LabeledContent(
        String(localized: "订阅"),
        value: rssStore.feeds.count.formatted()
      )
      LabeledContent(
        String(localized: "文章"),
        value: rssStore.articleHeaders.count.formatted()
      )
      Picker(String(localized: "清理范围"), selection: $retentionDays) {
        ForEach([30, 60, 90, 180, 365, 730], id: \.self) { days in
          Text("\(days) 天前").tag(days)
        }
      }
      Text("只清理超过期限、已读、未加入稍后阅读且没有高亮的文章。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "清理 RSS 历史文章"), systemImage: "trash", role: .destructive) {
        isRSSCleanupConfirmationPresented = true
      }
      .disabled(rssStore.isRefreshing || isRelocating)
    }
  }

  private var backupSection: some View {
    Section(String(localized: "备份与恢复")) {
      Text("备份包含草稿、历史版本、配置、资料库（含笔记）、RSS、附件、发布记录和 AI 对话；不包含 API Key。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(String(localized: "立即备份…"), systemImage: "externaldrive.badge.plus") {
          createWorkspaceBackup()
        }
        .accessibilityIdentifier("workspace-backup-now")
        Button(String(localized: "恢复…"), systemImage: "arrow.counterclockwise") {
          chooseBackupForRestore()
        }
        .accessibilityIdentifier("workspace-backup-restore")
      }
      .disabled(backupControlsDisabled)

      Text("创建后自动校验；恢复前先预览内容并确认替换范围。旧版资料库备份也可从这里恢复。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if isPerformingBackupOperation {
        ProgressView(String(localized: "正在处理并校验备份…"))
          .controlSize(.small)
      }
      if let operationMessage {
        AccessibleStatusMessage(message: operationMessage, severity: .success)
          .textSelection(.enabled)
      }
      if let operationError {
        AccessibleStatusMessage(message: operationError, severity: .error)
          .textSelection(.enabled)
      }

      automaticBackupSection
    }
  }

  private var backupControlsDisabled: Bool {
    isRelocating || isPerformingBackupOperation || backupScheduler.isRunning
      || dataManagement.isKnowledgeBusy
  }

  private var automaticBackupSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      Toggle(
        String(localized: "自动备份"),
        isOn: Binding(
          get: { backupScheduler.settings.frequency != .off },
          set: { backupScheduler.setAutomaticBackupEnabled($0) }
        )
      )
      .accessibilityIdentifier("workspace-automatic-backup")
      .disabled(backupControlsDisabled)

      Text("开启后每天检查一次并备份完整工作区，内容未变化时跳过。应用需要处于运行状态。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if backupScheduler.settings.frequency != .off,
        backupScheduler.settings.frequency != .daily
          || backupScheduler.selectedCategories != Set(WorkspaceBackupCategory.allCases)
      {
        Text(legacyAutomaticBackupDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      LabeledContent(String(localized: "保存位置")) {
        HStack {
          Text(backupScheduler.destinationFolderLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(backupScheduler.destinationFolderLabel)
          Button(String(localized: "更改…")) {
            chooseAutomaticBackupDirectory()
          }
          .accessibilityLabel(String(localized: "更改自动备份保存位置"))
          .disabled(backupControlsDisabled)
        }
      }
      Text(
        backupScheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk
          ? String(localized: "当前保存位置保留全部自动快照，请留意磁盘空间。")
          : String(localized: "自动快照按最多 12 份、90 天和 4 GiB 保留，并始终保留最近的有效备份。")
      )
      .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("可选择本机、外置磁盘或云盘文件夹。云盘是否完成上传，以文件提供器的状态为准。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let lastBackupAt = backupScheduler.settings.lastBackupAt {
        LabeledContent(
          String(localized: "最近成功备份"),
          value: lastBackupAt.formatted(date: .abbreviated, time: .shortened)
        )
      }
      LabeledContent(String(localized: "备份副本状态")) {
        Text(cloudUploadStatusText(backupScheduler.cloudUploadStatus))
          .font(.caption)
          .foregroundStyle(cloudUploadStatusColor(backupScheduler.cloudUploadStatus))
          .fixedSize(horizontal: false, vertical: true)
      }
      if backupScheduler.isRunning {
        ProgressView(String(localized: "正在创建并校验自动备份…"))
          .controlSize(.small)
      }
      if let statusMessage = backupScheduler.statusMessage, !statusMessage.isEmpty {
        AccessibleStatusMessage(
          message: statusMessage,
          severity: backupSchedulerStatusSeverity,
          announcesNonUrgentStatus: backupScheduler.statusLevel == .info
            || backupScheduler.statusLevel == .success
        )
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      if backupScheduler.invalidRecentBackupCount > 0 {
        AccessibleStatusMessage(
          message: String(
            localized: "发现 \(backupScheduler.invalidRecentBackupCount) 个自动备份校验失败，请重新备份或检查保存位置。"),
          severity: .warning
        )
      }
      if backupScheduler.statusLevel != .error,
        let lastError = backupScheduler.settings.lastError, !lastError.isEmpty
      {
        AccessibleStatusMessage(message: lastError, severity: .error)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var legacyAutomaticBackupDescription: String {
    let frequency =
      backupScheduler.settings.frequency == .weekly
      ? String(localized: "每周") : String(localized: "每天")
    let categories = WorkspaceBackupCategory.allCases
      .filter { backupScheduler.selectedCategories.contains($0) }
      .map { category in
        switch category {
        case .workbench: String(localized: "草稿与附件")
        case .knowledgeLibrary: String(localized: "资料库")
        case .rssReader: String(localized: "RSS 阅读器")
        case .operationHistory: String(localized: "操作记录")
        }
      }
      .joined(separator: "、")
    return String(localized: "现有计划保持不变：\(frequency)，\(categories)。关闭后重新开启将改为每天完整备份。")
  }

  private func cleanupRestoreStaging() {
    guard let stagingDirectory = selectiveRestoreStagingDirectory else { return }
    try? FileManager.default.removeItem(at: stagingDirectory)
    selectiveRestoreStagingDirectory = nil
  }

  private func prepareSelectiveRestore(
    categories: Set<WorkspaceBackupCategory>, from backupURL: URL
  ) async throws {
    _ = try await dataManagement.prepareSelectiveWorkspaceBackupRestore(
      from: backupURL, categories: categories
    )
    cleanupRestoreStaging()
  }

  private func cloudUploadStatusText(_ status: WorkspaceBackupCloudUploadStatus) -> String {
    switch status {
    case .noBackup: return String(localized: "尚无已完成的备份")
    case .backupUnavailable: return String(localized: "备份暂不可访问；无法确认副本状态")
    case .localCopyComplete: return String(localized: "本地副本已完成")
    case .iCloudFileUnrecognized: return String(localized: "本机副本已完成；尚未识别为 iCloud 云端文件")
    case .waitingForUpload: return String(localized: "本机副本已完成；等待 iCloud 上传确认")
    case .uploadConfirmed: return String(localized: "本机副本已完成；iCloud 已确认上传")
    case .uploadFailed(let message): return String(localized: "本机副本已完成；iCloud 上传失败：\(message)")
    case .manifestCorrupt: return String(localized: "备份清单损坏；请重新创建备份")
    }
  }

  private func cloudUploadStatusColor(_ status: WorkspaceBackupCloudUploadStatus) -> Color {
    switch status {
    case .noBackup: return .secondary
    case .backupUnavailable: return WorkbenchTheme.warning
    case .localCopyComplete, .uploadConfirmed: return WorkbenchTheme.success
    case .uploadFailed, .manifestCorrupt: return WorkbenchTheme.risk
    case .iCloudFileUnrecognized, .waitingForUpload: return WorkbenchTheme.warning
    }
  }

  private var relocationSection: some View {
    Section(String(localized: "更改存储位置")) {
      Text("选择本机或外置硬盘中的目标位置。RepoPress Studio 会新建数据文件夹，复制并校验全部资料库、RSS 和附件后再切换；原文件夹会保留。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "复制到新位置并切换…"), systemImage: "externaldrive.badge.timemachine") {
        chooseRelocationDestination()
      }
      .disabled(isRelocating || rootURL == nil)
      if isRelocating {
        ProgressView(String(localized: "正在复制并校验，请勿断开硬盘…"))
          .controlSize(.small)
      } else {
        Text("切换成功后应用会退出。重新打开即可使用新位置；确认无误前请不要删除原文件夹。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var rootURL: URL? {
    coordinator.dataRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private var relocationConfirmationMessage: String {
    guard let parentURL = pendingRelocationParentURL else {
      return String(localized: "请选择新的存储位置。")
    }
    return String(
      format: String(localized: "RepoPress Studio 将在 %@ 中创建新的数据文件夹。复制并校验成功后应用会退出，原文件夹不会删除。"),
      parentURL.path
    )
  }

  private func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
  }

  private func refreshUsage() async {
    guard let rootURL else { return }
    isLoadingUsage = true
    usageError = nil
    do {
      usageSnapshot = try await Task.detached(priority: .utility) {
        try WorkbenchStorageUsageService().snapshot(
          for: WorkbenchDataRootLayout(rootURL: rootURL)
        )
      }.value
    } catch {
      usageError = error.localizedDescription
    }
    isLoadingUsage = false
  }

  private func cleanKnowledgeRecycleBin() {
    isCleaningKnowledge = true
    operationMessage = nil
    operationError = nil
    Task {
      let summary = await dataManagement.knowledge.emptyRecycleBin()
      if summary.failedDocumentCount > 0 || summary.failedStoredFileCount > 0 {
        operationError = String(
          format: String(localized: "资料库仅完成部分清理：删除 %@ 条资料，%@ 条资料和 %@ 个本地文件未能移除。"),
          summary.removedDocumentCount.formatted(),
          summary.failedDocumentCount.formatted(),
          summary.failedStoredFileCount.formatted()
        )
      } else {
        operationMessage = String(
          format: String(localized: "资料库清理完成：永久删除 %@ 条资料。"),
          summary.removedDocumentCount.formatted()
        )
      }
      isCleaningKnowledge = false
      await refreshUsage()
    }
  }

  private func cleanRSSHistory() {
    operationMessage = nil
    operationError = nil
    let summary = rssStore.pruneReadArticles(olderThanDays: retentionDays)
    if let lastError = rssStore.lastError, !lastError.isEmpty {
      operationError = lastError
    } else {
      operationMessage =
        summary.removedArticleCount == 0
        ? String(localized: "没有符合条件的 RSS 历史文章。")
        : String(
          format: String(localized: "RSS 清理完成：删除 %@ 篇文章。"),
          summary.removedArticleCount.formatted()
        )
    }
    Task { await refreshUsage() }
  }

  private func createWorkspaceBackup() {
    guard !backupControlsDisabled else { return }
    isPerformingBackupOperation = true
    Task { @MainActor in
      defer { isPerformingBackupOperation = false }
      guard
        let destinationURL = await WorkspaceBackupSelectionPanel.chooseBackupDestination(
          directoryURL: backupScheduler.destinationFolderURL
        )
      else { return }
      operationMessage = nil
      operationError = nil
      let preview = await dataManagement.createWorkspaceBackup(at: destinationURL)
      if let preview {
        operationMessage = String(
          format: String(localized: "完整备份已创建：%@（%@）。"),
          preview.backupURL.lastPathComponent,
          formattedByteCount(preview.totalByteCount)
        )
      } else {
        operationError = dataManagement.lastSaveStatus
      }
    }
  }

  private func chooseBackupForRestore() {
    guard !backupControlsDisabled else { return }
    isPerformingBackupOperation = true
    Task { @MainActor in
      defer { isPerformingBackupOperation = false }
      guard
        let backupURL = await WorkspaceBackupSelectionPanel.chooseBackupForRestore(
          directoryURL: backupScheduler.destinationFolderURL, includesLibraryBackups: true
        )
      else { return }
      operationMessage = nil
      operationError = nil
      if backupURL.pathExtension.lowercased() == "pslibrarybackup" {
        knowledgeBackupPreview = await dataManagement.knowledge.backupPreview(from: backupURL)
        if knowledgeBackupPreview == nil {
          operationError = dataManagement.knowledge.statusMessage
        }
        return
      }
      do {
        let values = try backupURL.resourceValues(forKeys: [.isUbiquitousItemKey])
        let inspectionURL: URL
        if values.isUbiquitousItem == true {
          inspectionURL = try await iCloudWorkspaceBackupStore().downloadToLocalStaging(backupURL)
          selectiveRestoreStagingDirectory = inspectionURL.deletingLastPathComponent()
        } else {
          inspectionURL = backupURL
        }
        selectiveRestorePreview = try await dataManagement.workspaceBackupSelectiveRestorePreview(
          from: inspectionURL)
        isSelectiveRestorePreviewPresented = true
      } catch {
        cleanupRestoreStaging()
        operationError = String(localized: "备份校验失败：\(error.localizedDescription)")
      }
    }
  }

  private func chooseAutomaticBackupDirectory() {
    guard !backupControlsDisabled else { return }
    isPerformingBackupOperation = true
    Task { @MainActor in
      defer { isPerformingBackupOperation = false }
      guard let folderURL = await WorkspaceBackupSelectionPanel.chooseBackupDirectory() else {
        return
      }
      do {
        try backupScheduler.setDestinationFolder(folderURL)
        operationMessage = String(localized: "自动备份目录已更新。")
        operationError = nil
      } catch {
        operationError = String(
          format: String(localized: "自动备份目录不可用：%@"),
          error.localizedDescription
        )
      }
    }
  }

  private var backupSchedulerStatusSeverity: AccessibleStatusSeverity {
    switch backupScheduler.statusLevel {
    case .success:
      return .success
    case .warning:
      return .warning
    case .error:
      return .error
    case .info, .none:
      return .info
    }
  }

  private func chooseRelocationDestination() {
    Task {
      guard
        let parentURL = await WorkbenchDataRootSelectionPanel.chooseDestinationParent(
          forMigration: true
        )
      else { return }
      pendingRelocationParentURL = parentURL
      isRelocationConfirmationPresented = true
    }
  }

  private func relocateDataRoot() {
    guard let parentURL = pendingRelocationParentURL else { return }
    pendingRelocationParentURL = nil
    isRelocating = true
    operationMessage = nil
    Task {
      let result = await coordinator.relocateCurrentDataRoot(in: parentURL)
      guard let result else {
        isRelocating = false
        return
      }
      operationMessage = String(
        format: String(localized: "数据已复制到 %@，即将退出应用。"),
        result.destinationRootURL.path
      )
      NSApp.terminate(nil)
    }
  }
}
