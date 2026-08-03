import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var repositoryStageContent: some View {
    switch stage {
    case .overview:
      repositoryOverviewLayout
    case .changes:
      repositoryScanProgress
      remoteChangedFiles
      changedFiles
    case .source:
      EmptyView()
    case .history:
      ReleaseHistoryDetailView(store: store)
    }
  }

  var hasSelectedRepository: Bool {
    !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  var repositoryPrimaryActions: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("常用操作")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)
        Text("仓库管理与发布入口始终显示；实际写入和线上发布仍在统一发布流程中确认。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)],
        alignment: .leading,
        spacing: 10
      ) {
        Button {
          chooseRepository()
        } label: {
          Label(
            hasSelectedRepository ? String(localized: "更换仓库") : String(localized: "选择站点文件夹"),
            systemImage: "folder"
          )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(
          store.repository.scanState.isScanning
            || store.isLocalRepositoryBranchOperationRunning
        )
        .accessibilityIdentifier("repository-action-select-folder")

        if store.repository.scanState.isScanning {
          Button {
            store.repository.cancelScan()
          } label: {
            Label("取消扫描", systemImage: "xmark.circle")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("repository-action-scan")
        } else {
          Button {
            scanRepository()
          } label: {
            Label(
              hasSelectedRepository ? String(localized: "重新扫描") : String(localized: "扫描仓库"),
              systemImage: "arrow.clockwise"
            )
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .disabled(
            !hasSelectedRepository
              || store.isLocalRepositoryBranchOperationRunning
          )
          .help(
            store.isLocalRepositoryBranchOperationRunning
              ? String(localized: "正在处理分支")
              : (
                hasSelectedRepository
                  ? String(localized: "重新读取仓库结构、Git 状态和文件变化")
                  : String(localized: "请先选择站点文件夹")
              )
          )
          .accessibilityIdentifier("repository-action-scan")
        }

        Button {
          Task {
            await store.importDraftsFromLocalRepositoryAsync()
          }
        } label: {
          Label("导入文章", systemImage: "tray.and.arrow.down")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(
          !hasSelectedRepository
            || store.repository.scanState.isScanning
            || store.isLocalRepositoryBranchOperationRunning
        )
        .help(
          hasSelectedRepository
            ? String(localized: "将仓库中的文章导入写作列表")
            : String(localized: "请先选择站点文件夹")
        )
        .accessibilityIdentifier("repository-action-import")

        Button {
          isContentMigrationPresented = true
        } label: {
          Label("内容迁移", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("repository-action-migrate")

        Button {
          store.selectSection(.images)
        } label: {
          Label("图片资源", systemImage: "photo.on.rectangle")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help("管理站点图片、问题引用与批量优化")
        .accessibilityIdentifier("repository-action-open-images")

        Button {
          openUnifiedPublishFlow()
        } label: {
          Label("打开发布流程", systemImage: "paperplane")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .workbenchProminentActionStyle()
        .disabled(store.selectedDraft == nil)
        .help(store.selectedDraft == nil ? "请先选择一篇文章" : "检查并选择保存到本地或发布上线")
        .accessibilityIdentifier("repository-action-open-publish")
      }
      .controlSize(.regular)
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-primary-actions")
  }

  var repositoryOverviewLayout: some View {
    // Keep one stable layout tree while the native Inspector split item is
    // collapsing or expanding. ViewThatFits measured two complete repository
    // dashboards and could enter an AppKit/SwiftUI layout feedback loop.
    LazyVGrid(
      columns: [
        GridItem(
          .adaptive(minimum: 460, maximum: 720),
          spacing: 16,
          alignment: .top
        ),
      ],
      alignment: .leading,
      spacing: 16
    ) {
      repositoryOverviewPrimaryColumn
        .frame(maxWidth: .infinity, alignment: .topLeading)
      repositoryOverviewContextColumn
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var repositoryOverviewPrimaryColumn: some View {
    VStack(alignment: .leading, spacing: 16) {
      repositoryScanProgress
      repositorySummary
      repositoryProblemsSection
      onlinePublishCenterSection
      repositoryAutoSyncSection
    }
  }

  private var repositoryOverviewContextColumn: some View {
    VStack(alignment: .leading, spacing: 16) {
      repositoryInformationSection
      RepositoryWorkspaceGitManagementSection(store: store)
      repositoryOverviewLocalPreviewSection
      repositoryOverviewSyncPlanSection
      pathRules
    }
  }

  @ViewBuilder
  private var repositoryOverviewLocalPreviewSection: some View {
    if store.localSitePreviewPlan != nil {
      localPreviewSection
    } else {
      repositoryUnavailableToolCard(
        title: "本地预览",
        detail: "尚未识别可用的本地预览命令。请先扫描仓库，或在站点配置中补充预览设置。",
        systemImage: "play.rectangle",
        identifier: "repository-section-local-preview"
      )
    }
  }

  @ViewBuilder
  private var repositoryOverviewSyncPlanSection: some View {
    if store.repositorySyncCommandPlan != nil {
      repositorySyncPlan
    } else {
      repositoryUnavailableToolCard(
        title: "同步建议",
        detail: "尚未生成同步建议。请先扫描仓库，并确认当前分支已经设置 upstream。",
        systemImage: "arrow.triangle.2.circlepath",
        identifier: "repository-section-sync-plan"
      )
    }
  }

  private func repositoryUnavailableToolCard(
    title: LocalizedStringKey,
    detail: LocalizedStringKey,
    systemImage: String,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }

  @ViewBuilder
  var repositoryWorkflowBanner: some View {
    if !hasSelectedRepository {
      workflowBanner(
        title: "先选择站点文件夹",
        detail: "请选择保存网站文章和图片的文件夹。",
        systemImage: "externaldrive.badge.questionmark",
        tint: WorkbenchTheme.warning,
        actionTitle: "选择站点文件夹",
        action: chooseRepository
      )
    } else if store.repository.scanState.isScanning {
      workflowBanner(
        title: "正在扫描仓库",
        detail: LocalizedStringKey(store.repository.scanState.message),
        systemImage: "arrow.clockwise",
        tint: .secondary,
        actionTitle: "取消扫描",
        action: store.repository.cancelScan
      )
    } else if let report = store.repositoryReport,
              let issue = report.preflightIssues.first(where: { $0.severity == .error }) {
      workflowBanner(
        title: "需要先处理：\(issue.title)",
        detail: LocalizedStringKey(issue.message),
        systemImage: "xmark.octagon",
        tint: WorkbenchTheme.risk,
        actionTitle: "打开发布规则",
        action: openPublishingRulesSettings
      )
    } else if let report = store.repositoryReport, !report.remoteChangedFiles.isEmpty {
      workflowBanner(
        title: "网站上有 \(report.remoteChangedFiles.count) 个更新",
        detail: "先查看这些更新，避免覆盖其他设备或网站上的新内容。",
        systemImage: "arrow.down.doc",
        tint: WorkbenchTheme.warning,
        actionTitle: "查看文件变更",
        action: { stage = .changes }
      )
    } else if let report = store.repositoryReport, !report.changedFiles.isEmpty {
      workflowBanner(
        title: "这台 Mac 上有 \(report.changedFiles.count) 个文件变化",
        detail: "可以先确认变化内容，再决定保存到本地或发布上线。",
        systemImage: "arrow.triangle.2.circlepath",
        tint: WorkbenchTheme.warning,
        actionTitle: "查看文件变更",
        action: { stage = .changes }
      )
    } else if store.repositoryReport == nil {
      workflowBanner(
        title: "还没有读取站点文件",
        detail: "扫描只会检查文件和同步状态，不会修改任何内容。",
        systemImage: "arrow.clockwise",
        tint: .secondary,
        actionTitle: "扫描站点",
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
        title: "可以继续保存或发布",
        detail: "打开发布流程后，只需选择“保存到本地”或“发布上线”。",
        systemImage: "paperplane",
        tint: WorkbenchTheme.success,
        actionTitle: "打开发布",
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

  var repositoryGettingStartedGuide: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("第一次使用，只需三步")
        .font(.workbenchSectionTitle)

      repositoryOnboardingStep(
        number: 1,
        title: "选择站点文件夹",
        detail: "选择保存网站文章和图片的文件夹。"
      )
      repositoryOnboardingStep(
        number: 2,
        title: "检查文件变化",
        detail: "软件会读取同步状态，不会自动修改文件。"
      )
      repositoryOnboardingStep(
        number: 3,
        title: "保存或发布",
        detail: "选择文章后，可以只保存到本地，也可以直接发布上线。"
      )
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
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
        "选择保存到本地或发布上线；需要时再展开检查结果和文件差异。"
      )
    } else {
      store.runPreflight()
      store.setPublishActionMessage(String(localized: "请从顶部发布状态打开统一发布流程。"))
    }
  }

  func workflowBanner(
    title: LocalizedStringKey,
    detail: LocalizedStringKey,
    systemImage: String,
    tint: Color,
    actionTitle: LocalizedStringKey,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("下一步")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) {
          workflowBannerMessage(
            title: title,
            detail: detail,
            systemImage: systemImage,
            tint: tint
          )
          Spacer(minLength: 12)
          Button(action: action) {
            Text(actionTitle)
          }
          .workbenchProminentActionStyle()
        }

        VStack(alignment: .leading, spacing: 12) {
          workflowBannerMessage(
            title: title,
            detail: detail,
            systemImage: systemImage,
            tint: tint
          )
          Button(action: action) {
            Text(actionTitle)
              .frame(maxWidth: .infinity)
          }
          .workbenchProminentActionStyle()
        }
      }
    }
    .padding(16)
    .background(tint.opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前状态和下一步")
    .accessibilityIdentifier("repository-next-action")
  }

  private func workflowBannerMessage(
    title: LocalizedStringKey,
    detail: LocalizedStringKey,
    systemImage: String,
    tint: Color
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .font(.title2)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  func chooseRepository() {
    guard !store.isLocalRepositoryBranchOperationRunning else { return }
    guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
    Task {
      await store.repository.rememberRootAsync(url)
    }
  }

  func scanRepository() {
    guard !store.isLocalRepositoryBranchOperationRunning else { return }
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
      let blockingIssueCount = report.preflightIssues.filter { $0.severity == .error }.count

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("同步概况")
            .font(.workbenchSectionTitle)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          Label(report.syncStatusTitle, systemImage: "arrow.up.arrow.down")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
        }

        LazyVGrid(columns: repositoryMetricGridColumns, spacing: 10) {
          MetricTile(title: "本地变化", value: "\(report.changedFiles.count)", systemImage: "desktopcomputer")
          MetricTile(title: "网站更新", value: "\(report.remoteChangedFiles.count)", systemImage: "arrow.down.doc")
          MetricTile(title: "需要处理", value: "\(blockingIssueCount)", systemImage: blockingIssueCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-summary")
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

  @ViewBuilder
  var repositoryInformationSection: some View {
    if let report = store.repositoryReport {
      VStack(alignment: .leading, spacing: 10) {
        Label("仓库信息", systemImage: "externaldrive")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)

        let rootDisplayText = repositoryRootDisplayText(for: report)
        Text(rootDisplayText)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .workbenchTruncatedIdentity(rootDisplayText, lineLimit: 2)

        Label(report.detectedKind?.localizedDisplayName ?? String(localized: "未识别"), systemImage: "globe")
        Label("Markdown \(report.markdownFileCount) · 图片 \(report.imageFileCount)", systemImage: "doc.on.doc")

        if let branchStatus = report.branchStatus {
          Label(
            branchStatus.isDetached
              ? "Detached HEAD"
              : (branchStatus.branchName ?? String(localized: "未识别分支")),
            systemImage: "arrow.triangle.branch"
          )
          Label(
            branchStatus.upstreamName ?? String(localized: "未设置 upstream"),
            systemImage: "arrow.up.arrow.down"
          )
        }

        if let remote = report.originRemote {
          Divider()
          Label(
            "\(remote.provider.localizedDisplayName) \(remote.owner)/\(remote.name)",
            systemImage: "point.3.connected.trianglepath.dotted"
          )
          Text(remote.remoteURL)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(remote.remoteURL, lineLimit: 2)
          Button {
            store.applyDetectedRepositoryRemote()
          } label: {
            Label("用于线上发布", systemImage: "paperplane")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
        }
      }
      .font(.callout)
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-information")
    }
  }

  private func repositoryRootDisplayText(for report: RepositoryScanReport) -> String {
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    if ScreenshotDemoDataService.isEnabledFromEnvironment {
      return "示例仓库（隔离演示数据）"
    }
#endif
    return report.rootPath.isEmpty ? String(localized: "未选择仓库") : report.rootPath
  }

  @ViewBuilder
  var repositoryProblemsSection: some View {
    if let report = store.repositoryReport, !report.preflightIssues.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Label("需要处理", systemImage: "checklist")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)

        ForEach(report.preflightIssues) { issue in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity.publishDrawerSystemImage)
              .foregroundStyle(issue.severity.publishDrawerColor)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.title)
                .font(.callout.weight(.medium))
              Text(issue.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-problems")
    }
  }

  func repositoryOnboardingStep(
    number: Int,
    title: LocalizedStringKey,
    detail: LocalizedStringKey
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(WorkbenchTheme.navigationSelection, in: Circle())
        .accessibilityLabel("第 \(number) 步")
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  func openPublishingRulesSettings() {
    requestedSettingsTabID = SettingsTab.defaultRules.id
    openSettings()
  }

}
