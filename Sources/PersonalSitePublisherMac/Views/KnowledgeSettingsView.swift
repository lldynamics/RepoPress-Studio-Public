import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeAdvancedSettingsExpansionState: Equatable {
  var vectorSearch = false
  var smartCollections = false
  var backup = false
  var browserConnection = false

  var isFullyCollapsed: Bool {
    !vectorSearch && !smartCollections && !backup && !browserConnection
  }
}

struct KnowledgeSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var backupScheduler: WorkspaceBackupScheduler
  @ObservedObject var knowledge: KnowledgeStore
  let browserBridge: KnowledgeBrowserBridge?
  let onOpenLibrary: () -> Void

  @AppStorage("knowledgeSavedCollectionsV1") private var savedCollectionsJSON = "[]"
  @State private var expansionState = KnowledgeAdvancedSettingsExpansionState()
  @State private var isBrowserConnectionPresented = false
  @State private var restorePreview: KnowledgeLibraryBackupPreview?
  @State private var workspaceBackupPreview: WorkspaceBackupPreview?
  @State private var isWorkspaceOperationRunning = false
  @State private var workspaceOperationMessage: String?
  @State private var workspaceOperationIsError = false

  var body: some View {
    VStack(spacing: 0) {
      knowledgeSettingsHeader

      Divider()

      Form {
        Section(String(localized: "资料库概览")) {
          LabeledContent("资料", value: knowledge.documents.count.formatted())
          LabeledContent("文件夹", value: knowledge.folders.count.formatted())
          LabeledContent("已存智能集合", value: savedCollectionCount.formatted())
          if let statusMessage = knowledge.statusMessage, !statusMessage.isEmpty {
            Text(statusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        Section(String(localized: "高级功能")) {
          DisclosureGroup(isExpanded: $expansionState.vectorSearch) {
            vectorSearchSettings
          } label: {
            advancedGroupLabel(
              title: String(localized: "向量搜索"),
              detail: String(localized: "本地语义检索与索引维护"),
              systemImage: "point.3.connected.trianglepath.dotted"
            )
          }
          .accessibilityIdentifier("knowledge-settings-vector-search")

          DisclosureGroup(isExpanded: $expansionState.smartCollections) {
            smartCollectionSettings
          } label: {
            advancedGroupLabel(
              title: String(localized: "智能集合"),
              detail: String(localized: "作者、标签、来源与时间规则"),
              systemImage: "wand.and.stars"
            )
          }
          .accessibilityIdentifier("knowledge-settings-smart-collections")

          DisclosureGroup(isExpanded: $expansionState.backup) {
            backupSettings
          } label: {
            advancedGroupLabel(
              title: String(localized: "备份"),
              detail: String(localized: "完整性校验、恢复预览与安全回退"),
              systemImage: "externaldrive"
            )
          }
          .accessibilityIdentifier("knowledge-settings-backup")

          DisclosureGroup(isExpanded: $expansionState.browserConnection) {
            browserConnectionSettings
          } label: {
            advancedGroupLabel(
              title: String(localized: "浏览器连接"),
              detail: String(localized: "从 Safari、Chrome 或 Firefox 保存网页"),
              systemImage: "puzzlepiece.extension"
            )
          }
          .accessibilityIdentifier("knowledge-settings-browser-connection")
        }
      }
      .formStyle(.grouped)
      .padding(WorkbenchSpacing.content)
    }
    .sheet(item: $restorePreview) { preview in
      KnowledgeLibraryRestorePreviewView(knowledge: knowledge, preview: preview)
    }
    .sheet(item: $workspaceBackupPreview) { preview in
      WorkspaceBackupRestorePreviewView(store: store, preview: preview)
    }
    .sheet(isPresented: $isBrowserConnectionPresented) {
      if let browserBridge {
        BrowserExtensionConnectionView()
          .environmentObject(browserBridge)
      }
    }
    .onChange(of: expansionState.vectorSearch) { _, isExpanded in
      guard isExpanded, knowledge.healthSnapshot == nil, !knowledge.isLoadingHealth else { return }
      Task { await knowledge.refreshLibraryHealth() }
    }
    .task {
      await backupScheduler.refreshRecentBackups()
    }
    .accessibilityIdentifier("knowledge-settings")
  }

  private var knowledgeSettingsHeader: some View {
    HStack(spacing: WorkbenchSpacing.section) {
      Image(systemName: "books.vertical")
        .font(.title3.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.brand)
        .frame(width: 36, height: 36)
        .background(
          WorkbenchTheme.brand.opacity(WorkbenchOpacity.selectionBackground),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("资料库设置")
          .font(.workbenchPageTitle)
          .accessibilityAddTraits(.isHeader)
        Text("管理本地检索、智能集合、备份和浏览器连接。")
          .font(.workbenchPageSubtitle)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: WorkbenchSpacing.content)

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("关闭资料库设置")
      .accessibilityLabel("关闭资料库设置")
    }
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.vertical, WorkbenchSpacing.card)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var vectorSearchSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("向量在本机生成并保存，与全文搜索结合排序；不会为此上传整个资料库。")
        .font(.callout)
        .foregroundStyle(.secondary)

      if let health = knowledge.healthSnapshot {
        LabeledContent("检索片段", value: health.indexedChunkCount.formatted())
        LabeledContent("待修复向量", value: health.semanticRepairChunkCount.formatted())
      } else if knowledge.isLoadingHealth {
        ProgressView("正在检查本地向量索引…")
          .controlSize(.small)
      }

      HStack {
        Button("检查索引") {
          Task { await knowledge.refreshLibraryHealth() }
        }
        Button("重建全部向量") {
          Task { await knowledge.rebuildAllSemanticIndex() }
        }
        .disabled(knowledge.documents.isEmpty)
      }
      .disabled(knowledge.isBusy || knowledge.isLoadingHealth)
    }
    .padding(.leading, 22)
    .padding(.vertical, 8)
  }

  private var smartCollectionSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("智能集合根据作者、标签、来源、时间和检索权限自动更新，不会复制资料。")
        .font(.callout)
        .foregroundStyle(.secondary)
      LabeledContent("可用规则", value: knowledge.smartCollections.count.formatted())
      LabeledContent("已存组合", value: savedCollectionCount.formatted())
      Button {
        onOpenLibrary()
      } label: {
        Label("打开资料库管理集合", systemImage: "arrow.up.forward.app")
      }
    }
    .padding(.leading, 22)
    .padding(.vertical, 8)
  }

  private var backupSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("备份包含正文、网页归档、版本、标注和检索索引；恢复前会先校验并显示预览。")
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Button {
          createBackup()
        } label: {
          Label("创建完整备份…", systemImage: "externaldrive.badge.plus")
        }
        Button {
          chooseBackupForRestore()
        } label: {
          Label("从备份恢复…", systemImage: "arrow.counterclockwise")
        }
      }
      .disabled(knowledge.isBusy)

      Divider()

      Text("完整工作区备份")
        .font(.headline)
      Text("包含草稿、历史版本、站点配置、资料库、附件和发布记录；默认不包含 API Key。")
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Button {
          createWorkspaceBackup()
        } label: {
          Label(String(localized: "备份完整工作区…"), systemImage: "externaldrive.badge.plus")
        }
        Button {
          chooseWorkspaceBackupForRestore()
        } label: {
          Label(String(localized: "恢复完整工作区…"), systemImage: "arrow.counterclockwise")
        }
      }
      .disabled(knowledge.isBusy || isWorkspaceOperationRunning)

      if isWorkspaceOperationRunning {
        ProgressView("正在校验完整工作区备份…")
          .controlSize(.small)
      }
      if let workspaceOperationMessage {
        Label(
          workspaceOperationMessage,
          systemImage: workspaceOperationIsError ? "exclamationmark.triangle" : "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(workspaceOperationIsError ? WorkbenchTheme.warning : Color.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }

      automaticWorkspaceBackupSettings
    }
    .padding(.leading, 22)
    .padding(.vertical, 8)
  }

  private var browserConnectionSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let browserBridge {
        LabeledContent("连接状态") {
          Label(
            browserBridge.state.localizedDisplayName,
            systemImage: browserBridge.state == .ready ? "checkmark.circle.fill" : "circle.dotted"
          )
          .foregroundStyle(browserBridge.state == .ready ? WorkbenchTheme.success : Color.secondary)
        }
        Text("浏览器插件通过当前用户专属的本机连接保存网页，不向公网暴露资料库端口。")
          .font(.callout)
          .foregroundStyle(.secondary)
        Button {
          isBrowserConnectionPresented = true
        } label: {
          Label("打开浏览器连接设置…", systemImage: "puzzlepiece.extension")
        }
      } else {
        Text("浏览器连接尚未就绪，请重新打开设置。")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 22)
    .padding(.vertical, 8)
  }

  private var automaticWorkspaceBackupSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()

      Text("自动工作区备份")
        .font(.headline)
      Text("按每日或每周计划创建完整工作区备份；应用启动时会补做逾期备份，系统允许时也会在后台执行。每次创建后都会重新校验归档。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker(
        String(localized: "备份频率"),
        selection: Binding(
          get: { backupScheduler.settings.frequency },
          set: { backupScheduler.setFrequency($0) }
        )
      ) {
        ForEach(WorkspaceBackupFrequency.allCases, id: \.self) { frequency in
          Text(frequency.localizedDisplayNameKey).tag(frequency)
        }
      }

      LabeledContent(String(localized: "保存目录")) {
        Text(backupScheduler.destinationFolderLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button {
          chooseAutomaticBackupDirectory()
        } label: {
          Label(String(localized: "选择目录…"), systemImage: "folder")
        }
        Button(String(localized: "恢复默认目录")) {
          backupScheduler.resetDestinationFolder()
        }
        .disabled(backupScheduler.settings.destinationPath == nil)
      }

      HStack {
        Button {
          Task { await backupScheduler.runBackupNow() }
        } label: {
          Label(String(localized: "立即备份并校验"), systemImage: "checkmark.shield")
        }
        Button {
          Task { await backupScheduler.refreshRecentBackups() }
        } label: {
          Label(String(localized: "校验最近备份"), systemImage: "arrow.triangle.2.circlepath")
        }
      }
      .disabled(backupScheduler.isRunning)

      if backupScheduler.isRunning {
        ProgressView(String(localized: "正在创建并校验自动备份…"))
          .controlSize(.small)
      }
      if let statusMessage = backupScheduler.statusMessage, !statusMessage.isEmpty {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if backupScheduler.invalidRecentBackupCount > 0 {
        Label(
          String(
            format: String(
              localized: "%@ 个自动备份校验失败，已从一键恢复列表中隐藏；请检查备份目录或重新创建备份。"
            ),
            backupScheduler.invalidRecentBackupCount.formatted()
          ),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }
      if let lastBackupAt = backupScheduler.settings.lastBackupAt {
        LabeledContent(
          String(localized: "最近成功备份"),
          value: lastBackupAt.formatted(date: .abbreviated, time: .shortened)
        )
      }
      if let lastValidationAt = backupScheduler.settings.lastValidationAt {
        LabeledContent(
          String(localized: "最近校验"),
          value: lastValidationAt.formatted(date: .abbreviated, time: .shortened)
        )
      }
      if let lastError = backupScheduler.settings.lastError, !lastError.isEmpty {
        Label(lastError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !backupScheduler.recentBackups.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("最近自动备份")
            .font(.subheadline.weight(.semibold))
          ForEach(backupScheduler.recentBackups.prefix(5)) { preview in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.callout.weight(.medium))
                Text(preview.backupURL.lastPathComponent)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
                Text(compatibilitySummary(for: preview))
                  .font(.workbenchMetadata)
                  .foregroundStyle(
                    preview.compatibility.requiresConfirmation
                      ? WorkbenchTheme.warning
                      : WorkbenchTheme.neutral
                  )
              }
              Spacer(minLength: 8)
              Button(String(localized: "一键恢复")) {
                restoreAutomaticBackup(preview)
              }
              .accessibilityLabel(
                String(
                  format: String(localized: "恢复 %@ 创建的自动备份"),
                  preview.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
              )
            }
            .padding(9)
            .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
    .padding(.leading, 22)
    .padding(.vertical, 8)
  }

  private func advancedGroupLabel(
    title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }

  private var savedCollectionCount: Int {
    guard let data = savedCollectionsJSON.data(using: .utf8),
          let collections = try? JSONDecoder().decode([KnowledgeSavedCollection].self, from: data) else {
      return 0
    }
    return collections.count
  }

  private func createBackup() {
    guard let destinationURL = KnowledgeLibraryBackupSelectionPanel.chooseBackupDestination() else { return }
    Task { _ = await knowledge.createBackup(at: destinationURL) }
  }

  private func chooseBackupForRestore() {
    guard let backupURL = KnowledgeLibraryBackupSelectionPanel.chooseBackupForRestore() else { return }
    Task { restorePreview = await knowledge.backupPreview(from: backupURL) }
  }

  private func createWorkspaceBackup() {
    guard let destinationURL = WorkspaceBackupSelectionPanel.chooseBackupDestination() else { return }
    isWorkspaceOperationRunning = true
    workspaceOperationMessage = nil
    workspaceOperationIsError = false
    Task {
      let preview = await store.createWorkspaceBackup(at: destinationURL)
      if let preview {
        workspaceOperationMessage = String(
          format: String(localized: "完整工作区备份已创建：%@"),
          preview.backupURL.lastPathComponent
        )
      } else {
        workspaceOperationMessage = store.lastSaveStatus
        workspaceOperationIsError = true
      }
      isWorkspaceOperationRunning = false
    }
  }

  private func chooseWorkspaceBackupForRestore() {
    guard let backupURL = WorkspaceBackupSelectionPanel.chooseBackupForRestore() else { return }
    isWorkspaceOperationRunning = true
    workspaceOperationMessage = nil
    workspaceOperationIsError = false
    Task {
      workspaceBackupPreview = await store.workspaceBackupPreview(from: backupURL)
      if workspaceBackupPreview == nil {
        workspaceOperationMessage = store.lastSaveStatus
        workspaceOperationIsError = true
      }
      isWorkspaceOperationRunning = false
    }
  }

  private func chooseAutomaticBackupDirectory() {
    guard let folderURL = WorkspaceBackupSelectionPanel.chooseBackupDirectory() else { return }
    do {
      try backupScheduler.setDestinationFolder(folderURL)
    } catch {
      let message = String(
        format: String(localized: "自动备份目录不可用：%@"),
        error.localizedDescription
      )
      store.setLastSaveStatus(message)
      workspaceOperationMessage = message
      workspaceOperationIsError = true
    }
  }

  private func restoreAutomaticBackup(_ preview: WorkspaceBackupPreview) {
    Task {
      workspaceBackupPreview = await store.workspaceBackupPreview(from: preview.backupURL)
    }
  }

  private func compatibilitySummary(for preview: WorkspaceBackupPreview) -> String {
    switch preview.compatibility {
    case .compatible:
      return String(localized: "版本兼容，已校验")
    case .createdByOlderApplication:
      return String(localized: "来自较旧应用版本，恢复前会提示迁移")
    case .createdByNewerApplication:
      return String(localized: "来自较新应用版本，恢复前需确认")
    case .unknownApplicationVersion:
      return String(localized: "无法比较应用版本，恢复前需确认")
    }
  }
}
