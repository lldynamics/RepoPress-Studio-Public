import PublishingWorkbenchCore
import SwiftUI

/// Pure presentation state for the batch online-publish action.
///
/// Keeping the gate explanation separate from the SwiftUI view makes it
/// possible to test every disabled state without constructing a store or
/// starting a network operation.
enum PublishDrawerBatchPermissionState: Equatable {
  case unchecked
  case readOnly
  case writable
}

enum PublishDrawerRemoteOperationPurpose: Equatable {
  case publication
  case websiteDraftSync

  var confirmationTitle: String {
    switch self {
    case .publication:
      return String(localized: "最终发布确认")
    case .websiteDraftSync:
      return String(localized: "网站草稿同步确认")
    }
  }

  var confirmationDetail: String {
    switch self {
    case .publication:
      return String(localized: "请确认远端、分支、发布方式和完整文件清单。确认后会立即写入远端。")
    case .websiteDraftSync:
      return String(
        localized: "只同步当前网站草稿到远端；不会纳入批量正式发布，也不会移除 draft 标记。请确认远端、分支和完整文件清单。"
      )
    }
  }

  var targetSectionTitle: String {
    self == .websiteDraftSync
      ? String(localized: "草稿同步目标")
      : String(localized: "发布目标")
  }

  var modeLabel: String {
    self == .websiteDraftSync ? String(localized: "同步方式") : String(localized: "模式")
  }

  var branchLabel: String {
    self == .websiteDraftSync ? String(localized: "同步分支") : String(localized: "发布分支")
  }

  var fileListTitle: String {
    self == .websiteDraftSync ? String(localized: "完整同步文件清单") : String(localized: "完整文件清单")
  }

  var emptyFileMessage: String {
    self == .websiteDraftSync ? String(localized: "没有待同步文件。") : String(localized: "没有待发布文件。")
  }

  var warningTitle: String {
    self == .websiteDraftSync ? String(localized: "同步警告") : String(localized: "发布警告")
  }

  func footerSummary(fileCount: Int) -> String {
    if self == .websiteDraftSync {
      return String(format: String(localized: "将同步 %d 个草稿文件"), fileCount)
    }
    return String(format: String(localized: "将发布 %d 个文件"), fileCount)
  }

  var confirmActionTitle: String {
    self == .websiteDraftSync ? String(localized: "确认同步网站草稿") : String(localized: "确认线上发布")
  }

  var confirmAccessibilityHint: String {
    self == .websiteDraftSync
      ? String(localized: "确认后立即同步当前网站草稿")
      : String(localized: "确认后立即执行远端发布")
  }
}

struct PublishDrawerSingleArticleActionPresentation: Equatable {
  let actionTitle: String
  let accessibilityLabel: String
  let enabledHint: String
  let disabledHint: String
  let confirmationPurpose: PublishDrawerRemoteOperationPurpose

  static func make(isWebsiteDraft: Bool) -> Self {
    if isWebsiteDraft {
      return Self(
        actionTitle: String(localized: "同步当前网站草稿…"),
        accessibilityLabel: String(localized: "同步当前网站草稿"),
        enabledHint: String(localized: "打开当前网站草稿的单篇同步确认页；不会纳入批量正式发布"),
        disabledHint: String(localized: "当前网站草稿的远端同步预览未通过"),
        confirmationPurpose: .websiteDraftSync
      )
    }
    return Self(
      actionTitle: String(localized: "仅发布当前文章…"),
      accessibilityLabel: String(localized: "仅发布当前文章"),
      enabledHint: String(localized: "打开当前文章的最终发布确认页"),
      disabledHint: String(localized: "当前文章的线上发布预览未通过"),
      confirmationPurpose: .publication
    )
  }
}

struct PublishDrawerPreviewBranchActionPresentation: Equatable {
  let title: String
  let detail: String
  let actionTitle: String
  let accessibilityLabel: String
  let accessibilityHint: String

