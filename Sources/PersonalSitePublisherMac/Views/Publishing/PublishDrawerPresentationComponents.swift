import PublishingWorkbenchCore
import SwiftUI

/// Pure presentation state for the site overview's publishing summary.
struct UnifiedPublishReadinessPresentation: Equatable {
  struct ContentHealth: Equatable, Sendable {
    let errorCount: Int
    let warningCount: Int
    let aiFixCount: Int
    let passingDraftCount: Int

    static let unavailable = Self(
      errorCount: 0,
      warningCount: 0,
      aiFixCount: 0,
      passingDraftCount: 0
    )
  }

  let articleCount: Int
  let newArticleCount: Int
  let modifiedArticleCount: Int
  let imageChangeCount: Int
  let newImageCount: Int
  let deletionCount: Int
  let preflightTitle: String
  let preflightSystemImage: String
  let targetTitle: String
  let pipelineTitle: String
  let actionTitle: String
  let contentHealth: ContentHealth

  static func make(
    plan: BatchPublishPlan?,
    preview: RemoteRepositoryPublishPreview?,
    profile: SiteProfile,
    pendingDeletionCount: Int,
    contentHealth: ContentHealth = .unavailable
  ) -> Self {
    let items = plan?.remotePublishableItems ?? []
    let newArticleCount = items.count { item in
      item.preview.fileDiffs.contains { diff in
        diff.kind == .markdown
          && diff.path == item.markdownPath
          && diff.status == .added
      }
    }
    let imageDiffs = items.flatMap(\.preview.fileDiffs).filter { diff in
      diff.kind == .image && diff.status != .unchanged
    }
    let imagePaths = Set(imageDiffs.map(\.path))
    let newImagePaths = Set(
      imageDiffs.filter { $0.status == .added }.map(\.path)
    )
    let mode =
      preview?.mode
      ?? (profile.repositoryPublishStrategy == .reviewRequest ? .reviewRequest : .directCommit)
    let provider = preview?.provider ?? profile.repositoryProvider
    let targetBranch =
      preview?.targetBranch.nilIfEmpty
      ?? profile.branch.nilIfEmpty
      ?? "main"

    let planBlockingIssues =
      items
      .flatMap(\.allIssues)
      .filter { $0.severity == .error }
    let preflight: (String, String)
    if plan == nil {
      preflight = (String(localized: "正在汇总发布检查"), "clock.arrow.circlepath")
    } else if mode == .directCommit && preview?.remoteRiskState == .conflict {
      preflight = (String(localized: "远端版本冲突，未执行写入"), "xmark.octagon.fill")
    } else if let issue = preview?.blockingIssues.first ?? planBlockingIssues.first {
      preflight = (issue.title, "xmark.octagon.fill")
    } else if preview == nil || (mode == .directCommit && preview?.remoteRiskState == .unknown) {
      preflight = (String(localized: "内容检查通过，远端将在发布时预检"), "checkmark.shield")
    } else {
      preflight = (String(localized: "全部通过（已检查项未发现公开风险）"), "checkmark.shield.fill")
    }

    return Self(
      articleCount: items.count,
      newArticleCount: newArticleCount,
      modifiedArticleCount: max(0, items.count - newArticleCount),
      imageChangeCount: imagePaths.count,
      newImageCount: newImagePaths.count,
      deletionCount: pendingDeletionCount,
      preflightTitle: preflight.0,
      preflightSystemImage: preflight.1,
      targetTitle: "\(targetBranch) · \(provider.localizedDisplayName)",
      pipelineTitle: mode == .reviewRequest
        ? String(localized: "生成发布包 → 内容检查 → 远端预检 → 创建 PR/MR")
        : String(localized: "生成发布包 → 内容检查 → 远端预检 → 提交 → 部署检查"),
      actionTitle: mode == .reviewRequest
        ? String(localized: "审阅并创建 PR/MR…")
        : String(localized: "审阅并发布…"),
      contentHealth: contentHealth
    )
  }
}

extension PublishActionMessageStatus {
  var publishDrawerSystemImage: String {
    switch self {
    case .information: return "info.circle.fill"
    case .inProgress: return "arrow.trianglehead.2.clockwise.rotate.90"
    case .success: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .failure: return "xmark.octagon.fill"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .information: return WorkbenchTheme.info
    case .inProgress: return WorkbenchTheme.progress
    case .success: return WorkbenchTheme.success
    case .warning: return WorkbenchTheme.warning
    case .failure: return WorkbenchTheme.risk
    }
  }

  var publishDrawerTitle: String {
    switch self {
    case .information: return String(localized: "信息")
    case .inProgress: return String(localized: "进行中")
    case .success: return String(localized: "成功")
    case .warning: return String(localized: "警告")
    case .failure: return String(localized: "失败")
    }
  }
}

