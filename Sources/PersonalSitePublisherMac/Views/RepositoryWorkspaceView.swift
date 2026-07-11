import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorkspaceView: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var stage: RepositoryContextStage
  @State var isLocalPreviewPresented = false
  @State var isContentMigrationPresented = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("本地仓库")
              .font(.title2.weight(.semibold))
            Text("只做文章发布需要的 Git：路径规则、diff 摘要和发布准备。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          if hasSelectedRepository {
            repositoryActionsMenu
          }
        }

        repositoryWorkflowBanner

        if hasSelectedRepository {
          if store.repositoryReport != nil || stage == .overview {
            repositoryStageContent
          } else {
            repositoryScanRequiredState
          }
        } else {
          repositorySelectionEmptyState
        }
      }
      .padding(20)
    }
    .sheet(isPresented: $isLocalPreviewPresented) {
      LocalSitePreviewSheet(
        previewURL: store.localSitePreviewRuntimeStatus.previewURL ?? store.localSitePreviewPlan?.previewURL
      )
    }
    .sheet(isPresented: $isContentMigrationPresented) {
      ContentMigrationAssistantView(store: store)
    }
  }

  @ViewBuilder
  private var repositoryStageContent: some View {
    switch stage {
    case .overview:
      repositorySummary
      repositoryScanProgress
      repositorySyncPlan
    case .changes:
      remoteChangedFiles
      changedFiles
      pathRules
    case .publishing:
      publishPackageSummary
      publishDiffPreview
      batchPublishQueueSection
      onlinePublishCenterSection
      reviewRequestSection
    case .automation:
      repositoryAutoSyncSection
    case .preview:
      localPreviewSection
    }
  }

  private var hasSelectedRepository: Bool {
    !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  private var repositoryActionsMenu: some View {
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
  private var repositoryWorkflowBanner: some View {
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
        detail: "下一步确认发布包、写入策略和线上发布方式。",
        systemImage: "paperplane",
        tint: WorkbenchTheme.success,
        actionTitle: "写入与发布",
        action: { stage = .publishing }
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

  private var repositorySelectionEmptyState: some View {
    EmptyStateView(
      title: "选择仓库后继续",
      message: "变更、写入与发布、自动化和本地预览会在仓库选定后按需显示。",
      systemImage: "externaldrive.badge.plus"
    )
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  private var repositoryScanRequiredState: some View {
    EmptyStateView(
      title: "扫描仓库后继续",
      message: "先完成一次仓库扫描，才会显示变更、写入与发布、自动化和本地预览模块。",
      systemImage: "arrow.clockwise.circle"
    )
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  private func workflowBanner(
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
      .buttonStyle(.borderedProminent)
    }
    .padding(12)
    .background(tint.opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前同步阻断与下一步")
  }

  private func chooseRepository() {
    guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
    Task {
      await store.repository.rememberRootAsync(url)
    }
  }

  private func scanRepository() {
    Task {
      await store.repository.scanAsync()
    }
  }

  @ViewBuilder
  private var repositoryScanProgress: some View {
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
  private var repositorySummary: some View {
    if let report = store.repositoryReport {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        MetricTile(title: "仓库状态", value: report.statusTitle, systemImage: "externaldrive")
        MetricTile(title: "同步", value: report.syncStatusTitle, systemImage: "arrow.up.arrow.down")
        MetricTile(title: "Markdown", value: "\(report.markdownFileCount)", systemImage: "doc.text")
        MetricTile(title: "图片", value: "\(report.imageFileCount)", systemImage: "photo")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(report.rootPath.isEmpty ? "未选择仓库" : report.rootPath)
          .font(.callout.monospaced())
          .textSelection(.enabled)
        Label(report.detectedKind?.displayName ?? "未识别", systemImage: "globe")
          .foregroundStyle(.secondary)
        if let branchStatus = report.branchStatus {
          Label(branchStatus.displayName, systemImage: "arrow.triangle.branch")
            .foregroundStyle(.secondary)
          Label(branchStatus.upstreamName ?? "未设置 upstream", systemImage: "arrow.up.arrow.down")
            .foregroundStyle(.secondary)
        }
        if let remote = report.originRemote {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(remote.displayName, systemImage: "point.3.connected.trianglepath.dotted")
              .foregroundStyle(.secondary)
            Text(remote.remoteURL)
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
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
        title: "还没有扫描结果",
        message: "选择仓库后会检查站点类型、内容目录、图片目录和 Git 状态。",
        systemImage: "externaldrive.badge.plus"
      )
      .frame(height: 240)
    }
  }

  @ViewBuilder
  private var onlinePublishCenterSection: some View {
    if store.selectedDraft != nil, let preview = store.remotePublishPreviewSnapshot {
      let latestEntry = store.activeProfileReleaseLedger.entries.first

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("线上发布中心")
              .font(.headline)
            Text("\(preview.provider.displayName) API · \(preview.mode.displayName) · \(preview.repositoryName)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            store.refreshPublishPreview()
          } label: {
            Label("刷新发布快照", systemImage: "arrow.clockwise")
          }
          .disabled(store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing)

          Button {
            Task {
              await store.checkRepositoryTokenAccess()
              store.refreshPublishPreview()
            }
          } label: {
            Label("检查权限", systemImage: "person.badge.key")
          }
          .disabled(store.isRemoteRepositoryChecking)

          Button {
            Task {
              await store.createRemoteRepositoryForActiveProfile(privateRepository: false)
              store.refreshPublishPreview()
            }
          } label: {
            Label("创建仓库", systemImage: "plus.circle")
          }
          .disabled(store.isRemoteRepositoryPublishing)

          Button {
            Task {
              await store.publishSelectedDraftOnlineUsingPreferredStrategy()
            }
          } label: {
            Label(preview.mode.displayName, systemImage: preview.mode == .directCommit ? "arrow.up.circle" : "arrow.triangle.pull")
          }
          .buttonStyle(.borderedProminent)
          .disabled(!preview.canPublish || store.isRemoteRepositoryPublishing)

          Button {
            copy(preview.checklistMarkdown, message: "已复制线上发布核对包。")
          } label: {
            Label("复制核对包", systemImage: "doc.on.doc")
          }
          if let accessCheck = preview.accessCheck {
            Button {
              copy(accessCheck.accessEvidenceMarkdown, message: "已复制仓库 Token 权限证据包。")
            } label: {
              Label("复制权限证据", systemImage: "checklist.checked")
            }
          }
        }

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
          MetricTile(title: "状态", value: preview.readiness.displayName, systemImage: preview.readiness.systemImage)
          MetricTile(title: "权限", value: preview.accessSummary, systemImage: preview.hasToken ? "person.badge.key" : "key")
          MetricTile(title: "目标", value: preview.targetBranch, systemImage: "arrow.down.to.line")
          MetricTile(title: "文件", value: "\(preview.changedPaths.count)", systemImage: "shippingbox")
        }

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          GridRow {
            Text("发布分支").foregroundStyle(.secondary)
            Text(preview.branchName)
              .font(.callout.monospaced())
              .lineLimit(1)
              .textSelection(.enabled)
          }
          GridRow {
            Text("仓库").foregroundStyle(.secondary)
            Text(preview.repositoryName)
              .font(.callout.monospaced())
              .lineLimit(1)
              .textSelection(.enabled)
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
        if blockingIssues.isEmpty && warningIssues.isEmpty {
          Label("线上 API 发布准备就绪。", systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.success)
        } else {
          ForEach((blockingIssues + warningIssues).prefix(5)) { issue in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                  .font(.caption.weight(.semibold))
                Text(issue.message)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
              }
              Spacer()
            }
          }
        }

        if !preview.changedPaths.isEmpty {
          Text(preview.changedPaths.prefix(6).joined(separator: "\n"))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(6)
            .textSelection(.enabled)
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
            store.selectSection(.releaseHistory)
          } label: {
            Label("查看发布记录", systemImage: "clock.arrow.circlepath")
          }
          if let latestEntry {
            Label("最近：\(latestEntry.status.displayName)", systemImage: latestEntry.status.systemImage)
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
  private var repositorySyncPlan: some View {
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

  private var pathRules: some View {
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

  private func remotePublishResultCard(_ result: RemoteRepositoryPublishResult) -> some View {
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
        Button {
          copy(result.remoteVerificationMarkdown, message: "已复制线上发布实测包。")
        } label: {
          Label("复制实测包", systemImage: "checklist.checked")
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
              .lineLimit(1)
              .textSelection(.enabled)
          }
        }
      }
      .font(.caption)

      if !result.changedPaths.isEmpty {
        Text(result.changedPaths.prefix(6).joined(separator: "\n"))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(6)
          .textSelection(.enabled)
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func remoteRepositoryCreationResultCard(_ result: RemoteRepositoryCreationResult) -> some View {
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
              .lineLimit(1)
              .textSelection(.enabled)
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
          Text("\(preview.provider.displayName) API · \(preview.mode.displayName) · \(preview.repositoryName)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Label(preview.readiness.displayName, systemImage: preview.readiness.systemImage)
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

      let issues = preview.blockingIssues + preview.warningIssues
      if issues.isEmpty {
        Label("批量线上 API 发布准备就绪。", systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
      } else {
        ForEach(issues.prefix(4)) { issue in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
              .foregroundStyle(issue.severity == .error ? .red : .orange)
              .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.title)
                .font(.caption.weight(.semibold))
              Text(issue.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
          }
        }
      }

      if !preview.changedPaths.isEmpty {
        Text(preview.changedPaths.prefix(5).joined(separator: "\n"))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(5)
          .textSelection(.enabled)
      }

      if !preview.remoteConflictPaths.isEmpty {
        remoteConflictPreview(paths: preview.remoteConflictPaths, isDirectCommit: preview.mode == .directCommit)
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func remoteConflictPreview(paths: [String], isDirectCommit: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(isDirectCommit ? "远端冲突会阻断直接提交" : "远端冲突预览", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption.weight(.semibold))
        .foregroundStyle(isDirectCommit ? .red : .orange)

      Text(isDirectCommit ? "先同步这些 upstream 变更，或切换为 PR/MR 发布。" : "这些路径在 upstream 也有变更，合并前需要审阅远端 diff。")
        .font(.caption2)
        .foregroundStyle(.secondary)

      ForEach(paths.prefix(6), id: \.self) { path in
        Text(path)
          .font(.caption2.monospaced())
          .lineLimit(1)
          .textSelection(.enabled)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((isDirectCommit ? WorkbenchTheme.risk : WorkbenchTheme.warning).opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  @ViewBuilder
  private var changedFiles: some View {
    if let report = store.repositoryReport {
      let summary = repositoryChangeSummary(for: report)
      let importableArticleCount = importableChangedArticleCount(for: report)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Diff 摘要")
            .font(.headline)
          Spacer()
          Button {
            store.importChangedArticleDraftsFromLocalRepository()
          } label: {
            Label("导入文章变更", systemImage: "tray.and.arrow.down")
          }
          .disabled(importableArticleCount == 0)
          .accessibilityLabel("导入本地文章变更")
          .accessibilityValue("\(importableArticleCount) 篇可导入")
          Text("\(summary.publishRelevantCount) 个发布相关变更")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("发布相关本地变更")
            .accessibilityValue("\(summary.publishRelevantCount) 个")
        }

        if summary.totalCount > 0 {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricTile(title: "文章", value: "\(summary.articleCount)", systemImage: "doc.text")
            MetricTile(title: "图片", value: "\(summary.imageCount)", systemImage: "photo")
            MetricTile(title: "配置", value: "\(summary.configurationCount)", systemImage: "gearshape")
            MetricTile(title: "其他", value: "\(summary.otherCount)", systemImage: "ellipsis")
          }
        }

        if report.changedFiles.isEmpty {
          Text("当前工作树没有变更。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(RepositoryChangedFileRole.allCases, id: \.self) { role in
            let files = report.changedFiles(
              role: role,
              contentRoot: store.activeProfile.contentRoot,
              assetRoot: store.activeProfile.assetRoot
            )

            if !files.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("\(role.displayName)变更")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)

                ForEach(files) { file in
                  VStack(alignment: .leading, spacing: 8) {
                    HStack {
                      Text(file.kind.displayName)
                        .font(.caption)
                        .frame(width: 58, alignment: .leading)
                        .foregroundStyle(.secondary)
                      Text(file.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                      Spacer()
                      Text(file.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("本地文件状态")
                        .accessibilityValue(file.status)
                    }

                    if let lineDiff = file.lineDiff {
                      Text(lineDiff)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(16)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
                        .accessibilityLabel("本地 diff 预览")
                        .accessibilityValue(file.path)
                    }
                  }
                  Divider()
                }
              }
            }
          }
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  private func repositoryChangeSummary(for report: RepositoryScanReport) -> RepositoryChangeSummary {
    report.changeSummary(
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
  }

  private func importableChangedArticleCount(for report: RepositoryScanReport) -> Int {
    report.changedFiles(
      role: .article,
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
    .filter { $0.kind != .deleted }
    .count
  }

  func copyReviewCommands() {
    let commands = store.reviewBranchCommandsForSelectedDraft()
    guard !commands.isEmpty else {
      store.setPublishActionMessage("选择本地仓库后才能生成分支发布命令。")
      return
    }
    copy(commands.joined(separator: "\n"), message: "已复制分支发布命令。")
  }

  func copyBatchCommitCommand() {
    guard let command = store.batchLocalCommitCommandForWritableDrafts() else {
      store.setPublishActionMessage("待发布队列没有可提交的文件。")
      return
    }
    copy(command, message: "已复制批量 git 提交命令。")
  }

  func copyBatchReviewBranchCommands() {
    let commands = store.batchReviewBranchCommandsForWritableDrafts()
    guard !commands.isEmpty else {
      store.setPublishActionMessage("待发布队列没有可创建分支的文件。")
      return
    }
    copy(commands.joined(separator: "\n"), message: "已复制批量分支发布命令。")
  }

  func copyBatchReviewDescription() {
    store.refreshBatchPublishPlan()
    guard let review = store.batchRemoteReviewDraft else {
      store.setPublishActionMessage("待发布队列没有可生成 PR/MR 描述的文章。")
      return
    }
    copy(review.body, message: "已复制批量 PR/MR 描述。")
  }

  func openReviewURL(_ review: RemoteReviewDraft) {
    guard let url = review.webURL else {
      store.setPublishActionMessage("填写仓库 owner/name 后才能打开 PR/MR 创建页。")
      return
    }
    ExternalURLOpener.open(url)
  }

  func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }

  private func ledgerStatusForeground(_ status: ReleaseLedgerStatus) -> AnyShapeStyle {
    switch status {
    case .succeeded:
      return AnyShapeStyle(.green)
    case .deploying, .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .pendingReview:
      return AnyShapeStyle(.orange)
    case .failed:
      return AnyShapeStyle(.red)
    case .localOnly, .unknown:
      return AnyShapeStyle(.secondary)
    }
  }
}
