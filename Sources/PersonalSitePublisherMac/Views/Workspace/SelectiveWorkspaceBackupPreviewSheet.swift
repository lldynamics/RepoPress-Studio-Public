import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct SelectiveWorkspaceBackupPreviewSheet: View {
  let preview: WorkspaceBackupSelectiveRestorePreview
  @ObservedObject var dataManagement: WorkbenchDataManagementFeatureFacade
  let prepareRestore: @MainActor (Set<WorkspaceBackupCategory>) async throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedCategories = Set<WorkspaceBackupCategory>()
  @State private var isConfirmingRestore = false
  @State private var isConfirmingCompatibility = false
  @State private var isPreparingRestore = false
  @State private var isArticleSelectionPresented = false
  @State private var restoreError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("恢复预览")
            .font(.workbenchPageTitle)
          Text(preview.backupPreview.backupURL.lastPathComponent)
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Spacer()
        Button("完成") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }

      LabeledContent("备份时间", value: preview.backupPreview.createdAt.formatted(date: .abbreviated, time: .shortened))
      LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: preview.backupPreview.totalByteCount, countStyle: .file))
      LabeledContent("格式版本", value: preview.backupPreview.formatVersion.formatted())
      AccessibleStatusMessage(
        message: preview.backupPreview.includesAPIKeys
          ? String(localized: "此备份声明包含 API Key；分类恢复已禁用。")
          : String(localized: "此备份不包含 API Key、Keychain 内容或 AI 服务凭据。"),
        severity: preview.backupPreview.includesAPIKeys ? .error : .success
      )
      if preview.backupPreview.compatibility.requiresConfirmation {
        AccessibleStatusMessage(message: compatibilityMessage, severity: .warning)
      }

      Divider()
      Text("包含的数据")
        .font(.headline)
      ForEach(preview.availableCategories, id: \.self) { category in
        let summary = preview.categorySummaries.first { $0.category == category }
        VStack(alignment: .leading, spacing: 5) {
          Toggle(isOn: categoryBinding(category)) {
            HStack {
              Label(categoryTitle(category), systemImage: categoryIcon(category))
              Spacer()
              Text("\(summary?.fileCount ?? 0) 个文件 · \(ByteCountFormatter.string(fromByteCount: summary?.byteCount ?? 0, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
          if category == .workbench {
            Text("草稿、历史版本、站点和工作台配置、发布历史、AI 对话及引用附件")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if preview.replacementCategories.contains(category), selectedCategories.contains(category) {
            Text("将替换本机该类别")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.leading, 24)
          }
        }
      }

      AccessibleStatusMessage(
        message: String(localized: "所选类别恢复会替换本机对应数据。恢复前的当前数据会先保存在恢复目录；所选内容会在应用重新启动时生效。"),
        severity: .warning
      )

      HStack {
        Button("按文章添加草稿…", systemImage: "checklist") {
          isArticleSelectionPresented = true
        }
        .disabled(!preview.availableCategories.contains(.workbench) || isPreparingRestore)
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("准备恢复所选类别…", systemImage: "arrow.counterclockwise", role: .destructive) {
          if preview.backupPreview.compatibility.requiresConfirmation {
            isConfirmingCompatibility = true
          } else {
            isConfirmingRestore = true
          }
        }
        .disabled(selectedCategories.isEmpty || isPreparingRestore || preview.backupPreview.includesAPIKeys)
      }

      if isPreparingRestore {
        ProgressView("正在保存恢复前数据并准备恢复…")
          .controlSize(.small)
      }
      if let restoreError {
        AccessibleStatusMessage(message: restoreError, severity: .error)
      }

      Spacer(minLength: 0)
    }
    .padding(WorkbenchSpacing.page)
    .frame(minWidth: 560, minHeight: 480)
    .accessibilityIdentifier("selective-workspace-backup-preview")
    .confirmationDialog(
      "确认替换所选类别？",
      isPresented: $isConfirmingRestore,
      titleVisibility: .visible
    ) {
      Button("保存当前数据并重新启动", role: .destructive) {
        prepareSelectedRestore()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(selectedReplacementSummary)
    }
    .confirmationDialog(
      "版本兼容性提示",
      isPresented: $isConfirmingCompatibility,
      titleVisibility: .visible
    ) {
      Button("仍然继续并审阅替换范围", role: .destructive) {
        isConfirmingRestore = true
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(compatibilityMessage)
    }
    .sheet(isPresented: $isArticleSelectionPresented) {
      WorkspaceBackupArticleSelectionView(
        dataManagement: dataManagement,
        backupPreview: preview.backupPreview,
        requiresCompatibilityConfirmation: preview.backupPreview.compatibility.requiresConfirmation,
        compatibilityMessage: String(localized: "请确认此备份与当前应用版本的兼容性。")
      )
    }
  }

  private var selectedReplacementSummary: String {
    let selected = preview.availableCategories.filter { selectedCategories.contains($0) }
      .map(categoryTitle)
      .joined(separator: "、")
    return String(localized: "以下类别将替换本机现有数据：\(selected)。当前数据会先保存在恢复目录；应用重新启动后生效。")
  }

  private var compatibilityMessage: String {
    switch preview.backupPreview.compatibility {
    case .compatible:
      return String(localized: "此备份与当前应用版本兼容。")
    case .createdByOlderApplication:
      return String(localized: "此备份由较旧版本的应用创建。恢复前请确认预览，部分字段可能已迁移。")
    case .createdByNewerApplication:
      return String(localized: "此备份由较新版本的应用创建；当前版本可能无法读取全部数据。建议升级后再恢复。")
    case .unknownApplicationVersion:
      return String(localized: "无法确认此备份的应用版本兼容性。请检查内容预览后再继续。")
    }
  }

  private func prepareSelectedRestore() {
    isPreparingRestore = true
    Task { @MainActor in
      do {
        try await prepareRestore(selectedCategories)
      } catch {
        restoreError = String(localized: "无法准备所选恢复：\(error.localizedDescription)")
        isPreparingRestore = false
        return
      }
      isPreparingRestore = false
      NSApp.terminate(nil)
    }
  }

  private func categoryBinding(_ category: WorkspaceBackupCategory) -> Binding<Bool> {
    Binding(
      get: { selectedCategories.contains(category) },
      set: { selected in
        if selected { selectedCategories.insert(category) }
        else { selectedCategories.remove(category) }
      }
    )
  }

  private func categoryTitle(_ category: WorkspaceBackupCategory) -> String {
    switch category {
    case .workbench: return String(localized: "草稿与附件")
    case .knowledgeLibrary: return String(localized: "资料库")
    case .rssReader: return String(localized: "RSS 阅读器")
    case .operationHistory: return String(localized: "操作记录")
    }
  }

  private func categoryIcon(_ category: WorkspaceBackupCategory) -> String {
    switch category {
    case .workbench: return "doc.text"
    case .knowledgeLibrary: return "books.vertical"
    case .rssReader: return "dot.radiowaves.left.and.right"
    case .operationHistory: return "clock.arrow.circlepath"
    }
  }
}