struct PublishDrawerReadinessChecklist: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let presentation: PublishDrawerReadinessPresentation
  @Binding var selectedIssueID: String?
  var onNavigate: ((PublishDrawerReadinessIssue) -> Void)? = nil
  var onRequestAIFix: ((PublishDrawerReadinessIssue) -> Void)? = nil
  var store: WorkbenchStore? = nil
  @State private var showsPassedChecks = false

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      if !presentation.issues.isEmpty {
        VStack(spacing: 0) {
          ForEach(presentation.issues) { issue in
            readinessIssueRow(issue)
            if issue.id != presentation.issues.last?.id { Divider() }
          }
        }
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }
      if presentation.isLoading {
        Label("正在读取最新检查结果…", systemImage: "arrow.clockwise")
          .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
      }
      if presentation.ignoredCount > 0 {
        Label(
          String(format: String(localized: "已按站点检查设置忽略 %d 项可选提醒"), presentation.ignoredCount),
          systemImage: "eye.slash"
        )
        .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
        .help(String(localized: "在“站点 → 站点检查 → 已忽略设置”中可恢复。"))
        .accessibilityIdentifier("publish-drawer-ignored-checks")
      }
      DisclosureGroup(isExpanded: $showsPassedChecks) {
        ForEach(presentation.passedSections) { section in
          Label(section.title, systemImage: section.systemImage)
            .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
            .padding(.vertical, WorkbenchSpacing.tight)
        }
        if presentation.passedSections.isEmpty {
          Text("尚无已完成的通过项").font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
        }
      } label: {
        Label(
          String(format: String(localized: "已通过 %d 项"), presentation.passedSections.count),
          systemImage: "checkmark.circle"
        )
        .font(.workbenchBody.weight(.medium)).foregroundStyle(WorkbenchTheme.success)
      }
      .disclosureGroupStyle(
        WorkbenchDisclosureGroupStyle(toggleIdentifier: "publish-inspector-passed-checks")
      )
      .padding(WorkbenchSpacing.control)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-drawer-readiness-checklist")
  }

  private func readinessIssueRow(_ issue: PublishDrawerReadinessIssue) -> some View {
    HStack(alignment: .top, spacing: WorkbenchSpacing.tight) {
      Image(systemName: issue.severity.publishDrawerSystemImage)
        .foregroundStyle(issue.severity.publishDrawerColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
        Text(issue.title).font(.workbenchBody.weight(.medium))
        Text(issue.message).font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkbenchSpacing.tight) { issueActions(issue) }
          VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) { issueActions(issue) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(WorkbenchSpacing.control)
    .background(selectedIssueID == issue.id ? workbenchAccentColor.opacity(0.10) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { selectedIssueID = issue.id }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(issue.severity.localizedDisplayName)：\(issue.title)")
    .accessibilityValue(selectedIssueID == issue.id ? String(localized: "已选中") : "")
    .accessibilityIdentifier("publish-inspector-issue-\(issue.id)")
  }

  @ViewBuilder
  private func issueActions(_ issue: PublishDrawerReadinessIssue) -> some View {
    if let onNavigate {
      Button(issue.actionTitle) {
        selectedIssueID = issue.id
        onNavigate(issue)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel("\(issue.actionTitle)：\(issue.title)")
      .accessibilityIdentifier("publish-readiness-action-\(issue.id)")
    }
    if issue.supportsAIFix, let onRequestAIFix {
      if let store {
        PublishDrawerAIFixButton(
          issue: issue, store: store, isPrimaryAction: onNavigate == nil
        ) {
          selectedIssueID = issue.id
          onRequestAIFix(issue)
        }
      } else {
        let button = Button {
          selectedIssueID = issue.id
          onRequestAIFix(issue)
        } label: {
          Label("AI 修复", systemImage: "sparkles")
        }
        .accessibilityLabel("AI 修复：\(issue.title)")
        .accessibilityHint("打开 AI 助手准备修复请求")
        .accessibilityIdentifier("publish-readiness-ai-fix-\(issue.id)")
        if onNavigate == nil {
          button
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
          button
            .buttonStyle(.link)
        }
      }
    }
  }
}

struct PublishDrawerAttentionSummary: View {
  let blockingCount: Int
  let pendingCount: Int
  let optimizationCount: Int
  let isReady: Bool

  var body: some View {
    if blockingCount > 0 {
      Text(String(format: String(localized: "阻止发布 · %d"), blockingCount))
        .font(.workbenchMetadata.weight(.semibold)).foregroundStyle(.red)
    }
    if pendingCount > 0 {
      Text(String(format: String(localized: "需要处理 · %d"), pendingCount))
        .font(.workbenchMetadata.weight(.semibold)).foregroundStyle(.workbenchSecondary)
    } else if isReady {
      Text("可发布")
        .font(.workbenchMetadata.weight(.semibold)).foregroundStyle(.green)
    }
    if optimizationCount > 0 {
      Text(String(format: String(localized: "可选优化 · %d"), optimizationCount))
        .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
    }
  }
}
