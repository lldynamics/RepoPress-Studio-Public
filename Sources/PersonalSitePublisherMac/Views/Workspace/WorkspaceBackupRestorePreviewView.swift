import PublishingBackupCore
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceBackupArticleSelectionView: View {
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


struct WorkspaceExchangeRestorePreviewSheet: View {
  let preview: WorkspaceExchangePreview
  let store: WorkbenchStore
  let onImported: (Int) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var choices: [UUID: ProfileChoice] = [:]
  @State private var slugOverrides: [UUID: String] = [:]
  @State private var isImporting = false
  @State private var errorMessage: String?

  private enum ProfileChoice: Hashable {
    case choose
    case importAsNew
    case existing(UUID)
  }

  private var sourceProfileIDs: [UUID] {
    var ids = preview.package.payload.drafts.compactMap { draft in
      draft.scope == "site" ? draft.sourceProfileID : nil
    }
    ids += preview.package.payload.profiles.map(\.id)
    return Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
  }

  private var profileByID: [UUID: WorkspaceExchangeProfile] {
    Dictionary(uniqueKeysWithValues: preview.package.payload.profiles.map { ($0.id, $0) })
  }

  private var mappingsAreComplete: Bool {
    sourceProfileIDs.allSatisfy { id in
      guard let choice = choices[id] else { return false }
      switch choice {
      case .choose: return false
      case .importAsNew: return profileByID[id] != nil
      case .existing(let destinationID): return store.profiles.contains { $0.id == destinationID }
      }
    }
  }

  private var selectedMappings: [UUID: WorkspaceExchangeProfileMapping] {
    Dictionary(uniqueKeysWithValues: choices.compactMap { sourceID, choice -> (UUID, WorkspaceExchangeProfileMapping)? in
      switch choice {
      case .choose: nil
      case .importAsNew: (sourceID, .importAsNewProfile)
      case .existing(let destinationID): (sourceID, .existing(destinationID))
      }
    })
  }

  private var pathValidation: (conflicts: [WorkspaceExchangePublishPathConflict], error: String?) {
    guard mappingsAreComplete else { return ([], nil) }
    do {
      return (try WorkspaceExchangePathConflictService.conflicts(
        package: preview.package,
        profileMappings: selectedMappings,
        slugOverrides: slugOverrides,
        existingProfiles: store.profiles,
        existingDrafts: store.drafts
      ), nil)
    } catch {
      return ([], error.localizedDescription)
    }
  }

  var body: some View {
    let validation = pathValidation
    return VStack(alignment: .leading, spacing: 16) {
      Text("跨端交换文件预览")
        .font(.title2.weight(.semibold))
      Text("文件会作为新草稿追加。重复导入也会创建新副本；现有草稿和站点配置不会被覆盖。")
        .foregroundStyle(.secondary)

      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
        metric("站点配置", value: preview.package.payload.profiles.count)
        metric("草稿", value: preview.package.payload.drafts.count)
        metric("附件", value: preview.package.manifest.itemCounts.attachments)
        metric("文件大小", detail: preview.estimatedSizeBytes.formatted(.byteCount(style: .file)))
      }

      if !preview.conflictingProfileNames.isEmpty {
        warning("同名站点配置：\(preview.conflictingProfileNames.joined(separator: "、"))。导入后仍会创建或映射到你选择的目标。")
      }
      if preview.unmappedSiteDraftCount > 0 {
        warning("\(preview.unmappedSiteDraftCount) 篇站点文章需要显式映射来源站点配置。")
      }
      if preview.attachmentAccessibilityMetadataCount > 0 {
        warning(
          String(
            localized:
              "有 \(preview.attachmentAccessibilityMetadataCount) 个附件包含替代文字或说明。此版本会保留这些内容；通过旧版 iOS 再次导出时仍可能丢失。"
          ))
      }
      warning("Markdown 正文中的附件链接保持原样；导入会保留相对发布路径，不会改写正文链接。")

      if !sourceProfileIDs.isEmpty {
        Text("为每个来源配置选择处理方式")
          .font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(sourceProfileIDs, id: \.self) { sourceID in
              profileMappingRow(sourceID)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
      }

      let conflictsByDraftID = Dictionary(
        uniqueKeysWithValues: validation.conflicts.map { ($0.sourceDraftID, $0) })
      let editableDrafts = preview.package.payload.drafts.filter { draft in
        conflictsByDraftID[draft.id] != nil || slugOverrides[draft.id] != nil
      }
      if !editableDrafts.isEmpty {
        Text("调整重复的发布路径")
          .font(.headline)
        Text("以下草稿在所选目标站点生成了相同发布路径。请修改 Slug，直到冲突消失；原有文章不会被覆盖。")
          .font(.callout)
          .foregroundStyle(.secondary)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(editableDrafts, id: \.id) { draft in
              let conflict = conflictsByDraftID[draft.id]
              VStack(alignment: .leading, spacing: 4) {
                Text(draft.title.isEmpty ? String(localized: "未命名文章") : draft.title)
                  .font(.subheadline.weight(.semibold))
                if let conflict {
                  Text("\(conflict.destinationProfileName) · \(conflict.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                } else {
                  Text("发布路径冲突已解决")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                TextField("新 Slug", text: slugBinding(for: draft))
                  .textFieldStyle(.roundedBorder)
                  .accessibilityLabel("\(draft.title) 的新 Slug")
                if slugOverrides[draft.id] != nil {
                  Button("恢复原 Slug") { slugOverrides.removeValue(forKey: draft.id) }
                    .buttonStyle(.link)
                }
              }
              .padding(10)
              .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .frame(maxHeight: 220)
      }

      if let validationError = validation.error {
        AccessibleStatusMessage(message: validationError, severity: .error)
          .textSelection(.enabled)
      }

      if let errorMessage {
        AccessibleStatusMessage(message: errorMessage, severity: .error)
          .textSelection(.enabled)
      }

      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button {
          importPackage()
        } label: {
          if isImporting {
            ProgressView().controlSize(.small)
          } else {
            Text("导入为新草稿")
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isImporting || !mappingsAreComplete || !validation.conflicts.isEmpty || validation.error != nil)
      }
    }
    .padding(24)
    .frame(minWidth: 620, minHeight: 480)
  }

  private func metric(_ title: LocalizedStringKey, value: Int) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value.formatted()).monospacedDigit()
    }
  }

  private func metric(_ title: LocalizedStringKey, detail: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(detail).monospacedDigit()
    }
  }

  @ViewBuilder
  private func profileMappingRow(_ sourceID: UUID) -> some View {
    let source = profileByID[sourceID]
    VStack(alignment: .leading, spacing: 5) {
      Text(source?.name ?? "包中未包含来源配置")
        .font(.subheadline.weight(.semibold))
      if let source {
        Text("\(source.siteKind) · \(source.repoOwner)/\(source.repoName) · \(source.branch)")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(sourceID.uuidString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Picker("目标配置", selection: choiceBinding(for: sourceID)) {
        Text("请选择…").tag(ProfileChoice.choose)
        if source != nil {
          Text("作为新的本地配置导入").tag(ProfileChoice.importAsNew)
        }
        ForEach(store.profiles) { profile in
          Text("映射到：\(profile.name)").tag(ProfileChoice.existing(profile.id))
        }
      }
      .labelsHidden()
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
  }

  private func choiceBinding(for sourceID: UUID) -> Binding<ProfileChoice> {
    Binding(
      get: { choices[sourceID] ?? .choose },
      set: { choices[sourceID] = $0 }
    )
  }

  private func slugBinding(for draft: WorkspaceExchangeDraft) -> Binding<String> {
    Binding(
      get: { slugOverrides[draft.id] ?? draft.slug },
      set: { slugOverrides[draft.id] = $0 }
    )
  }

  private func warning(_ message: String) -> some View {
    Label(message, systemImage: "info.circle")
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func importPackage() {
    guard mappingsAreComplete else { return }
    let validation = pathValidation
    guard validation.conflicts.isEmpty, validation.error == nil else { return }
    isImporting = true
    errorMessage = nil
    let mappings = selectedMappings
    Task {
      defer { isImporting = false }
      do {
        let count = try await store.importWorkspaceExchange(
          preview,
          profileMappings: mappings,
          slugOverrides: slugOverrides
        )
        onImported(count)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