  static func make(branchName: String, targetBranch: String) -> Self {
    Self(
      title: String(localized: "推送草稿预览分支"),
      detail: String(
        format: String(localized: "创建或复用 %@，只写入该分支；不会更新 %@、创建 PR/MR 或改变正式发布状态。"),
        branchName,
        targetBranch
      ),
      actionTitle: String(localized: "推送预览分支"),
      accessibilityLabel: String(localized: "推送草稿预览分支"),
      accessibilityHint: String(
        format: String(localized: "将当前单篇草稿推送到 %@"),
        branchName
      )
    )
  }
}

struct PublishDrawerBatchActionPresentation {
  struct State: Equatable {
    var repositoryConfigured: Bool
    var hasToken: Bool
    var tokenAccessFailureMessage: String?
    var permission: PublishDrawerBatchPermissionState
    var blockingIssueTitle: String?
    var hasRemoteConflict: Bool
    var publishableArticleCount: Int?
    var draftSyncArticleCount: Int
    var pendingDeletionCount: Int
    var changedFileCount: Int?
    var isPlanRefreshing: Bool
    var isPermissionChecking: Bool
    var isPublishing: Bool

    init(
      repositoryConfigured: Bool,
      hasToken: Bool,
      tokenAccessFailureMessage: String? = nil,
      permission: PublishDrawerBatchPermissionState = .unchecked,
      blockingIssueTitle: String? = nil,
      hasRemoteConflict: Bool = false,
      publishableArticleCount: Int? = nil,
      draftSyncArticleCount: Int = 0,
      pendingDeletionCount: Int = 0,
      changedFileCount: Int? = nil,
      isPlanRefreshing: Bool = false,
      isPermissionChecking: Bool = false,
      isPublishing: Bool = false
    ) {
      self.repositoryConfigured = repositoryConfigured
      self.hasToken = hasToken
      self.tokenAccessFailureMessage = tokenAccessFailureMessage
      self.permission = permission
      self.blockingIssueTitle = blockingIssueTitle
      self.hasRemoteConflict = hasRemoteConflict
      self.publishableArticleCount = publishableArticleCount
      self.draftSyncArticleCount = draftSyncArticleCount
      self.pendingDeletionCount = pendingDeletionCount
      self.changedFileCount = changedFileCount
      self.isPlanRefreshing = isPlanRefreshing
      self.isPermissionChecking = isPermissionChecking
      self.isPublishing = isPublishing
    }
  }

  static let title = String(localized: "发布所有待处理变更")
  static let detail = String(
    localized: "包含应用管理的文章发布包和待下线 Markdown；不会包含 CSS、模板、脚本等其他 Git 工作区变更。发布前会显示完整文件清单。"
  )
  static let actionTitle = String(localized: "发布所有待处理变更…")

  static func isEnabled(_ state: State) -> Bool {
    guard !state.isPlanRefreshing,
          !state.isPermissionChecking,
          !state.isPublishing,
          state.repositoryConfigured,
          state.hasToken,
          state.tokenAccessFailureMessage == nil,
          state.permission == .writable,
          state.blockingIssueTitle == nil,
          !state.hasRemoteConflict,
          let articleCount = state.publishableArticleCount,
          articleCount > 0 || state.pendingDeletionCount > 0
    else {
      return false
    }
    return true
  }

