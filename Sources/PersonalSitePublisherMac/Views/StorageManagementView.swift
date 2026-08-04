import AppKit
import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct StorageManagementView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var rssStore: RSSReaderStore
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator

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
  @State private var workspaceBackupPreview: WorkspaceBackupPreview?
  @State private var operationMessage: String?
  @State private var operationError: String?

  var body: some View {
    Form {
      currentLocationSection
      knowledgeSection
      rssSection
      backupSection
      relocationSection
    }
    .formStyle(.grouped)
    .padding(WorkbenchSpacing.content)
    .task(id: coordinator.dataRootPath) {
      await refreshUsage()
    }
    .sheet(item: $workspaceBackupPreview) { preview in
      WorkspaceBackupRestorePreviewView(store: store, preview: preview)
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
        Label(usageError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .textSelection(.enabled)
      }
      if let operationMessage {
        Text(operationMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let operationError {
        Label(operationError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
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

  private var knowledgeSection: some View {
    Section(String(localized: "资料库清理")) {
      LabeledContent(
        String(localized: "资料"),
        value: store.knowledge.documents.count.formatted()
      )
      LabeledContent(
        String(localized: "回收站"),
        value: store.knowledge.recycledDocuments.count.formatted()
      )
      Text("只清空已经移入资料库回收站的内容；仍在资料库中的正文和原始外部文件不会被删除。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "清空资料库回收站"), systemImage: "trash", role: .destructive) {
        isKnowledgeCleanupConfirmationPresented = true
      }
      .disabled(
        store.knowledge.recycledDocuments.isEmpty
          || store.knowledge.isBusy
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
      LabeledContent(
        String(localized: "本地图片"),
        value: rssStore.mediaAssets.count.formatted()
      )
      Picker(String(localized: "清理范围"), selection: $retentionDays) {
        ForEach([30, 60, 90, 180, 365, 730], id: \.self) { days in
          Text("\(days) 天前").tag(days)
        }
      }
      Text("只清理超过期限、已读、未加入稍后阅读且没有高亮的文章，并一并移除这些文章的本地图片。")
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
    Section(String(localized: "备份与导入")) {
      Text("完整备份包含工作台、资料库、RSS、附件和发布记录；导入前会先校验并显示内容预览，API Key 不会写入备份。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(String(localized: "创建完整备份…"), systemImage: "externaldrive.badge.plus") {
          createWorkspaceBackup()
        }
        Button(String(localized: "从备份导入…"), systemImage: "square.and.arrow.down") {
          chooseWorkspaceBackupForRestore()
        }
      }
      .disabled(isRelocating)
    }
  }

  private var relocationSection: some View {
    Section(String(localized: "更改存储位置")) {
      Text("选择本机或外置硬盘中的目标位置。RepoPress 会新建数据文件夹，复制并校验全部资料库、RSS 和附件后再切换；原文件夹会保留。")
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
      format: String(localized: "RepoPress 将在 %@ 中创建新的数据文件夹。复制并校验成功后应用会退出，原文件夹不会删除。"),
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
      let summary = await store.knowledge.emptyRecycleBin()
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
      operationMessage = summary.removedArticleCount == 0
        ? String(localized: "没有符合条件的 RSS 历史文章。")
        : String(
          format: String(localized: "RSS 清理完成：删除 %@ 篇文章和 %@ 个本地图片。"),
          summary.removedArticleCount.formatted(),
          summary.removedMediaAssetCount.formatted()
        )
    }
    Task { await refreshUsage() }
  }

  private func createWorkspaceBackup() {
    guard let destinationURL = WorkspaceBackupSelectionPanel.chooseBackupDestination() else { return }
    Task {
      let preview = await store.createWorkspaceBackup(at: destinationURL)
      if let preview {
        operationMessage = String(
          format: String(localized: "完整备份已创建：%@（%@）。"),
          preview.backupURL.lastPathComponent,
          formattedByteCount(preview.totalByteCount)
        )
      } else {
        operationMessage = store.lastSaveStatus
      }
      await refreshUsage()
    }
  }

  private func chooseWorkspaceBackupForRestore() {
    guard let backupURL = WorkspaceBackupSelectionPanel.chooseBackupForRestore() else { return }
    Task {
      workspaceBackupPreview = await store.workspaceBackupPreview(from: backupURL)
      if workspaceBackupPreview == nil {
        operationMessage = store.lastSaveStatus
      }
    }
  }

  private func chooseRelocationDestination() {
    Task {
      guard let parentURL = await WorkbenchDataRootSelectionPanel.chooseDestinationParent(
        forMigration: true
      ) else { return }
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
