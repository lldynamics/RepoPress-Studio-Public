import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var repositoryStageContent: some View {
    switch stage {
    case .overview:
      repositorySummary
      repositoryScanProgress
      onlinePublishCenterSection
      repositorySyncPlan
      pathRules
    case .changes:
      repositoryScanProgress
      remoteChangedFiles
      changedFiles
    case .automation:
      repositoryAutoSyncSection
    case .preview:
      localPreviewSection
    case .source:
      EmptyView()
    case .history:
      ReleaseHistoryDetailView(store: store)
    }
  }

  var hasSelectedRepository: Bool {
    !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  var repositoryActionsMenu: some View {
    Menu {
      Button {
        chooseRepository()
      } label: {
        Label("更换仓库", systemImage: "folder")
      }
      .disabled(store.repository.scanState.isScanning)

      if store.repository.scanState.isScanning {
        Button {
          store.repository.cancelScan()
        } label: {
          Label("取消扫描", systemImage: "xmark.circle")
        }
      } else {
        Button {
          scanRepository()
        } label: {
          Label("重新扫描", systemImage: "arrow.clockwise")
        }
      }

      Divider()

      Button {
        Task {
          await store.importDraftsFromLocalRepositoryAsync()
        }
      } label: {
        Label("导入文章", systemImage: "tray.and.arrow.down")
      }

      Button {
        isContentMigrationPresented = true
      } label: {
        Label("内容迁移", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
      }
    } label: {
      Label("仓库操作", systemImage: "ellipsis.circle")
    }
    .accessibilityLabel("仓库操作")
  }

  @ViewBuilder
  var repositoryWorkflowBanner: some View {
    if !hasSelectedRepository {
      workflowBanner(
        title: "尚未选择本地仓库",
        detail: "先选择静态站点仓库，才能扫描变更、写入文章或启动预览。",
        systemImage: "externaldrive.badge.questionmark",
        tint: WorkbenchTheme.warning,
        actionTitle: "选择仓库",
        action: chooseRepository
      )
    } else if store.repository.scanState.isScanning {
      workflowBanner(
        title: "正在扫描仓库",
        detail: store.repository.scanState.message,
        systemImage: "arrow.clockwise",
        tint: .secondary,
        actionTitle: "取消扫描",
        action: store.repository.cancelScan
      )
    } else if let report = store.repositoryReport,
              let issue = report.preflightIssues.first(where: { $0.severity == .error }) {
      workflowBanner(
        title: "仓库配置阻断：\(issue.title)",
        detail: issue.message,
        systemImage: "xmark.octagon",
        tint: WorkbenchTheme.risk,
        actionTitle: "查看概览",
        action: { stage = .overview }
      )
    } else if let report = store.repositoryReport, !report.remoteChangedFiles.isEmpty {
      workflowBanner(
        title: "远端有 \(report.remoteChangedFiles.count) 个变更",
        detail: "先审阅远端 diff，确认是否导入或合并后再写入与发布。",
        systemImage: "arrow.down.doc",
        tint: WorkbenchTheme.warning,
        actionTitle: "审阅变更",
        action: { stage = .changes }
      )
    } else if let report = store.repositoryReport, !report.changedFiles.isEmpty {
      workflowBanner(
        title: "本地有 \(report.changedFiles.count) 个变更",
        detail: "先确认文章、图片和配置 diff，再进入写入与发布。",
        systemImage: "arrow.triangle.2.circlepath",
        tint: WorkbenchTheme.warning,
        actionTitle: "审阅变更",
        action: { stage = .changes }
      )
    } else if store.repositoryReport == nil {
      workflowBanner(
        title: "仓库尚未扫描",
        detail: "扫描会识别站点结构、Git 状态和本地变更。",
        systemImage: "arrow.clockwise",
        tint: .secondary,
        actionTitle: "开始扫描",
        action: scanRepository
      )
    } else if let draft = store.selectedDraft,
              let readiness = store.localPublishReadiness,
              readiness.blockingIssueCount > 0 {
      workflowBanner(
        title: "当前文章存在 \(readiness.blockingIssueCount) 个发布阻断项",
        detail: "先处理文章检查结果，再写入或线上发布。",
        systemImage: "checklist",
        tint: WorkbenchTheme.risk,
        actionTitle: "查看检查",
        action: { _ = store.focusDraft(draft.id, section: .contentHealth) }
      )
    } else if store.selectedDraft != nil {
      workflowBanner(
        title: "已具备继续发布的仓库上下文",
        detail: "在统一发布流程中确认检查、差异（Diff）、写入、远端和部署状态。",
        systemImage: "paperplane",
        tint: WorkbenchTheme.success,
        actionTitle: "打开发布流程",
        action: openUnifiedPublishFlow
      )
    } else {
      workflowBanner(
        title: "请选择一篇文章",
        detail: "选择文章后可生成发布包、审阅 diff 并执行发布。",
        systemImage: "doc.badge.questionmark",
        tint: .secondary,
        actionTitle: "前往写作",
        action: { store.selectSection(.writing) }
      )
    }
  }

  var repositorySelectionEmptyState: some View {
    EmptyStateView(
      title: "选择仓库后继续",
      message: "变更、写入与发布、自动化和本地预览会在仓库选定后按需显示。",
      systemImage: "externaldrive.badge.plus",
      actionTitle: "选择仓库",
      actionSystemImage: "folder.badge.plus",
      action: chooseRepository
    )
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  var repositoryScanRequiredState: some View {
    let content: (title: String, message: String, systemImage: String)
    switch stage {
    case .changes:
      content = (
        String(localized: "扫描后查看仓库变更"),
        String(localized: "扫描会读取 Git 状态、远端差异和发布相关文件，不会修改仓库。"),
        "arrow.left.arrow.right"
      )
    case .automation:
      content = (
        String(localized: "扫描后启用自动检查"),
        String(localized: "先识别项目类型和现有脚本，再为当前仓库提供准确的检查入口。"),
        "checkmark.shield"
      )
    case .preview:
      content = (
        String(localized: "扫描后启动本地预览"),
        String(localized: "扫描会确认站点类型、预览命令和可用端口，然后显示启动操作。"),
        "play.rectangle"
      )
    case .source:
      content = (
        String(localized: "打开 HTML 高级源码编辑器"),
        String(localized: "选择仓库中的 HTML 文件后，可在保留编码与换行符的前提下安全编辑。"),
        "chevron.left.forwardslash.chevron.right"
      )
    case .history:
      content = (
        String(localized: "扫描后关联发布台账"),
        String(localized: "扫描当前仓库后，可将发布记录与分支、远端和部署状态对应起来。"),
        "clock.arrow.circlepath"
      )
    case .overview:
      content = (
        String(localized: "先扫描本地仓库"),
        String(localized: "读取仓库状态后，这里会显示发布准备情况和下一步建议。"),
        "arrow.clockwise.circle"
      )
    }

    return EmptyStateView(
      title: LocalizedStringKey(content.title),
      message: LocalizedStringKey(content.message),
      systemImage: content.systemImage,
      density: .inline,
      actionTitle: "扫描仓库",
      actionSystemImage: "arrow.clockwise",
      action: {
        Task { await store.repository.scanAsync() }
      }
    )
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.subtle,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  func openUnifiedPublishFlow() {
    if let publishDrawerCommandAction {
      publishDrawerCommandAction.open(
        "已从仓库工作区进入统一发布流程，请确认检查、差异、写入、远端和部署状态。"
      )
    } else {
      store.runPreflight()
      store.setPublishActionMessage(String(localized: "请从顶部发布状态打开统一发布流程。"))
    }
  }

  func workflowBanner(
    title: String,
    detail: String,
    systemImage: String,
    tint: Color,
    actionTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .font(.title3)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 12)
      Button(action: action) {
        Text(actionTitle)
      }
      .workbenchProminentActionStyle()
    }
    .padding(12)
    .background(tint.opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前同步阻断与下一步")
  }

  func chooseRepository() {
    guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
    Task {
      await store.repository.rememberRootAsync(url)
    }
  }

  func scanRepository() {
    Task {
      await store.repository.scanAsync()
    }
  }

  @ViewBuilder
  var repositoryScanProgress: some View {
    if store.repository.scanState.isScanning {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text(store.repository.scanState.message)
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          store.repository.cancelScan()
        } label: {
          Label("取消", systemImage: "xmark.circle")
        }
        .controlSize(.small)
      }
      .padding(12)
      .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    } else if store.repository.scanState.finishedAt != nil {
      Label(store.repository.scanState.message, systemImage: "checkmark.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  var repositorySummary: some View {
    if let report = store.repositoryReport {
      LazyVGrid(columns: repositoryMetricGridColumns, spacing: 12) {
        MetricTile(title: "仓库状态", value: report.statusTitle, systemImage: "externaldrive")
        MetricTile(title: "同步", value: report.syncStatusTitle, systemImage: "arrow.up.arrow.down")
        MetricTile(title: "Markdown", value: "\(report.markdownFileCount)", systemImage: "doc.text")
        MetricTile(title: "图片", value: "\(report.imageFileCount)", systemImage: "photo")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(report.rootPath.isEmpty ? "未选择仓库" : report.rootPath)
          .font(.callout.monospaced())
          .textSelection(.enabled)
        Label(report.detectedKind?.localizedDisplayName ?? "未识别", systemImage: "globe")
          .foregroundStyle(.secondary)
        if let branchStatus = report.branchStatus {
          Label(
            branchStatus.isDetached
              ? "Detached HEAD"
              : (branchStatus.branchName ?? String(localized: "未识别分支")),
            systemImage: "arrow.triangle.branch"
          )
            .foregroundStyle(.secondary)
          Label(branchStatus.upstreamName ?? "未设置 upstream", systemImage: "arrow.up.arrow.down")
            .foregroundStyle(.secondary)
        }
        if let remote = report.originRemote {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(
              "\(remote.provider.localizedDisplayName) \(remote.owner)/\(remote.name)",
              systemImage: "point.3.connected.trianglepath.dotted"
            )
              .foregroundStyle(.secondary)
            Text(remote.remoteURL)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .workbenchTruncatedIdentity(remote.remoteURL)
            Spacer()
            Button {
              store.applyDetectedRepositoryRemote()
            } label: {
              Label("用于 PR/MR", systemImage: "arrow.triangle.pull")
            }
          }
        }
      }
    } else {
      EmptyStateView(
        title: "扫描后将显示仓库概况",
        message: "这里会汇总站点类型、内容目录、图片目录和 Git 状态。",
        systemImage: "list.bullet.clipboard",
        density: .inline
      )
      .padding(.vertical, 8)
    }
  }

}
