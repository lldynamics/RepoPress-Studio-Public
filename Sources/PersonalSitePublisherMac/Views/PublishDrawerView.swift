import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerView: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var isPresented: Bool
  @State private var newBranchName = ""
  @State private var showAllCommits = false
  @State private var selectedStep: PublishDrawerFlowCard = .checks

  var body: some View {
    drawerContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      store.ensureEditableDraftSelected()
      store.runPreflight()
      if let draft = store.selectedDraft {
        store.refreshPublishPreview(for: draft)
        selectedStep = recommendedStep(for: publishFlowSteps(draft: draft))
      }
    }
  }

  @ViewBuilder
  private var drawerContent: some View {
    if let draft = store.selectedDraft {
      VStack(spacing: 0) {
        header(draft: draft)
        Divider()
        publishFlowStepper(draft: draft)
        Divider()
        publishStepContent(draft: draft)
        Divider()
        stepNavigation
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "paperplane")
          .font(.system(size: 30))
          .foregroundStyle(.secondary)
        Text("没有可发布文章")
          .font(.headline)
        Button("关闭") {
          isPresented = false
        }
        .accessibilityLabel("关闭发布流程")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(draft: ArticleDraft) -> some View {
    HStack(spacing: 12) {
      Label("发布", systemImage: "paperplane")
        .font(.headline)

      Text(draft.title)
        .font(.callout.weight(.medium))
        .lineLimit(1)

      Text(store.profile(for: draft).markdownPath(for: draft))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer()

      if let message = store.publishActionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Button {
        store.runPreflight()
        store.refreshPublishPreview(for: draft)
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .accessibilityLabel("刷新发布检查和 Diff")

      Button {
        isPresented = false
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("关闭发布流程")
      .accessibilityLabel("关闭发布流程")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("发布流程")
    .accessibilityValue("\(draft.title)，\(store.profile(for: draft).markdownPath(for: draft))")
  }

  private func publishFlowStepper(
    draft: ArticleDraft
  ) -> some View {
    let steps = publishFlowSteps(draft: draft)

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("发布流程", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
          .font(.caption.weight(.semibold))
        Text(publishFlowSummary(steps))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
      }

      Picker("发布步骤", selection: $selectedStep) {
        ForEach(PublishDrawerFlowCard.allCases) { step in
          Text(step.title).tag(step)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("发布步骤")
      .accessibilityValue(selectedStep.title)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("发布流程")
    .accessibilityValue(publishFlowSummary(steps))
  }

  @ViewBuilder
  private func publishStepContent(draft: ArticleDraft) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        switch selectedStep {
        case .checks:
          checkResultsCard(draft: draft)
        case .diff:
          diffCard(draft: draft)
        case .write:
          commitMethodCard(draft: draft)
          repositoryBranchCard
          commitHistoryCard
        case .remote:
          remotePublishPreviewCard(draft: draft)
          reviewDescriptionCard(draft: draft)
          remotePublishProgressCard
        case .deployment:
          deploymentStatusCard(draft: draft)
        }
      }
      .padding(16)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(selectedStep.title)步骤内容")
  }

  private var stepNavigation: some View {
    HStack {
      Button("上一步") {
        moveSelectedStep(by: -1)
      }
      .disabled(selectedStep == PublishDrawerFlowCard.allCases.first)

      Spacer()

      Text("步骤 \((PublishDrawerFlowCard.allCases.firstIndex(of: selectedStep) ?? 0) + 1) / \(PublishDrawerFlowCard.allCases.count)")
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      Button(selectedStep == PublishDrawerFlowCard.allCases.last ? "完成" : "下一步") {
        if selectedStep == PublishDrawerFlowCard.allCases.last {
          isPresented = false
        } else {
          moveSelectedStep(by: 1)
        }
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func moveSelectedStep(by offset: Int) {
    guard let index = PublishDrawerFlowCard.allCases.firstIndex(of: selectedStep) else {
      return
    }
    let target = index + offset
    guard PublishDrawerFlowCard.allCases.indices.contains(target) else {
      return
    }
    selectedStep = PublishDrawerFlowCard.allCases[target]
  }

  private func publishFlowSteps(draft: ArticleDraft) -> [PublishDrawerFlowStep] {
    let issues = store.preflightIssues(for: draft)
    let blockingCount = issues.filter { $0.severity == .error }.count
    let warningCount = issues.filter { $0.severity == .warning }.count
    let preview = store.localPublishPreview(for: draft)
    let changedCount = preview.changedFileDiffs.count
    let canWrite = store.localPublishReadiness?.canWrite == true
    let hasToken = store.repositoryTokenAvailability.hasToken

    if blockingCount > 0 {
      return [
        PublishDrawerFlowStep(
          title: "检查",
          detail: "\(blockingCount) 个阻断",
          systemImage: "xmark.octagon",
          state: .blocked
        ),
        PublishDrawerFlowStep(title: "Diff", detail: "等待检查通过", systemImage: "doc.text.magnifyingglass", state: .pending),
        PublishDrawerFlowStep(title: "写入", detail: "暂不可写入", systemImage: "square.and.arrow.down", state: .pending),
        PublishDrawerFlowStep(title: "远端", detail: "等待本地写入", systemImage: "arrow.up.circle", state: .pending),
        PublishDrawerFlowStep(title: "部署", detail: "等待发布", systemImage: "globe", state: .pending)
      ]
    }

    if changedCount == 0 {
      return [
        PublishDrawerFlowStep(
          title: "检查",
          detail: warningCount == 0 ? "已通过" : "\(warningCount) 个警告",
          systemImage: "checkmark.circle",
          state: .complete
        ),
        PublishDrawerFlowStep(title: "Diff", detail: "无待写入变化", systemImage: "equal.circle", state: .complete),
        PublishDrawerFlowStep(title: "写入", detail: "本地已同步", systemImage: "checkmark.seal", state: .complete),
        PublishDrawerFlowStep(
          title: "远端",
          detail: hasToken ? "可继续发布" : "需要 Token",
          systemImage: hasToken ? "arrow.up.circle" : "key",
          state: hasToken ? .active : .blocked
        ),
        PublishDrawerFlowStep(title: "部署", detail: "发布后跟踪", systemImage: "globe", state: .pending)
      ]
    }

    if !canWrite {
      return [
        PublishDrawerFlowStep(
          title: "检查",
          detail: warningCount == 0 ? "已通过" : "\(warningCount) 个警告",
          systemImage: "checkmark.circle",
          state: .complete
        ),
        PublishDrawerFlowStep(title: "Diff", detail: "\(changedCount) 个变化", systemImage: "doc.text.magnifyingglass", state: .complete),
        PublishDrawerFlowStep(title: "写入", detail: "准备状态不足", systemImage: "exclamationmark.triangle", state: .blocked),
        PublishDrawerFlowStep(title: "远端", detail: "等待本地写入", systemImage: "arrow.up.circle", state: .pending),
        PublishDrawerFlowStep(title: "部署", detail: "等待发布", systemImage: "globe", state: .pending)
      ]
    }

    return [
      PublishDrawerFlowStep(
        title: "检查",
        detail: warningCount == 0 ? "已通过" : "\(warningCount) 个警告",
        systemImage: "checkmark.circle",
        state: .complete
      ),
      PublishDrawerFlowStep(title: "Diff", detail: "\(changedCount) 个变化", systemImage: "doc.text.magnifyingglass", state: .complete),
      PublishDrawerFlowStep(title: "写入", detail: "下一步写入仓库", systemImage: "square.and.arrow.down", state: .active),
      PublishDrawerFlowStep(
        title: "远端",
        detail: hasToken ? "Token 已就绪" : "需要 Token",
        systemImage: hasToken ? "arrow.up.circle" : "key",
        state: hasToken ? .pending : .blocked
      ),
      PublishDrawerFlowStep(title: "部署", detail: "发布后跟踪", systemImage: "globe", state: .pending)
    ]
  }

  private func publishFlowSummary(_ steps: [PublishDrawerFlowStep]) -> String {
    if let blocked = steps.first(where: { $0.state == .blocked }) {
      return "阻断在 \(blocked.title)：\(blocked.detail)"
    }

    if let active = steps.first(where: { $0.state == .active }) {
      return "当前步骤：\(active.title) · \(active.detail)"
    }

    return "发布流程已准备就绪"
  }

  private func publishFlowDestination(for step: PublishDrawerFlowStep) -> PublishDrawerFlowCard {
    switch step.title {
    case "检查":
      return .checks
    case "Diff":
      return .diff
    case "写入":
      return .write
    case "远端":
      return .remote
    case "部署":
      return .deployment
    default:
      return .checks
    }
  }

  private func recommendedStep(for steps: [PublishDrawerFlowStep]) -> PublishDrawerFlowCard {
    guard let currentStep = steps.first(where: { $0.state == .blocked || $0.state == .active }) else {
      return .deployment
    }
    return publishFlowDestination(for: currentStep)
  }

  private func checkResultsCard(draft: ArticleDraft) -> some View {
    let issues = store.preflightIssues(for: draft)
    let blocking = issues.filter { $0.severity == .error }
    let warnings = issues.filter { $0.severity == .warning }

    return PublishDrawerCard(title: "检查结果", systemImage: "checklist") {
      HStack(spacing: 8) {
        PublishDrawerStat(title: "阻断", value: "\(blocking.count)", systemImage: "xmark.octagon", color: blocking.isEmpty ? .secondary : .red)
        PublishDrawerStat(title: "警告", value: "\(warnings.count)", systemImage: "exclamationmark.triangle", color: warnings.isEmpty ? .secondary : .orange)
      }

      if issues.isEmpty {
        Label("当前检查通过。", systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(issues.prefix(4)) { issue in
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: issue.severity.publishDrawerSystemImage)
                .foregroundStyle(issue.severity.publishDrawerColor)
                .frame(width: 14)
              VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                  .font(.caption.weight(.medium))
                  .lineLimit(1)
                Text(issue.message)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
      }
    }
  }

  private func diffCard(draft: ArticleDraft) -> some View {
    let preview = store.localPublishPreview(for: draft)
    let changedDiffs = preview.changedFileDiffs

    return PublishDrawerCard(title: "Diff", systemImage: "doc.text.magnifyingglass") {
      HStack(spacing: 8) {
        PublishDrawerStat(title: "文件", value: "\(preview.fileDiffs.count)", systemImage: "doc.on.doc", color: .secondary)
        PublishDrawerStat(title: "变化", value: "\(changedDiffs.count)", systemImage: "arrow.left.arrow.right", color: changedDiffs.isEmpty ? .secondary : .orange)
      }

      if changedDiffs.isEmpty {
        Label("没有待写入变化。", systemImage: "equal.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(changedDiffs.prefix(5)) { diff in
            HStack(spacing: 6) {
              Image(systemName: diff.status.publishDrawerSystemImage)
                .foregroundStyle(diff.status.publishDrawerColor)
                .frame(width: 14)
              VStack(alignment: .leading, spacing: 2) {
                Text(diff.path)
                  .font(.caption.monospaced())
                  .lineLimit(1)
                Text("\(diff.kind.displayName) · \(diff.status.displayName)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
  }

  private var repositoryBranchCard: some View {
    let branches = store.localRepositoryBranches
    let currentBranch = store.repositoryReport?.branchStatus?.branchName
      ?? store.localRepositoryBranches.first(where: \.isCurrent)?.name
      ?? "未识别"
    let currentBranchUpstream = branches.first(where: \.isCurrent)?.upstreamName
      ?? store.repositoryReport?.branchStatus?.upstreamName
    let profile = store.activeProfile
    let hasBranches = !branches.isEmpty

    return PublishDrawerCard(title: "分支管理", systemImage: "arrow.triangle.branch") {
      PublishDrawerInfoRow(
        title: "当前分支",
        value: currentBranch,
        systemImage: "pin.circle"
      )
      PublishDrawerInfoRow(
        title: "目标分支",
        value: profile.branch.nilIfEmpty ?? "未配置",
        systemImage: "flag"
      )

      if let upstream = currentBranchUpstream {
        PublishDrawerInfoRow(title: "上游", value: upstream, systemImage: "link")
      } else {
        PublishDrawerInfoRow(title: "上游", value: "未配置", systemImage: "link")
      }

      if hasBranches {
        Text("可切换分支")
          .font(.caption2)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(branches.prefix(6))) { branch in
            HStack {
              Text(branch.name)
                .lineLimit(1)
                .font(.caption.monospaced())
              Spacer()
              if branch.isCurrent {
                Label("当前", systemImage: "checkmark.circle.fill")
                  .font(.caption2)
                  .foregroundStyle(.green)
              } else {
                Button("切换") {
                  store.switchActiveProfileRepositoryBranch(to: branch.name)
                }
                .controlSize(.small)
              }
            }
          }
        }
      } else {
        Text("未检测到可用分支。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack {
        TextField("新建分支名", text: $newBranchName)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("新建分支名")
          .accessibilityValue(newBranchName.isEmpty ? "未填写" : newBranchName)
        Button("创建并切换") {
          createAndSwitchBranch()
        }
        .controlSize(.small)
        .disabled(newBranchName.trimmedForPublishing.isEmpty)
        .accessibilityLabel("创建并切换到新分支")
      }
    }
  }

  private var commitHistoryCard: some View {
    let commits = store.localRepositoryRecentCommits

    return PublishDrawerCard(title: "提交历史", systemImage: "clock.arrow.circlepath") {
      PublishDrawerStat(
        title: "最近提交",
        value: "\(commits.count)",
        systemImage: "list.number",
        color: .blue
      )

      if commits.isEmpty {
        Text("未查询到提交记录。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          let defaultCount = 6
          let displayCount = min(showAllCommits ? commits.count : defaultCount, commits.count)
          let displayCommits = Array(commits.prefix(displayCount))
          ForEach(Array(displayCommits.enumerated()), id: \.offset) { index, commit in
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .top, spacing: 6) {
                Text(commit.shortSHA)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                Text(commit.message)
                  .font(.caption2.weight(.medium))
                  .lineLimit(1)
                Spacer(minLength: 0)
              }
              Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if index != displayCommits.count - 1 {
              Divider()
            }
          }
          if commits.count > defaultCount {
            Button(showAllCommits ? "收起" : "显示更多") {
              showAllCommits.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundStyle(.blue)
            .padding(.top, 4)
            .accessibilityLabel(showAllCommits ? "收起提交历史" : "显示更多提交历史")
          }
        }
      }
    }
  }

  private func commitMethodCard(draft: ArticleDraft) -> some View {
    let profile = store.profile(for: draft)
    let mode = store.preferredRemoteRepositoryPublishMode(for: profile)
    let readiness = store.localPublishReadiness

    return PublishDrawerCard(title: "提交方式", systemImage: "arrow.triangle.branch") {
      PublishDrawerInfoRow(title: "本地策略", value: profile.repositoryPublishStrategy.displayName, systemImage: profile.repositoryPublishStrategy == .direct ? "checkmark.seal" : "arrow.triangle.branch")
      PublishDrawerInfoRow(title: "线上策略", value: mode.displayName, systemImage: "network")
      PublishDrawerInfoRow(title: "写入", value: readiness?.writeReadiness.displayName ?? "待刷新", systemImage: readiness?.writeReadiness.systemImage ?? "clock")
      PublishDrawerInfoRow(title: "提交", value: readiness?.commitReadiness.displayName ?? "待刷新", systemImage: readiness?.commitReadiness.systemImage ?? "clock")

      HStack(spacing: 8) {
        Button {
          writeDraftToRepository(draft)
        } label: {
          Label("写入", systemImage: "square.and.arrow.down")
        }
        .disabled(readiness?.canWrite != true)
        .accessibilityLabel("写入本地仓库")
        .accessibilityHint(readiness?.canWrite == true ? "写入当前文章" : "当前不能写入")

        Button {
          commitDraftUsingPreferredStrategy(draft)
        } label: {
          Label(profile.repositoryPublishStrategy.displayName, systemImage: profile.repositoryPublishStrategy == .direct ? "checkmark.seal" : "arrow.triangle.branch")
        }
        .disabled(readiness?.canCommit != true)
        .accessibilityLabel("提交方式：\(profile.repositoryPublishStrategy.displayName)")
        .accessibilityHint(readiness?.canCommit == true ? "按当前策略提交文章" : "当前不能提交")
      }
      .controlSize(.small)
    }
  }

  private func reviewDescriptionCard(draft: ArticleDraft) -> some View {
    let review = store.remoteReviewDraft(for: draft)

    return PublishDrawerCard(title: "PR/MR 描述", systemImage: "text.page") {
      PublishDrawerInfoRow(title: "分支", value: review.branchName, systemImage: "arrow.triangle.branch")
      PublishDrawerInfoRow(title: "目标", value: review.targetBranch, systemImage: "arrow.down.to.line")

      Text(review.title)
        .font(.caption.weight(.semibold))
        .lineLimit(2)

      Text(review.body)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(6)
        .textSelection(.enabled)

      Button {
        copy(review.body, message: "已复制 PR/MR 描述。")
      } label: {
        Label("复制描述", systemImage: "doc.on.doc")
      }
      .controlSize(.small)
      .accessibilityLabel("复制 PR 或 MR 描述")
    }
  }

  private func remotePublishPreviewCard(draft: ArticleDraft) -> some View {
    let preview = store.remoteRepositoryPublishPreview(for: draft)

    return PublishDrawerCard(title: "线上发布预览", systemImage: "network") {
      PublishDrawerInfoRow(title: "状态", value: preview.readiness.displayName, systemImage: preview.readiness.systemImage)
      PublishDrawerInfoRow(title: "远端", value: preview.repositoryName, systemImage: preview.provider == .github ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted")
      PublishDrawerInfoRow(title: "模式", value: preview.mode.displayName, systemImage: preview.mode == .directCommit ? "arrow.up.circle" : "arrow.triangle.pull")
      PublishDrawerInfoRow(title: "目标", value: preview.targetBranch, systemImage: "arrow.down.to.line")
      PublishDrawerInfoRow(title: "分支", value: preview.branchName, systemImage: "arrow.triangle.branch")
      PublishDrawerInfoRow(title: "权限", value: preview.accessSummary, systemImage: preview.hasToken ? "person.badge.key" : "key")

      if let issue = (preview.blockingIssues + preview.warningIssues).first {
        Label(issue.title, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(issue.severity == .error ? .red : .orange)
          .lineLimit(1)
        Text(issue.message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      } else {
        Text(preview.changedPaths.prefix(3).joined(separator: "\n"))
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .textSelection(.enabled)
      }

      HStack(spacing: 8) {
        Button {
          Task {
            await checkRepositoryTokenAccess(for: draft)
          }
        } label: {
          Label("查权限", systemImage: "person.badge.key")
        }
        .disabled(store.isRemoteRepositoryChecking)
        .accessibilityLabel("检查仓库 Token 权限")

        Button {
          publishDraftOnline(draft)
        } label: {
          Label(preview.mode.displayName, systemImage: preview.mode == .directCommit ? "arrow.up.circle" : "arrow.triangle.pull")
        }
        .disabled(!preview.canPublish || store.isRemoteRepositoryPublishing)
        .accessibilityLabel("线上发布：\(preview.mode.displayName)")
        .accessibilityHint(preview.canPublish ? "执行线上发布确认流程" : "当前线上发布预览未通过")

        Button {
          copy(preview.checklistMarkdown, message: "已复制线上发布核对包。")
        } label: {
          Label("复制核对包", systemImage: "doc.on.doc")
        }
        .accessibilityLabel("复制线上发布核对包")
      }
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private var remotePublishProgressCard: some View {
    if let progress = store.remoteRepositoryPublishProgress {
      PublishDrawerCard(title: "发布进度", systemImage: "chart.bar") {
        PublishDrawerInfoRow(
          title: "阶段",
          value: progress.stage.displayName,
          systemImage: progress.stage == .failed ? "xmark.octagon" : "flag.checkered"
        )
        PublishDrawerInfoRow(
          title: "提示",
          value: progress.message,
          systemImage: progress.stage == .failed ? "exclamationmark.triangle" : "info.circle"
        )

        if let progressValue = progress.progress {
          ProgressView(value: progressValue) {
            Text("\(Int(progressValue * 100))%")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .progressViewStyle(.linear)
        } else {
          ProgressView()
        }

        if let detail = progress.detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if let filePath = progress.filePath {
          Text(filePath)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        if progress.stage == .completed {
          Text("已完成")
            .font(.caption2)
            .foregroundStyle(.green)
        } else if progress.stage == .failed {
          Text("已失败")
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }
    } else {
      PublishDrawerCard(title: "发布进度", systemImage: "chart.bar") {
        Label("暂无发布进度", systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func deploymentStatusCard(draft: ArticleDraft? = nil) -> some View {
    let latestRecord = latestReleaseRecord(for: draft)
    let entry = latestRecord.map { store.releaseLedgerEntry(for: $0) }

    return PublishDrawerCard(title: "部署状态", systemImage: "checkmark.icloud") {
      PublishDrawerInfoRow(
        title: "轮询",
        value: store.deploymentPollingSettings.isEnabled ? "已开启" : "已关闭",
        systemImage: store.deploymentPollingSettings.isEnabled ? "timer" : "pause.circle"
      )
      PublishDrawerInfoRow(
        title: "待检查",
        value: "\(store.deploymentPollingEligibleRecords.count)",
        systemImage: "hourglass"
      )
      Button {
        copy(store.deploymentPollingState.followUpChecklistMarkdown, message: "已复制部署轮询后续清单。")
      } label: {
        Label("复制轮询清单", systemImage: "checklist")
      }
      .controlSize(.small)
      .disabled(store.deploymentPollingState.checkedRecords.isEmpty)
      .accessibilityLabel("复制部署轮询清单")

      if let entry {
        PublishDrawerInfoRow(title: "最近记录", value: entry.status.displayName, systemImage: entry.status.systemImage)
        Text(entry.record.title)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Text(entry.statusMessage)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(3)

        if let deploymentStatus = entry.deploymentStatus {
          PublishDrawerInfoRow(
            title: "校验",
            value: deploymentStatus.level.displayName,
            systemImage: deploymentStatus.level.systemImage
          )
          PublishDrawerInfoRow(
            title: "清单",
            value: "\(deploymentStatus.postPublishCheckItems.count) 项",
            systemImage: "checklist.checked"
          )
          Button {
            copy(deploymentStatus.postPublishChecklistMarkdown, message: "已复制发布后校验报告。")
          } label: {
            Label("复制校验报告", systemImage: "doc.on.doc")
          }
          .controlSize(.small)
          .accessibilityLabel("复制发布后校验报告")
        }
      } else {
        Label("还没有发布记录。", systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let latestRecord {
        Button {
          Task {
            await store.refreshDeploymentStatus(for: latestRecord)
          }
        } label: {
          Label("检查部署", systemImage: "arrow.clockwise")
        }
        .disabled(store.isDeploymentStatusChecking || !store.canCheckDeploymentStatus(for: latestRecord))
        .controlSize(.small)
        .accessibilityLabel("检查最新部署状态")
      }
    }
  }

  private func writeDraftToRepository(_ draft: ArticleDraft) {
    let currentSection = store.selectedSection
    store.focusDraft(draft.id)
    store.refreshPublishPreview(for: draft)
    store.writeSelectedDraftToLocalRepository()
    store.selectSection(currentSection)
    store.refreshPublishPreview(for: draft)
  }

  private func commitDraftUsingPreferredStrategy(_ draft: ArticleDraft) {
    let currentSection = store.selectedSection
    store.focusDraft(draft.id)
    store.refreshPublishPreview(for: draft)
    store.commitSelectedDraftUsingPreferredStrategy()
    store.selectSection(currentSection)
    store.refreshPublishPreview(for: draft)
  }

  private func publishDraftOnline(_ draft: ArticleDraft) {
    let currentSection = store.selectedSection
    store.focusDraft(draft.id)
    store.refreshPublishPreview(for: draft)
    Task {
      await store.publishSelectedDraftOnlineUsingPreferredStrategy()
      store.selectSection(currentSection)
      store.refreshPublishPreview(for: draft)
    }
  }

  private func createAndSwitchBranch() {
    store.createAndSwitchActiveProfileRepositoryBranch(name: newBranchName)
    newBranchName = ""
  }

  @MainActor
  private func checkRepositoryTokenAccess(for draft: ArticleDraft) async {
    let currentSection = store.selectedSection
    store.focusDraft(draft.id)
    await store.checkRepositoryTokenAccess()
    store.selectSection(currentSection)
  }

  private func latestReleaseRecord(for draft: ArticleDraft?) -> ReleaseRecord? {
    let records = store.activeProfileReleaseRecords
    guard let draft else {
      return records.first
    }
    return records.first { record in
      record.draftID == draft.id
        || (record.draftID == nil && record.draftTitle == draft.title && record.siteProfileID == draft.siteProfileID)
    } ?? records.first
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }
}

private struct PublishDrawerCard<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(.semibold))

      content

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityHint("发布流程步骤内容")
  }
}

private struct PublishDrawerStat: View {
  let title: String
  let value: String
  let systemImage: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: systemImage)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.semibold))
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }
}

private struct PublishDrawerInfoRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(value)
        .lineLimit(1)
    }
    .font(.caption)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }
}

private extension PreflightSeverity {
  var publishDrawerSystemImage: String {
    switch self {
    case .error:
      return "xmark.octagon"
    case .warning:
      return "exclamationmark.triangle"
    case .info:
      return "checkmark.circle"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .error:
      return .red
    case .warning:
      return .orange
    case .info:
      return .green
    }
  }
}

private extension PublishFileDiffStatus {
  var publishDrawerSystemImage: String {
    switch self {
    case .added:
      return "plus.circle"
    case .modified:
      return "pencil.circle"
    case .unchanged:
      return "equal.circle"
    case .missingSource:
      return "photo.badge.exclamationmark"
    case .unsafePath:
      return "xmark.octagon"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .added:
      return .green
    case .modified:
      return .orange
    case .unchanged:
      return .secondary
    case .missingSource, .unsafePath:
      return .red
    }
  }
}

private struct PublishDrawerFlowStep: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
  let systemImage: String
  let state: PublishDrawerFlowStepState
}

private enum PublishDrawerFlowCard: CaseIterable, Hashable, Identifiable {
  case checks
  case diff
  case write
  case remote
  case deployment

  var id: Self { self }

  var title: String {
    switch self {
    case .checks:
      return "检查"
    case .diff:
      return "Diff"
    case .write:
      return "写入"
    case .remote:
      return "远端"
    case .deployment:
      return "部署"
    }
  }
}

private enum PublishDrawerFlowStepState: Equatable {
  case complete
  case active
  case blocked
  case pending

  var color: Color {
    switch self {
    case .complete:
      return .green
    case .active:
      return .accentColor
    case .blocked:
      return .red
    case .pending:
      return .secondary
    }
  }

  var connectorColor: Color {
    switch self {
    case .complete, .active:
      return color.opacity(0.75)
    case .blocked, .pending:
      return Color(nsColor: .separatorColor)
    }
  }

  var backgroundColor: Color {
    switch self {
    case .complete:
      return .green.opacity(0.10)
    case .active:
      return .accentColor.opacity(0.12)
    case .blocked:
      return .red.opacity(0.10)
    case .pending:
      return Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }
  }

  var borderColor: Color {
    switch self {
    case .active:
      return .accentColor.opacity(0.55)
    case .blocked:
      return .red.opacity(0.45)
    case .complete:
      return .green.opacity(0.35)
    case .pending:
      return Color(nsColor: .separatorColor).opacity(0.45)
    }
  }
}

private struct PublishDrawerFlowStepView: View {
  let step: PublishDrawerFlowStep
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
          Image(systemName: step.systemImage)
            .foregroundStyle(step.state.color)
            .frame(width: 14)
          Text(step.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }

        Text(step.detail)
          .font(.caption2)
          .foregroundStyle(step.state.color)
          .lineLimit(1)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .frame(width: 112, alignment: .leading)
      .background(step.state.backgroundColor, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(step.state.borderColor)
      }
    }
    .buttonStyle(.plain)
    .help("定位到\(step.title)卡片")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(step.title)
    .accessibilityValue(step.detail)
  }
}
