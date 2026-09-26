import PublishingWorkbenchCore
import SwiftUI

enum RepositoryDraftDiscoveryPolicy {
  static func shouldRunAutomatically(
    isSafeMode: Bool,
    canUseProtectedWorkbench: Bool,
    isEnabled: Bool,
    isRefreshRunning: Bool
  ) -> Bool {
    !isSafeMode && canUseProtectedWorkbench && isEnabled && !isRefreshRunning
  }

  static func canRunManually(hasRepositoryRoot: Bool, isRunning: Bool) -> Bool {
    hasRepositoryRoot && !isRunning
  }
}

@MainActor
struct RepositoryDraftDiscoverySettingsSection: View {
  @ObservedObject var store: WorkbenchStore
  let activeProfileBinding: Binding<SiteProfile>
  var subsectionAnchor: SettingsSubsection? = nil
  @State private var scanTask: Task<Void, Never>?
  @State private var externalScanTask: Task<Void, Never>?
  @State private var confirmDisconnectExternalFolder = false
  @State private var externalStatusMessage: String?
  @State private var externalStatusSeverity: AccessibleStatusSeverity = .info
  @State private var statusMessage: String?
  @State private var statusSeverity: AccessibleStatusSeverity = .success

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          "自动发现并导入仓库中新文章",
          isOn: automaticallyImportsNewArticlesBinding
        )
        .accessibilityHint(
          "开启后，工作台启动、回到前台或从快速隐藏恢复时会查找当前站点仓库中的新文章。"
        )
        .accessibilityIdentifier("repository-draft-discovery-automatic")

        Text("只会把尚未登记的本地文章加入工作台，不会改写仓库文件或覆盖已有草稿。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityHidden(true)
      }

      Button {
        scanForNewArticles()
      } label: {
        if scanTask == nil {
          Label("立即扫描新文章", systemImage: "doc.badge.plus")
        } else {
          Label("正在扫描新文章…", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      .disabled(
        !RepositoryDraftDiscoveryPolicy.canRunManually(
          hasRepositoryRoot: activeProfile.localRepositoryRootURL != nil,
          isRunning: scanTask != nil
        )
      )
      .accessibilityIdentifier("repository-draft-discovery-scan-now")

      if activeProfile.localRepositoryRootURL == nil {
        Text("请先为当前站点选择本地仓库。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let statusMessage {
        AccessibleStatusMessage(
          message: statusMessage,
          severity: statusSeverity,
          announcesNonUrgentStatus: true
        )
        .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("本地文章发现")
        .settingsSubsectionAnchor(subsectionAnchor)
    } footer: {
      Text("关闭自动发现后，“立即扫描新文章”和仓库工作区里的手动扫描仍可使用。")
    }
    Section {
      if let mapping = activeProfile.externalDraftFolder {
        Text(mapping.path)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("external-draft-folder-path")
      } else {
        Text("选择 Obsidian Vault 的输出目录、Logseq 导出目录或普通 Markdown 文件夹。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button(activeProfile.externalDraftFolder == nil ? "选择草稿文件夹" : "更换草稿文件夹") {
          chooseExternalFolder()
        }
        .accessibilityIdentifier("external-draft-folder-choose")

        Button(externalScanTask == nil ? "立即同步" : "正在同步…") {
          scanExternalFolder()
        }
        .disabled(activeProfile.externalDraftFolder == nil || externalScanTask != nil)
        .accessibilityIdentifier("external-draft-folder-scan")

        if activeProfile.externalDraftFolder != nil {
          Button("停止映射") {
            confirmDisconnectExternalFolder = true
          }
          .accessibilityIdentifier("external-draft-folder-disconnect")
        }
      }

      if activeProfile.externalDraftFolder != nil {
        Toggle("观察文件变更并自动同步", isOn: observesExternalChangesBinding)
          .accessibilityIdentifier("external-draft-folder-observe")
      }

      if !store.externalDraftWriteFailures.isEmpty {
        HStack {
          Text("有 \(store.externalDraftWriteFailures.count) 篇草稿未能写回原文件；源文件和软件草稿均已保留。")
            .font(.workbenchSupporting)
          Button("重试写回") {
            store.retryExternalDraftWrites()
          }
        }
      }

      ForEach(
        store.drafts.filter {
          store.externalDraftConflicts.contains($0.id)
            && $0.externalDraftSource?.mappingID == activeProfile.externalDraftFolder?.id
        }
      ) { draft in
        if let source = draft.externalDraftSource {
          VStack(alignment: .leading, spacing: 4) {
            Text("两处均已修改：\(source.relativePath)")
              .font(.workbenchSupporting)
            Button("保留本地副本并采用外部文件") {
              Task { @MainActor in
                let resolved = await store.keepLocalCopyAndAcceptExternal(draftID: draft.id)
                externalStatusMessage =
                  resolved
                  ? String(localized: "已保留本地冲突副本，并更新映射草稿。")
                  : String(localized: "冲突处理未完成，请重新扫描后重试。")
                externalStatusSeverity = resolved ? .success : .error
              }
            }
          }
        }
      }

      if let externalStatusMessage {
        AccessibleStatusMessage(
          message: externalStatusMessage,
          severity: externalStatusSeverity,
          announcesNonUrgentStatus: true
        )
      }
    } header: {
      Text("外部 Markdown 草稿文件夹")
    } footer: {
      Text("Markdown 正文双向同步；写作标题等独立元数据保存在软件中。两处同时修改时可保留本地副本并采用外部版本。停止映射会保留软件里的草稿。")
    }
    .confirmationDialog(
      "停止映射外部草稿文件夹？",
      isPresented: $confirmDisconnectExternalFolder
    ) {
      Button("停止映射并保留草稿") {
        if store.disconnectExternalDraftFolder() {
          externalStatusMessage = String(localized: "已停止映射；现有通用草稿保留在软件中。")
          externalStatusSeverity = .success
        } else {
          externalStatusMessage = String(localized: "正在写回外部文件，请稍后再停止映射。")
          externalStatusSeverity = .warning
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("断开后不再自动读取或写回该文件夹。")
    }
    .onDisappear {
      scanTask?.cancel()
      scanTask = nil
      externalScanTask?.cancel()
      externalScanTask = nil
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var automaticallyImportsNewArticlesBinding: Binding<Bool> {
    Binding(
      get: { activeProfile.resolvedAutomaticallyImportsNewRepositoryArticles },
      set: { isEnabled in
        var profile = activeProfile
        profile.resolvedAutomaticallyImportsNewRepositoryArticles = isEnabled
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private var observesExternalChangesBinding: Binding<Bool> {
    Binding(
      get: { activeProfile.externalDraftFolder?.observesChanges ?? false },
      set: { observes in
        var profile = activeProfile
        profile.externalDraftFolder?.observesChanges = observes
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private func chooseExternalFolder() {
    guard let url = ExternalDraftFolderSelectionPanel.chooseDirectory() else { return }
    externalScanTask?.cancel()
    externalScanTask = nil
    guard store.connectExternalDraftFolder(url) else {
      externalStatusMessage = String(localized: "文件夹不可读取，或仍在写回文件，请稍后重新选择。")
      externalStatusSeverity = .error
      return
    }
    scanExternalFolder()
  }

  private func scanExternalFolder() {
    guard activeProfile.externalDraftFolder != nil, externalScanTask == nil else { return }
    externalStatusMessage = nil
    externalStatusSeverity = .info
    externalScanTask = Task { @MainActor in
      let summary = await store.scanExternalDraftFolder()
      guard !Task.isCancelled else { return }
      externalScanTask = nil
      if let errorMessage = summary.errorMessage {
        externalStatusMessage = errorMessage
        externalStatusSeverity = .error
      } else {
        externalStatusMessage = String(
          localized:
            "已加入 \(summary.addedCount) 篇，刷新 \(summary.refreshedCount) 篇；冲突 \(summary.conflictCount) 篇，源文件暂缺 \(summary.missingCount) 篇。"
        )
      }
    }
  }

  private func scanForNewArticles() {
    guard
      RepositoryDraftDiscoveryPolicy.canRunManually(
        hasRepositoryRoot: activeProfile.localRepositoryRootURL != nil,
        isRunning: scanTask != nil
      )
    else { return }
    let profileID = activeProfile.id
    let previousActionFeedback = store.publishActionFeedback
    statusMessage = nil
    statusSeverity = .success
    scanTask = Task { @MainActor in
      let insertedCount = await store.importMissingDraftsFromLocalRepository()
      guard !Task.isCancelled, store.activeProfileID == profileID else {
        scanTask = nil
        return
      }
      if insertedCount > 0 {
        statusMessage = String(localized: "已发现并加入工作台 \(insertedCount) 篇新文章。")
      } else if store.publishActionFeedback != previousActionFeedback,
        let actionFeedback = store.publishActionFeedback
      {
        statusMessage = actionFeedback.message
        statusSeverity = accessibilitySeverity(for: actionFeedback.status)
      } else {
        statusMessage = String(localized: "扫描完成，没有发现新的仓库文章。")
      }
      scanTask = nil
    }
  }

  private func accessibilitySeverity(
    for status: PublishActionMessageStatus
  ) -> AccessibleStatusSeverity {
    switch status {
    case .information, .inProgress:
      return .info
    case .success:
      return .success
    case .warning:
      return .warning
    case .failure:
      return .error
    }
  }
}