  static func status(_ state: State) -> String {
    if state.isPlanRefreshing {
      return String(localized: "正在汇总文章发布包")
    }
    if state.isPermissionChecking {
      return String(localized: "正在检查仓库写入权限")
    }
    if state.isPublishing {
      return String(localized: "正在发布文章")
    }
    if !state.repositoryConfigured {
      return String(localized: "先配置线上仓库")
    }
    if let blockingIssueTitle = state.blockingIssueTitle {
      return blockingIssueTitle
    }
    if state.tokenAccessFailureMessage != nil {
      return String(localized: "仓库 Token 状态读取失败")
    }
    if !state.hasToken {
      return String(localized: "请先保存仓库 Token")
    }
    switch state.permission {
    case .unchecked:
      return String(localized: "请先检查仓库写入权限")
    case .readOnly:
      return String(localized: "Token 没有仓库写入权限")
    case .writable:
      break
    }
    if state.hasRemoteConflict {
      return String(localized: "远端存在冲突，请先核对")
    }
    guard let articleCount = state.publishableArticleCount else {
      return String(localized: "正在准备文章发布包")
    }
    guard articleCount > 0 || state.pendingDeletionCount > 0 else {
      if state.draftSyncArticleCount > 0 {
        return String(
          format: String(localized: "%d 篇网站草稿未纳入发布，请单独同步"),
          state.draftSyncArticleCount
        )
      }
      return String(localized: "没有待处理变更")
    }
    let fileCount = state.changedFileCount ?? 0
    let draftSuffix = state.draftSyncArticleCount > 0
      ? String(
        format: String(localized: " · 另有 %d 篇网站草稿未纳入发布"),
        state.draftSyncArticleCount
      )
      : ""
    if articleCount == 0 {
      return String(
        format: String(localized: "待下线 %d 篇文章 · %d 个文件"),
        state.pendingDeletionCount,
        fileCount
      ) + draftSuffix
    }
    if state.pendingDeletionCount > 0 {
      return String(
        format: String(localized: "可发布 %d 篇 · 待下线 %d 篇 · %d 个文件"),
        articleCount,
        state.pendingDeletionCount,
        fileCount
      ) + draftSuffix
    }
    return String(
      format: String(localized: "可发布 %d 篇文章 · %d 个文章文件"),
      articleCount,
      fileCount
    ) + draftSuffix
  }

  static func accessibilityHint(isEnabled: Bool, status: String) -> String {
    if isEnabled {
      return String(localized: "执行此操作")
    }
    return status
  }
}

enum PublishDrawerActionStyle: Equatable {
  case localSave
  case formalRelease
  case isolatedPreview
}

struct PublishDrawerActionChoice: View {
  let title: String
  let detail: String
  let status: String
  let systemImage: String
  let tint: Color
  let isEnabled: Bool
  var isPrimary: Bool = false
  var actionStyle: PublishDrawerActionStyle = .localSave
  var targetBadge: String? = nil
  var targetBadgeTint: Color? = nil
  let actionTitle: String
  let actionSystemImage: String
  let actionIdentifier: String
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(tint)
          .accessibilityHidden(true)

        Spacer()

        if let targetBadge {
          Text(targetBadge)
            .font(.workbenchMetadata.weight(.medium))
            .foregroundStyle(targetBadgeTint ?? tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              (targetBadgeTint ?? tint).opacity(0.12),
              in: Capsule()
            )
            .lineLimit(1)
        }
      }

      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Label(status, systemImage: isEnabled ? "checkmark.circle" : "info.circle")
        .font(.caption)
        .foregroundStyle(isEnabled ? tint : .secondary)

      Spacer(minLength: 0)

      if actionStyle == .formalRelease || isPrimary {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
        .accessibilityIdentifier(actionIdentifier)
        .accessibilityHint(
          PublishDrawerBatchActionPresentation.accessibilityHint(
            isEnabled: isEnabled,
            status: status
          )
        )
        .help(status)
      } else {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier(actionIdentifier)
        .accessibilityHint(
          PublishDrawerBatchActionPresentation.accessibilityHint(
            isEnabled: isEnabled,
            status: status
          )
        )
        .help(status)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
    .background(
      cardBackground,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(cardBorderStroke, lineWidth: actionStyle == .formalRelease ? 1.5 : 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityValue(status)
  }

  private var cardBackground: AnyShapeStyle {
    if actionStyle == .formalRelease {
      return AnyShapeStyle(WorkbenchTheme.success.opacity(isEnabled ? 0.05 : 0.02))
    }
    return WorkbenchBackgroundStyle.card
  }

  private var cardBorderStroke: Color {
    if actionStyle == .formalRelease {
      return WorkbenchTheme.success.opacity(isEnabled ? 0.5 : 0.2)
    }
    return tint.opacity(isEnabled ? 0.35 : 0.15)
  }
}

private struct PublishDrawerReadinessIssue: Identifiable {
  let id: String
  let severity: PreflightSeverity
  let title: String
  let message: String
}

private struct PublishDrawerReadinessSection: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let issues: [PublishDrawerReadinessIssue]
  let isLoading: Bool

  var errorCount: Int {
    issues.filter { $0.severity == .error }.count
  }

  var warningCount: Int {
    issues.filter { $0.severity == .warning }.count
  }

  var tint: Color {
    if errorCount > 0 {
      return WorkbenchTheme.risk
    }
    if warningCount > 0 {
      return WorkbenchTheme.warning
    }
    return WorkbenchTheme.success
  }

  var statusTitle: String {
    if isLoading {
      return "检查中"
    }
    if errorCount > 0 {
      return "\(errorCount) 个阻断"
    }
    if warningCount > 0 {
      return "\(warningCount) 个提醒"
    }
    return "通过"
  }
}

