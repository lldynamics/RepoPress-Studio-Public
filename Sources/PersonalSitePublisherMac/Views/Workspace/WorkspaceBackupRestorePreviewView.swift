import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceBackupRestorePreviewView: View {
  let preview: WorkspaceBackupPreview
  @ObservedObject var dataManagement: WorkbenchDataManagementFeatureFacade
  let stageWorkspaceBackupRestore: @MainActor (URL) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var isRestoring = false
  @State private var isCompatibilityConfirmationPresented = false
  @State private var isArticleSelectionPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "checkmark.shield.fill")
          .font(.system(size: 30))
          .foregroundStyle(WorkbenchTheme.success)
        VStack(alignment: .leading, spacing: 4) {
          Text("工作区备份完整性校验通过")
            .font(.title2.weight(.semibold))
          Text(preview.backupURL.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
        metadataRow(
          String(localized: "创建时间"),
          value: preview.createdAt.formatted(date: .abbreviated, time: .shortened)
        )
        metadataRow(String(localized: "应用版本"), value: preview.applicationVersion)
        metadataRow(String(localized: "归档格式"), value: "v\(preview.formatVersion)")
        metadataRow(String(localized: "站点配置"), value: preview.profileCount.formatted())
        metadataRow(String(localized: "草稿"), value: preview.draftCount.formatted())
        metadataRow(String(localized: "历史版本"), value: preview.draftVersionCount.formatted())
        metadataRow(String(localized: "发布记录"), value: preview.releaseRecordCount.formatted())
        metadataRow(String(localized: "归档文件"), value: preview.fileCount.formatted())
        metadataRow(
          String(localized: "备份大小"),
          value: ByteCountFormatter.string(fromByteCount: preview.totalByteCount, countStyle: .file)
        )
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("包含内容")
          .font(.headline)
        ForEach(preview.components, id: \.component) { component in
          Label {
            Text(componentSummary(component))
          } icon: {
            Image(systemName: systemImage(for: component.component))
          }
        }
      }

      Label {
        Text(apiKeyNotice)
      } icon: {
        Image(systemName: preview.includesAPIKeys ? "xmark.octagon.fill" : "lock.shield.fill")
          .foregroundStyle(preview.includesAPIKeys ? WorkbenchTheme.risk : WorkbenchTheme.success)
      }
      .padding(12)
      .background(
        (preview.includesAPIKeys ? WorkbenchTheme.risk : WorkbenchTheme.success).opacity(0.1),
        in: RoundedRectangle(cornerRadius: 10)
      )

      if preview.unresolvedAttachmentCount > 0 {
        Label(
          unresolvedAttachmentMessage,
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(WorkbenchTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }

      Label {
        Text(restoreImpactMessage)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(WorkbenchTheme.warning)
      }
      .padding(12)
      .background(WorkbenchTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

      if preview.compatibility.requiresConfirmation {
        Label {
          Text(compatibilityMessage)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(WorkbenchTheme.warning)
        }
        .padding(12)
        .background(WorkbenchTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("workspace-backup-compatibility-warning")
      }

      HStack {
        Spacer()
        Button(String(localized: "选择文章恢复"), systemImage: "checklist") {
          isArticleSelectionPresented = true
        }
        .disabled(!dataManagement.canRestoreBackupArticles || isRestoring)
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isRestoring)
        Button(String(localized: "恢复并重新启动"), role: .destructive) {
          requestRestore()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isRestoring || preview.includesAPIKeys)
      }
    }
    .padding(24)
    .frame(width: 640)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-backup-restore-preview")
    .sheet(isPresented: $isArticleSelectionPresented) {
      WorkspaceBackupArticleSelectionView(
        dataManagement: dataManagement,
        backupPreview: preview,
        requiresCompatibilityConfirmation: preview.compatibility.requiresConfirmation,
        compatibilityMessage: compatibilityMessage
      )
    }
    .onChange(of: dataManagement.canRestoreBackupArticles) { _, canRestore in
      if !canRestore {
        isArticleSelectionPresented = false
      }
    }
    .alert(String(localized: "版本兼容性提示"), isPresented: $isCompatibilityConfirmationPresented) {
      Button(String(localized: "仍然恢复"), role: .destructive) {
        stageRestoreAndRestart()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(compatibilityMessage)
    }
  }

  private func metadataRow(_ label: String, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }

  private func systemImage(for component: WorkspaceBackupComponent) -> String {
    switch component {
    case .workbenchState:
      return "square.and.pencil"
    case .draftAttachments:
      return "paperclip"
    case .knowledgeLibrary:
      return "books.vertical"
    case .rssReader:
      return "dot.radiowaves.left.and.right"
    case .operationHistory:
      return "clock.arrow.circlepath"
    }
  }

  private func componentSummary(_ component: WorkspaceBackupComponentSummary) -> String {
    String(
      format: String(localized: "%@ · %@ 个文件 · %@"),
      component.component.localizedDisplayName,
      component.fileCount.formatted(),
      ByteCountFormatter.string(fromByteCount: component.byteCount, countStyle: .file)
    )
  }

  private var apiKeyNotice: String {
    preview.includesAPIKeys
      ? String(localized: "此备份声明包含 API Key，应用不会导入。")
      : String(localized: "默认不包含 API Key；受限本地配置、系统钥匙串和本次会话中的 Key 都不会进入备份，跨机器恢复后需重新配置。")
  }

  private var restoreImpactMessage: String {
    if preview.components.contains(where: { $0.component == .rssReader }) {
      return String(
        localized: "恢复会替换当前工作台、资料库、RSS 和应用内附件，并重新启动应用。当前数据会先保留在恢复目录，可用于手动回退。"
      )
    }
    return String(
      localized: "这是旧版备份：恢复会替换当前工作台、资料库和应用内附件，但会保留现有 RSS 数据。当前数据会先保留在恢复目录。"
    )
  }

  private var unresolvedAttachmentMessage: String {
    String(
      format: String(
        localized: "有 %@ 个附件没有可复制的源文件；其元数据会保留，源文件需从原站点或仓库重新获取。"
      ),
      preview.unresolvedAttachmentCount.formatted()
    )
  }

  private var compatibilityMessage: String {
    switch preview.compatibility {
    case .compatible:
      return String(localized: "此备份与当前应用版本兼容。")
    case .createdByOlderApplication:
      return String(
        format: String(
          localized: "此备份由较旧版本创建（归档版本 %@）。应用会按当前格式迁移数据，恢复前请确认内容预览。"
        ),
        preview.applicationVersion
      )
    case .createdByNewerApplication:
      return String(
        format: String(
          localized: "此备份由较新版本创建（归档版本 %@），当前版本可能无法完整识别全部字段。建议先升级应用，再恢复此备份。"
        ),
        preview.applicationVersion
      )
    case .unknownApplicationVersion:
      return String(localized: "无法可靠比较归档与当前应用版本，但清单、快照、资料库和文件校验均已通过。确认要继续恢复吗？")
    }
  }

  private func requestRestore() {
    if preview.compatibility.requiresConfirmation {
      isCompatibilityConfirmationPresented = true
    } else {
      stageRestoreAndRestart()
    }
  }

  private func stageRestoreAndRestart() {
    isRestoring = true
    Task {
      let succeeded = await stageWorkspaceBackupRestore(preview.backupURL)
      isRestoring = false
      guard succeeded else { return }
      NSApp.terminate(nil)
    }
  }
}

private struct WorkspaceBackupArticleSelectionView: View {
  @ObservedObject var dataManagement: WorkbenchDataManagementFeatureFacade
  let backupPreview: WorkspaceBackupPreview
  let requiresCompatibilityConfirmation: Bool
  let compatibilityMessage: String

  @Environment(\.dismiss) private var dismiss
  @State private var selectionPreview: WorkspaceBackupArticleSelectionPreview?
  @State private var selectedDraftIDs = Set<UUID>()
  @State private var searchText = ""
  @State private var isLoading = false
  @State private var isRestoring = false
  @State private var errorMessage: String?
  @State private var successMessage: String?
  @State private var isCompatibilityConfirmationPresented = false
  @State private var restoreTask: Task<Void, Never>?

  private var backupURL: URL { backupPreview.backupURL }

  private var filteredArticles: [WorkspaceBackupArticleSummary] {
    guard let articles = selectionPreview?.articles else { return [] }
    guard !searchText.isEmpty else { return articles }
    return articles.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
  }

  private var allVisibleIDs: Set<UUID> { Set(filteredArticles.map(\.id)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("选择文章恢复")
            .font(.title2.weight(.semibold))
          Text(backupURL.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Spacer()
        if isLoading || isRestoring { ProgressView().controlSize(.small) }
      }

      if let selectionPreview {
        Text("只会读取所选文章的当前版本，并将其恢复为新建的通用草稿；现有文章、设置和历史记录不会改变。缺失附件会保留元数据。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          Text(String(format: String(localized: "已选择 %@ 篇文章"), selectedDraftIDs.count.formatted()))
          Spacer()
          Button("全选") { selectedDraftIDs = allVisibleIDs }
            .disabled(filteredArticles.isEmpty || isRestoring || successMessage != nil)
          Button("清空") { selectedDraftIDs.removeAll() }
            .disabled(selectedDraftIDs.isEmpty || isRestoring || successMessage != nil)
        }
        .font(.callout)

        if selectionPreview.articles.isEmpty {
          ContentUnavailableView("备份中没有可恢复的文章", systemImage: "doc.text.magnifyingglass")
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              ForEach(filteredArticles) { article in
                Button {
                  toggle(article.id)
                } label: {
                  HStack(alignment: .top, spacing: 10) {
                    Image(
                      systemName: selectedDraftIDs.contains(article.id)
                        ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(
                      selectedDraftIDs.contains(article.id) ? WorkbenchTheme.success : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(article.title).frame(maxWidth: .infinity, alignment: .leading)
                      Text(attachmentSummary(for: article))
                        .font(.caption)
                        .foregroundStyle(
                          article.unresolvedAttachmentCount > 0
                            ? WorkbenchTheme.warning : .secondary)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRestoring || successMessage != nil)
                .padding(.vertical, 5)
                .accessibilityValue(selectedDraftIDs.contains(article.id) ? "已选择" : "未选择")
              }
            }
          }
          .frame(maxHeight: 300)
          TextField("搜索文章", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("搜索文章")
            .disabled(isRestoring || successMessage != nil)
        }
      } else if isLoading {
        ProgressView("正在读取备份文章…")
      }

      if let errorMessage {
        AccessibleStatusMessage(message: errorMessage, severity: .error)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let successMessage {
        AccessibleStatusMessage(
          message: successMessage, severity: .success, announcesNonUrgentStatus: true
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      if !dataManagement.canRestoreBackupArticles {
        AccessibleStatusMessage(
          message: String(localized: "当前工作台暂不可写入，无法恢复文章。"), severity: .warning)
      }

      HStack {
        Spacer()
        Button(isRestoring ? "取消恢复" : "取消") {
          if isRestoring {
            restoreTask?.cancel()
          }
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(false)
        if successMessage != nil {
          Button("完成") { dismiss() }
            .keyboardShortcut(.defaultAction)
        } else {
          Button("恢复所选文章") { requestRestore() }
            .keyboardShortcut(.defaultAction)
            .disabled(
              selectedDraftIDs.isEmpty || isRestoring || isLoading
                || !dataManagement.canRestoreBackupArticles)
        }
      }
    }
    .padding(24)
    .frame(width: 620)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-backup-article-selection")
    .task { await loadPreview() }
    .onDisappear { restoreTask?.cancel() }
    .onChange(of: dataManagement.canRestoreBackupArticles) { _, canRestore in
      if !canRestore {
        selectionPreview = nil
        selectedDraftIDs.removeAll()
        dismiss()
      }
    }
    .alert(String(localized: "版本兼容性提示"), isPresented: $isCompatibilityConfirmationPresented) {
      Button("仍然恢复") { restoreSelectedArticles() }
      Button("取消", role: .cancel) {}
    } message: {
      Text(compatibilityMessage)
    }
  }

  private func toggle(_ id: UUID) {
    if selectedDraftIDs.contains(id) {
      selectedDraftIDs.remove(id)
    } else {
      selectedDraftIDs.insert(id)
    }
  }

  private func attachmentSummary(for article: WorkspaceBackupArticleSummary) -> String {
    if article.unresolvedAttachmentCount > 0 {
      return String(
        format: String(localized: "%@ 个附件；%@ 个本地附件缺失，将仅保留元数据"), article.attachmentCount.formatted(),
        article.unresolvedAttachmentCount.formatted())
    }
    return String(format: String(localized: "%@ 个附件"), article.attachmentCount.formatted())
  }

  private func loadPreview() async {
    guard dataManagement.canRestoreBackupArticles else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let loaded = try await dataManagement.workspaceBackupArticleSelectionPreview(
        from: backupURL)
      guard loaded.backupPreview == backupPreview else {
        throw WorkspaceBackupArticleRestoreError.backupChanged
      }
      selectionPreview = loaded
    } catch {
      errorMessage = localizedError(error)
    }
  }

  private func requestRestore() {
    if requiresCompatibilityConfirmation {
      isCompatibilityConfirmationPresented = true
    } else {
      restoreSelectedArticles()
    }
  }

  private func restoreSelectedArticles() {
    guard let selectionPreview, !selectedDraftIDs.isEmpty else { return }
    let selectedIDs = selectedDraftIDs
    isRestoring = true
    errorMessage = nil
    restoreTask = Task {
      do {
        let count = try await dataManagement.restoreWorkspaceBackupArticles(
          preview: selectionPreview,
          selectedDraftIDs: selectedIDs
        )
        guard !Task.isCancelled else { return }
        successMessage = String(format: String(localized: "已恢复 %@ 篇文章为新建通用草稿。"), count.formatted())
      } catch {
        if !Task.isCancelled { errorMessage = localizedError(error) }
      }
      isRestoring = false
    }
  }

  private func localizedError(_ error: Error) -> String {
    guard let restoreError = error as? WorkspaceBackupArticleRestoreError else {
      return error.localizedDescription
    }
    switch restoreError {
    case .invalidSelection: return String(localized: "所选文章无效，请重新选择。")
    case .backupChanged: return String(localized: "备份内容已变化，请关闭此预览后重新读取。")
    case .unavailable: return String(localized: "当前工作台暂不可用，无法恢复文章。")
    case .persistenceFailed:
      return String(localized: "未能确认草稿保存结果。请检查存储空间，并重新打开工作区核对后再试。")
    }
  }
}
