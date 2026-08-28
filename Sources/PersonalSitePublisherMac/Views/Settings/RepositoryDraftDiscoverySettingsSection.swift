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
  let store: WorkbenchStore
  let activeProfileBinding: Binding<SiteProfile>
  @State private var scanTask: Task<Void, Never>?
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
    } footer: {
      Text("关闭自动发现后，“立即扫描新文章”和仓库工作区里的手动扫描仍可使用。")
    }
    .onDisappear {
      scanTask?.cancel()
      scanTask = nil
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

  private func scanForNewArticles() {
    guard RepositoryDraftDiscoveryPolicy.canRunManually(
      hasRepositoryRoot: activeProfile.localRepositoryRootURL != nil,
      isRunning: scanTask != nil
    ) else { return }
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
