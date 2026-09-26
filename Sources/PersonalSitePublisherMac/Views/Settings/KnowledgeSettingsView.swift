import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeAdvancedSettingsExpansionState: Equatable {
  var vectorSearch = false
  var smartCollections = false
  var backup = false

  var isFullyCollapsed: Bool {
    !vectorSearch && !smartCollections && !backup
  }
}

struct KnowledgeSettingsView: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  @ObservedObject var knowledge: KnowledgeStore
  let onOpenLibrary: () -> Void

  @AppStorage("knowledgeSavedCollectionsV1") private var savedCollectionsJSON = "[]"
  @AppStorage("dataManagementRequestedSection") private var dataManagementRequestedSection = DataManagementSection.backup.rawValue
  @State private var expansionState = KnowledgeAdvancedSettingsExpansionState()

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
        }
      }
      .formStyle(.grouped)
      .padding(WorkbenchSpacing.content)
    }
    .onChange(of: expansionState.vectorSearch) { _, isExpanded in
      guard isExpanded, knowledge.healthSnapshot == nil, !knowledge.isLoadingHealth else { return }
      Task { await knowledge.refreshLibraryHealth() }
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
        Text("管理本地检索、智能集合和备份。")
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
      Text("资料库备份、完整工作区备份、自动备份和恢复预览已集中到“数据管理”。")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button {
        openDataManagement()
      } label: {
        Label("打开数据管理", systemImage: "externaldrive")
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
        .foregroundStyle(workbenchAccentColor)
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

  private func openDataManagement() {
    dataManagementRequestedSection = DataManagementSection.backup.rawValue
    SettingsNavigation.present(
      destination: .data(.backup),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }
}