struct PublishDrawerReadinessChecklist: View {
  let preflightIssues: [PreflightIssue]
  let imageReport: ImageWorkbenchReport?
  let isImageReportLoading: Bool
  let seoReport: SEOAuditReport
  let socialSnapshot: SEOSocialPreviewSnapshot?
  let isSocialPreviewStale: Bool

  @State private var expandedSectionIDs: Set<String> = ["preflight"]

  var body: some View {
    let sections = readinessSections
    let blockingCount = sections.reduce(0) { $0 + $1.errorCount }
    let warningCount = sections.reduce(0) { $0 + $1.warningCount }
    let isLoading = sections.contains(where: \.isLoading)

    PublishDrawerCard(title: "发布就绪清单", systemImage: "checklist.checked") {
      Text("Preflight、图片、SEO 和社交卡片在同一处复核，发布前只需要看这一张清单。")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        PublishDrawerStat(
          title: "阻断",
          value: "\(blockingCount)",
          systemImage: "xmark.octagon",
          color: blockingCount == 0 ? .secondary : WorkbenchTheme.risk
        )
        PublishDrawerStat(
          title: "提醒",
          value: "\(warningCount)",
          systemImage: "exclamationmark.triangle",
          color: warningCount == 0 ? .secondary : WorkbenchTheme.warning
        )
        PublishDrawerStat(
          title: "检查项",
          value: "\(sections.count)",
          systemImage: "square.grid.2x2",
          color: .secondary
        )
      }

      Label(
        isLoading
          ? "正在准备图片或社交预览检查…"
          : blockingCount > 0
            ? "处理阻断项后再发布。"
            : warningCount > 0
              ? "可以发布，但建议先确认提醒。"
              : "四类发布检查均已通过。",
        systemImage: isLoading
          ? "arrow.clockwise"
          : blockingCount > 0
            ? "xmark.octagon"
            : warningCount > 0
              ? "exclamationmark.triangle"
              : "checkmark.circle"
      )
      .font(.caption.weight(.medium))
      .foregroundStyle(
        isLoading
          ? .secondary
          : blockingCount > 0
            ? WorkbenchTheme.risk
            : warningCount > 0
              ? WorkbenchTheme.warning
              : WorkbenchTheme.success
      )

      VStack(alignment: .leading, spacing: 6) {
        ForEach(sections) { section in
          if section.issues.isEmpty && !section.isLoading {
            readinessSectionLabel(section)
          } else {
            DisclosureGroup(isExpanded: expandedBinding(for: section.id)) {
              VStack(alignment: .leading, spacing: 7) {
                if section.isLoading {
                  Label("正在读取最新检查结果…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(section.issues) { issue in
                  readinessIssueRow(issue)
                }
              }
              .padding(.top, 5)
            } label: {
              readinessSectionLabel(section)
            }
          }
        }
      }
    }
    .accessibilityIdentifier("publish-drawer-readiness-checklist")
  }

