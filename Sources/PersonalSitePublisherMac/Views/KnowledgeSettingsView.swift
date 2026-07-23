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
  @ObservedObject var knowledge: KnowledgeStore
  let browserBridge: KnowledgeBrowserBridge?
  let onOpenLibrary: () -> Void

  @AppStorage("knowledgeSavedCollectionsV1") private var savedCollectionsJSON = "[]"
  @State private var expansionState = KnowledgeAdvancedSettingsExpansionState()
#if !APP_STORE_BUILD
  @State private var isBrowserConnectionPresented = false
#endif
  @State private var restorePreview: KnowledgeLibraryBackupPreview?

  var body: some View {
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

#if !APP_STORE_BUILD
        DisclosureGroup(isExpanded: $expansionState.browserConnection) {
          browserConnectionSettings
        } label: {
          advancedGroupLabel(
            title: String(localized: "浏览器连接"),
            detail: String(localized: "从 Chrome、Edge 或 Firefox 保存网页"),
            systemImage: "puzzlepiece.extension"
          )
        }
        .accessibilityIdentifier("knowledge-settings-browser-connection")
#endif
      }
    }
    .formStyle(.grouped)
    .padding()
    .sheet(item: $restorePreview) { preview in
      KnowledgeLibraryRestorePreviewView(knowledge: knowledge, preview: preview)
    }
#if !APP_STORE_BUILD
    .sheet(isPresented: $isBrowserConnectionPresented) {
      if let browserBridge {
        BrowserExtensionConnectionView()
          .environmentObject(browserBridge)
      }
    }
#endif
    .onChange(of: expansionState.vectorSearch) { _, isExpanded in
      guard isExpanded, knowledge.healthSnapshot == nil, !knowledge.isLoadingHealth else { return }
      Task { await knowledge.refreshLibraryHealth() }
    }
    .accessibilityIdentifier("knowledge-settings")
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
    }
    .padding(.leading, 22)
    .padding(.vertical, 8)
  }

#if !APP_STORE_BUILD
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
#endif

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
}
