import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  var onlinePublishCenterSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      if prioritizesPublishPreviewForScreenshot {
        repositoryPublishPreviewSection
        repositoryPublishManagementSection
      } else {
        repositoryPublishManagementSection
        repositoryPublishPreviewSection
      }
    }
  }

  private var prioritizesPublishPreviewForScreenshot: Bool {
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    ScreenshotDemoDataService.isEnabledFromEnvironment
      && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .syncAPIPublish
#else
    false
#endif
  }

  private var repositoryPublishManagementSection: some View {
    let latestEntry = store.activeProfileReleaseLedger.entries.first

    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("发布准备")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Text("刷新当前文章快照，检查远端权限，管理仓库与发布历史。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)],
        alignment: .leading,
        spacing: 10
      ) {
        Button {
          store.refreshPublishPreviewInBackground()
        } label: {
          Label("刷新发布快照", systemImage: "arrow.clockwise")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(
          store.selectedDraft == nil
            || store.isRemoteRepositoryChecking
            || store.isRemoteRepositoryPublishing
        )
        .help(store.selectedDraft == nil ? "选择文章后可生成发布快照" : "重新生成当前文章的发布快照")
        .accessibilityIdentifier("repository-action-refresh-publish-preview")

        Button {
          isConflictResolverPresented = true
        } label: {
          Label("Git 冲突消解器", systemImage: "arrow.triangle.merge")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help("调起双栏可视化 Git 冲突对比与一键消解器")

        Button {
          Task {
            await store.checkRepositoryTokenAccess()
            store.refreshPublishPreviewInBackground()
          }
        } label: {
          Label("检查权限", systemImage: "person.badge.key")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing)
        .accessibilityIdentifier("repository-action-check-permission")

        Button {
          createsPrivateRepository = true
          repositoryCreationFailureMessage = nil
          isRepositoryCreationConfirmationPresented = true
        } label: {
          Label("创建仓库", systemImage: "plus.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing)
        .accessibilityIdentifier("repository-action-create-remote")

        Button {
          stage = .history
        } label: {
          Label("查看发布记录", systemImage: "clock.arrow.circlepath")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("repository-action-view-release-history")
      }
      .controlSize(.regular)

      repositoryPublishAvailabilityNotice

      if store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(store.isRemoteRepositoryPublishing ? "正在执行线上发布..." : "正在检查仓库权限...")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      if let result = store.remoteRepositoryPublishResult {
        remotePublishResultCard(result)
      }

      if let creation = store.remoteRepositoryCreationResult {
        remoteRepositoryCreationResultCard(creation)
      }

      if let latestEntry {
        Label("最近记录：\(latestEntry.status.localizedDisplayName)", systemImage: latestEntry.status.systemImage)
          .font(.callout)
          .foregroundStyle(ledgerStatusForeground(latestEntry.status))
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-online-publish")
  }

  @ViewBuilder
  private var repositoryPublishAvailabilityNotice: some View {
    if store.selectedDraft == nil {
      Label(
        "请先选择一篇文章。选择后可生成发布快照并进入发布流程；权限检查和创建仓库仍可使用。",
        systemImage: "doc.badge.questionmark"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    } else if store.remotePublishPreviewSnapshot == nil {
      Label(
        "当前文章尚未生成发布快照。请刷新快照；如仍失败，先检查权限和仓库设置。",
        systemImage: "exclamationmark.triangle"
      )
      .font(.callout)
      .foregroundStyle(WorkbenchTheme.warning)
    } else {
      Label("当前文章的发布快照已生成。", systemImage: "checkmark.circle")
        .font(.callout)
        .foregroundStyle(WorkbenchTheme.success)
    }
  }

  private var repositoryPublishPreviewSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("当前文章发布快照")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)

        if let preview = store.remotePublishPreviewSnapshot {
          Text("\(preview.provider.localizedDisplayName) API · \(preview.mode.localizedDisplayName) · \(preview.repositoryName)")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          Text("生成快照后，这里会显示目标分支、文件清单、权限和发布检查。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      if let preview = store.remotePublishPreviewSnapshot {
        LazyVGrid(columns: repositoryMetricGridColumns, spacing: 10) {
          MetricTile(title: "状态", value: preview.readiness.localizedDisplayName, systemImage: preview.readiness.systemImage)
          MetricTile(title: "权限", value: preview.accessSummary, systemImage: preview.hasToken ? "person.badge.key" : "key")
          MetricTile(title: "目标", value: preview.targetBranch, systemImage: "arrow.down.to.line")
          MetricTile(title: "文件", value: "\(preview.changedPaths.count)", systemImage: "shippingbox")
        }

        Button {
          copy(preview.checklistMarkdown, message: "已复制线上发布核对包。")
        } label: {
          Label("复制核对包", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityIdentifier("repository-action-copy-checklist")

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          GridRow {
            Text("发布分支").foregroundStyle(.secondary)
            Text(preview.branchName)
              .font(.callout.monospaced())
              .workbenchTruncatedIdentity(preview.branchName)
          }
          GridRow {
            Text("仓库").foregroundStyle(.secondary)
            Text(preview.repositoryName)
              .font(.callout.monospaced())
              .workbenchTruncatedIdentity(preview.repositoryName)
          }
        }

        let blockingIssues = preview.blockingIssues
        let warningIssues = preview.warningIssues
        if preview.readiness == .ready && warningIssues.isEmpty {
          Label("线上 API 发布准备就绪。", systemImage: "checkmark.seal")
            .font(.callout)
            .foregroundStyle(WorkbenchTheme.success)
        } else if blockingIssues.isEmpty && warningIssues.isEmpty {
          repositoryPublishReadinessNotice(preview)
        } else {
          repositoryPublishIssueList(
            blockingIssues: blockingIssues,
            warningIssues: warningIssues
          )
        }

        if !preview.changedPaths.isEmpty {
          let changedPaths = preview.changedPaths.prefix(6).joined(separator: "\n")
          Text(changedPaths)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(changedPaths, lineLimit: 6)
        }

        if !preview.remoteConflictPaths.isEmpty {
          remoteConflictPreview(
            paths: preview.remoteConflictPaths,
            isDirectCommit: preview.mode == .directCommit
          )
        }
      } else if store.selectedDraft == nil {
        Label("尚未选择文章。", systemImage: "doc.badge.questionmark")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Label("等待生成发布快照。", systemImage: "clock")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-publish-preview")
  }

  @ViewBuilder
  var repositorySyncPlan: some View {
    if let plan = store.repositorySyncCommandPlan {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("同步建议")
              .font(.headline)
              .accessibilityAddTraits(.isHeader)
            Text(plan.title)
              .font(.callout.weight(.medium))
          }
          Spacer()
          Button {
            copy(plan.commandText, message: "已复制同步建议命令。")
          } label: {
            Label("复制命令", systemImage: "terminal")
          }
        }

        Text(plan.summary)
          .font(.callout)
          .foregroundStyle(.secondary)

        Text(plan.commandText)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .lineLimit(8)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

        ForEach(plan.notes, id: \.self) { note in
          Label(note, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-sync-plan")
    }
  }

  var pathRules: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("路径规则")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      repositoryPathRule(title: "内容目录", value: store.activeProfile.contentRoot)
      repositoryPathRule(title: "图片目录", value: store.activeProfile.assetRoot)
      repositoryPathRule(
        title: "文章路径",
        value: store.selectedDraft.map { store.activeProfile.markdownPath(for: $0) } ?? "-"
      )
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-path-rules")
  }

  private func repositoryPathRule(title: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .workbenchTruncatedIdentity(value, lineLimit: 2)
    }
  }

  func remotePublishResultCard(_ result: RemoteRepositoryPublishResult) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("线上发布结果", systemImage: "checkmark.seal")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(result.clipboardSummary, message: "已复制线上发布结果。")
        } label: {
          Label("复制结果", systemImage: "doc.on.doc")
        }
        if let reviewURL = result.reviewURL, let url = URL(string: reviewURL) {
          Button {
            ExternalURLOpener.open(url)
          } label: {
            Label("打开 PR/MR", systemImage: "arrow.up.right.square")
          }
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        GridRow {
          Text("方式").foregroundStyle(.secondary)
          Text(result.displayTitle)
        }
        GridRow {
          Text("分支").foregroundStyle(.secondary)
          Text(result.branchSummary)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        if let repositoryName = result.repositoryName {
          GridRow {
            Text("仓库").foregroundStyle(.secondary)
            Text(repositoryName)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        if let commitSHA = result.commitSHA {
          GridRow {
            Text("Commit").foregroundStyle(.secondary)
            HStack(spacing: 8) {
              Text(result.shortCommitSHA ?? commitSHA)
                .font(.caption.monospaced())
                .textSelection(.enabled)
              Button {
                copy(commitSHA, message: "已复制 commit SHA。")
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help("复制 commit SHA")
              .accessibilityLabel("复制 Commit SHA")
              .accessibilityValue(commitSHA)
            }
          }
        }
        if let reviewURL = result.reviewURL {
          GridRow {
            Text("PR/MR").foregroundStyle(.secondary)
            Text(reviewURL)
              .font(.caption.monospaced())
              .workbenchTruncatedIdentity(reviewURL)
          }
        }
      }
      .font(.caption)

      if !result.changedPaths.isEmpty {
        let changedPaths = result.changedPaths.prefix(6).joined(separator: "\n")
        Text(changedPaths)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(changedPaths, lineLimit: 6)
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func remoteRepositoryCreationResultCard(_ result: RemoteRepositoryCreationResult) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("远端仓库已创建", systemImage: "checkmark.circle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.success)
        Spacer()
        if let urlText = result.htmlURL ?? result.cloneURL, let url = URL(string: urlText) {
          Button {
            ExternalURLOpener.open(url)
          } label: {
            Label("打开仓库", systemImage: "arrow.up.right.square")
          }
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        GridRow {
          Text("仓库").foregroundStyle(.secondary)
          Text(result.repositoryName)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        if let defaultBranch = result.defaultBranch {
          GridRow {
            Text("默认分支").foregroundStyle(.secondary)
            Text(defaultBranch)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        GridRow {
          Text("可见性").foregroundStyle(.secondary)
          Text(result.privateRepository ? "私有" : "公开")
        }
        if let htmlURL = result.htmlURL ?? result.cloneURL {
          GridRow {
            Text("URL").foregroundStyle(.secondary)
            Text(htmlURL)
              .font(.caption.monospaced())
              .workbenchTruncatedIdentity(htmlURL)
          }
        }
      }
      .font(.caption)
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func remoteConflictPreview(paths: [String], isDirectCommit: Bool) -> some View {
    let title: LocalizedStringKey = isDirectCommit
      ? "远端冲突会阻断直接提交"
      : "远端冲突预览"
    let detail: LocalizedStringKey = isDirectCommit
      ? "先同步这些 upstream 变更，或切换为 PR/MR 发布。"
      : "这些路径在 upstream 也有变更，合并前需要审阅远端 diff。"

    return VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: "arrow.triangle.2.circlepath")
        .font(.workbenchCardTitle)
        .foregroundStyle(isDirectCommit ? WorkbenchTheme.risk : WorkbenchTheme.warning)

      Text(detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .lineSpacing(1)

      ForEach(paths.prefix(6), id: \.self) { path in
        WorkbenchPathIdentity(path: path)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((isDirectCommit ? WorkbenchTheme.risk : WorkbenchTheme.warning).opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  @ViewBuilder
  private func repositoryPublishIssueList(
    blockingIssues: [PreflightIssue],
    warningIssues: [PreflightIssue]
  ) -> some View {
    ForEach(blockingIssues) { issue in
      repositoryPublishIssueRow(issue)
    }

    if !warningIssues.isEmpty {
      Label("警告（\(warningIssues.count)）", systemImage: "exclamationmark.triangle")
        .font(.callout.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.warning)

      ForEach(warningIssues) { issue in
        repositoryPublishIssueRow(issue)
      }
    }
  }

  private func repositoryPublishIssueRow(_ issue: PreflightIssue) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
        .foregroundStyle(issue.severity == .error ? WorkbenchTheme.risk : WorkbenchTheme.warning)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title)
          .font(.callout.weight(.semibold))
        Text(issue.message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineSpacing(1)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
  }

  private func repositoryPublishReadinessNotice(
    _ preview: RemoteRepositoryPublishPreview
  ) -> some View {
    let message: LocalizedStringKey
    switch preview.readiness {
    case .ready:
      message = "线上 API 发布准备就绪。"
    case .needsToken:
      message = "请先保存仓库访问令牌，再检查写入权限。"
    case .needsPermissionCheck:
      message = "访问令牌已保存；请先检查仓库写入权限。"
    case .needsRemoteCheck:
      message = "远端快照待核对；直接提交会先通过 API 校验文件版本。"
    case .blocked:
      message = "当前仓库权限不足，暂不能线上发布。"
    }

    return Label(message, systemImage: preview.readiness.systemImage)
      .font(.callout)
      .foregroundStyle(preview.readiness == .blocked ? WorkbenchTheme.risk : WorkbenchTheme.warning)
  }

}