  private var readinessSections: [PublishDrawerReadinessSection] {
    let preflight =
      preflightIssues
      .filter { $0.severity != .info }
      .map { issue in
        PublishDrawerReadinessIssue(
          id: "preflight-\(issue.id.uuidString)",
          severity: issue.severity,
          title: issue.title,
          message: issue.message
        )
      }

    let imageIssues =
      imageReport?.issues
      .filter { !$0.isCovered(by: preflightIssues) }
      .map { issue in
        PublishDrawerReadinessIssue(
          id: "image-\(issue.id.uuidString)",
          severity: issue.severity,
          title: issue.title,
          message: issue.message
        )
      } ?? []

    let seoIssues = seoReport.findings
      .filter { $0.severity != .info }
      .map { finding in
        PublishDrawerReadinessIssue(
          id: "seo-\(finding.id.uuidString)",
          severity: finding.severity,
          title: finding.title,
          message: finding.message
        )
      }

    var socialIssues =
      socialSnapshot?.findings
      .filter { $0.severity != .info }
      .map { finding in
        PublishDrawerReadinessIssue(
          id: "social-\(finding.id.uuidString)",
          severity: finding.severity,
          title: finding.title,
          message: finding.message
        )
      } ?? []
    if socialSnapshot == nil {
      socialIssues.append(
        PublishDrawerReadinessIssue(
          id: "social-missing",
          severity: .warning,
          title: "社交预览尚未生成",
          message: "刷新社交预览后才能确认 Open Graph、Twitter/X 和 JSON-LD 字段。"
        )
      )
    } else if isSocialPreviewStale {
      socialIssues.append(
        PublishDrawerReadinessIssue(
          id: "social-stale",
          severity: .warning,
          title: "社交预览需要刷新",
          message: "文章元数据已变化，当前卡片快照不是最新版本。"
        )
      )
    }

    return [
      PublishDrawerReadinessSection(
        id: "preflight",
        title: "Preflight",
        systemImage: "shield.checkered",
        issues: preflight,
        isLoading: false
      ),
      PublishDrawerReadinessSection(
        id: "images",
        title: "图片",
        systemImage: "photo",
        issues: imageIssues,
        isLoading: isImageReportLoading && imageReport == nil
      ),
      PublishDrawerReadinessSection(
        id: "seo",
        title: "SEO",
        systemImage: "magnifyingglass",
        issues: seoIssues,
        isLoading: false
      ),
      PublishDrawerReadinessSection(
        id: "social",
        title: "社交卡片",
        systemImage: "rectangle.inset.filled",
        issues: socialIssues,
        isLoading: false
      ),
    ]
  }

  private func readinessSectionLabel(_ section: PublishDrawerReadinessSection) -> some View {
    HStack(spacing: 8) {
      Image(systemName: section.systemImage)
        .foregroundStyle(section.tint)
        .frame(width: 16)
      Text(section.title)
        .font(.caption.weight(.medium))
      Spacer(minLength: 8)
      Text(section.statusTitle)
        .font(.caption)
        .foregroundStyle(section.tint)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(section.title)，\(section.statusTitle)")
  }

  private func readinessIssueRow(_ issue: PublishDrawerReadinessIssue) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: issue.severity.publishDrawerSystemImage)
        .foregroundStyle(issue.severity.publishDrawerColor)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title)
          .font(.caption.weight(.medium))
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func expandedBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { expandedSectionIDs.contains(id) },
      set: { isExpanded in
        if isExpanded {
          expandedSectionIDs.insert(id)
        } else {
          expandedSectionIDs.remove(id)
        }
      }
    )
  }
}
