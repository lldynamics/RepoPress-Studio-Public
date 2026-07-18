import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var onlinePublishCenterSection: some View {
    if store.selectedDraft != nil, let preview = store.remotePublishPreviewSnapshot {
      let latestEntry = store.activeProfileReleaseLedger.entries.first

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("线上发布中心")
              .font(.headline)
            Text("\(preview.provider.localizedDisplayName) API · \(preview.mode.localizedDisplayName) · \(preview.repositoryName)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            if let publishDrawerCommandAction {
              publishDrawerCommandAction.open(
                "已从发布中心进入统一发布流程，请确认检查、差异、写入方式、远端策略和部署状态。"
              )
            } else {
              store.runPreflight()
              store.setPublishActionMessage(String(localized: "请从顶部“发布”菜单打开统一发布流程。"))
            }
          } label: {
            Label("打开发布流程", systemImage: "paperplane")
          }
          .workbenchProminentActionStyle()
          .disabled(store.isRemoteRepositoryPublishing)

          Menu {
            Button {
              store.refreshPublishPreviewInBackground()
            } label: {
              Label("刷新发布快照", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing)

            Button {
              Task {
                await store.checkRepositoryTokenAccess()
                store.refreshPublishPreviewInBackground()
              }
            } label: {
              Label("检查权限", systemImage: "person.badge.key")
            }
            .disabled(store.isRemoteRepositoryChecking)

            Button {
              createsPrivateRepository = true
              repositoryCreationFailureMessage = nil
              isRepositoryCreationConfirmationPresented = true
            } label: {
              Label("创建仓库", systemImage: "plus.circle")
            }
            .disabled(store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing)

            Divider()

            Button {
              copy(preview.checklistMarkdown, message: "已复制线上发布核对包。")
            } label: {
              Label("复制核对包", systemImage: "doc.on.doc")
            }
          } label: {
            Label(String(localized: "更多"), systemImage: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }

        LazyVGrid(columns: repositoryMetricGridColumns, spacing: 10) {
          MetricTile(title: "状态", value: preview.readiness.localizedDisplayName, systemImage: preview.readiness.systemImage)
          MetricTile(title: "权限", value: preview.accessSummary, systemImage: preview.hasToken ? "person.badge.key" : "key")
          MetricTile(title: "目标", value: preview.targetBranch, systemImage: "arrow.down.to.line")
          MetricTile(title: "文件", value: "\(preview.changedPaths.count)", systemImage: "shippingbox")
        }

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

        if store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(store.isRemoteRepositoryPublishing ? "正在执行线上发布..." : "正在检查仓库权限...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        let blockingIssues = preview.blockingIssues
        let warningIssues = preview.warningIssues
        if preview.readiness == .ready && warningIssues.isEmpty {
          Label("线上 API 发布准备就绪。", systemImage: "checkmark.seal")
            .font(.caption)
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
          remoteConflictPreview(paths: preview.remoteConflictPaths, isDirectCommit: preview.mode == .directCommit)
        }

        if let result = store.remoteRepositoryPublishResult {
          remotePublishResultCard(result)
        }

        if let creation = store.remoteRepositoryCreationResult {
          remoteRepositoryCreationResultCard(creation)
        }

        HStack {
          Button {
            stage = .history
          } label: {
            Label("查看发布记录", systemImage: "clock.arrow.circlepath")
          }
          if let latestEntry {
            Label("最近：\(latestEntry.status.localizedDisplayName)", systemImage: latestEntry.status.systemImage)
              .font(.caption)
              .foregroundStyle(ledgerStatusForeground(latestEntry.status))
          }
        }
        .controlSize(.small)
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  @ViewBuilder
  var repositorySyncPlan: some View {
    if let plan = store.repositorySyncCommandPlan {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("同步建议")
              .font(.headline)
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  var pathRules: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("路径规则")
        .font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
        GridRow {
          Text("内容目录").foregroundStyle(.secondary)
          Text(store.activeProfile.contentRoot).font(.callout.monospaced())
        }
        GridRow {
          Text("图片目录").foregroundStyle(.secondary)
          Text(store.activeProfile.assetRoot).font(.callout.monospaced())
        }
        GridRow {
          Text("文章路径").foregroundStyle(.secondary)
          Text(store.selectedDraft.map { store.activeProfile.markdownPath(for: $0) } ?? "-")
            .font(.callout.monospaced())
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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

  func batchOnlinePublishPreview(_ preview: RemoteRepositoryPublishPreview) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("批量线上预览")
            .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          let repositorySummary = "\(preview.provider.localizedDisplayName) API · \(preview.mode.localizedDisplayName) · \(preview.repositoryName)"
          Text(repositorySummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(repositorySummary)
        }
        Spacer()
        Label(preview.readiness.localizedDisplayName, systemImage: preview.readiness.systemImage)
          .font(.caption.weight(.medium))
        Button {
          copy(preview.checklistMarkdown, message: "已复制批量线上发布核对包。")
        } label: {
          Label("复制核对包", systemImage: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("复制线上发布核对包")
        .accessibilityLabel("复制批量线上发布核对包")
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        GridRow {
          Text("权限").foregroundStyle(.secondary)
          Text(preview.accessSummary)
        }
        GridRow {
          Text("分支").foregroundStyle(.secondary)
          Text("\(preview.branchName) -> \(preview.targetBranch)")
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        GridRow {
          Text("文件").foregroundStyle(.secondary)
          Text("\(preview.changedPaths.count) 个")
        }
      }
      .font(.caption)

      let blockingIssues = preview.blockingIssues
      let warningIssues = preview.warningIssues
      if preview.readiness == .ready && warningIssues.isEmpty {
        Label("批量线上 API 发布准备就绪。", systemImage: "checkmark.seal")
          .font(.caption)
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
        let changedPaths = preview.changedPaths.prefix(5).joined(separator: "\n")
        Text(changedPaths)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(changedPaths, lineLimit: 5)
      }

      if !preview.remoteConflictPaths.isEmpty {
        remoteConflictPreview(paths: preview.remoteConflictPaths, isDirectCommit: preview.mode == .directCommit)
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func remoteConflictPreview(paths: [String], isDirectCommit: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(isDirectCommit ? "远端冲突会阻断直接提交" : "远端冲突预览", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption.weight(.semibold))
        .foregroundStyle(isDirectCommit ? WorkbenchTheme.risk : WorkbenchTheme.warning)

      Text(isDirectCommit ? "先同步这些 upstream 变更，或切换为 PR/MR 发布。" : "这些路径在 upstream 也有变更，合并前需要审阅远端 diff。")
        .font(.caption)
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
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(warningIssues) { issue in
            repositoryPublishIssueRow(issue)
          }
        }
        .padding(.top, 5)
      } label: {
        Label("警告（\(warningIssues.count)）", systemImage: "exclamationmark.triangle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)
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
          .font(.caption.weight(.semibold))
        Text(issue.message)
          .font(.caption)
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
    let message: String
    switch preview.readiness {
    case .ready:
      message = "线上 API 发布准备就绪。"
    case .needsToken:
      message = "请先保存仓库访问令牌，再检查写入权限。"
    case .needsPermissionCheck:
      message = "访问令牌已保存；请先检查仓库写入权限。"
    case .needsRemoteCheck:
      message = String(localized: "远端快照待核对；直接提交会先通过 API 校验文件版本。")
    case .blocked:
      message = "当前仓库权限不足，暂不能线上发布。"
    }

    return Label(message, systemImage: preview.readiness.systemImage)
      .font(.caption)
      .foregroundStyle(preview.readiness == .blocked ? WorkbenchTheme.risk : WorkbenchTheme.warning)
      .accessibilityLabel("线上发布状态：\(message)")
  }

}
