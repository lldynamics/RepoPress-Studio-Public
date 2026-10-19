import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// The single confirmation of both publish actions. Nothing is staged until
/// the user confirms this exact frozen snapshot; the summary leads with what
/// will happen, and repository internals stay folded away.
struct RepositoryWorktreePublishConfirmationView: View {
  @State private var safetyWarningsAcknowledged = false
  @State private var outgoingHistoryAcknowledged = false

  let confirmation: RepositoryWorktreePublishConfirmation
  /// The article title, or the site name when publishing everything.
  var subject: String = ""
  /// The site name is supplied by the workspace route for an article publish.
  var siteName: String = ""
  /// Published articles are written with update semantics; drafts remain publishes.
  var isUpdate: Bool = false
  var note: String? = nil
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  private var actionTitle: String {
    confirmation.isScoped
      ? (isUpdate ? String(localized: "更新文章") : String(localized: "发布这篇文章"))
      : String(localized: "发布全部变更")
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if confirmation.isScoped {
            articleSummaryCard
          }
          summaryCard
          if let outgoingHistory {
            outgoingHistoryCard(outgoingHistory)
          }
          if !attentionItems.isEmpty {
            attentionCard
          }
          if !optionalAttentionItems.isEmpty {
            optionalAttentionCard
          }
          if confirmation.isScoped {
            DisclosureGroup {
              fileList
                .workbenchAccessibilityContainer(identifier: "publish-worktree-file-list-content")
            } label: {
              Text(String(localized: "查看 Git 文件差异"))
                .accessibilityIdentifier("publish-worktree-file-list-details")
            }
          } else {
            fileList
          }
          technicalDetails
        }
        .padding(WorkbenchSpacing.spacious)
      }
      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 600)
    // A container keeps the sheet's identifier from replacing its children's,
    // such as the confirm button's.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-worktree-confirmation")
    .onChange(of: confirmation.id) { _, _ in
      safetyWarningsAcknowledged = false
      outgoingHistoryAcknowledged = false
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: confirmation.isScoped ? "doc.badge.arrow.up" : "paperplane.fill")
        .font(.workbenchTitle2)
        .foregroundStyle(.workbenchSecondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(actionTitle)
          .font(.workbenchHeadline)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(actionTitle)
        if !subject.isEmpty {
          Text(subject)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer()
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var summaryCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if let outgoingHistory {
          if confirmation.snapshot.paths.isEmpty {
            Label(
              String(
                format: String(localized: "%d 个已有提交将推送到 origin/%@；这次没有新的文件提交。"),
                outgoingHistory.commitCount, confirmation.snapshot.branch),
              systemImage: "arrow.up.circle"
            )
          } else {
            Label(
              String(
                format: String(localized: "%d 个文件将提交，并推送 %d 个已有提交到 origin/%@"),
                confirmation.snapshot.paths.count, outgoingHistory.commitCount,
                confirmation.snapshot.branch),
              systemImage: "arrow.up.circle"
            )
          }
        } else if confirmation.snapshot.paths.isEmpty {
          Label(
            String(localized: "没有文件需要提交。"),
            systemImage: "arrow.up.circle"
          )
        } else {
          Label(
            String(
              format: String(localized: "%d 个文件将提交并推送到 origin/%@"),
              confirmation.snapshot.paths.count, confirmation.snapshot.branch),
            systemImage: "arrow.up.circle"
          )
        }
      }
      .font(.workbenchBody.weight(.medium))
      Text(summaryDescription)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if let note {
        Label(note, systemImage: "info.circle")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .workbenchAccessibilityContainer(identifier: "publish-worktree-summary")
  }

  private var summaryDescription: String {
    if outgoingHistory != nil {
      return confirmation.isScoped
        ? String(localized: "这些提交已经在本地创建，也会一并推送；当前未提交文件仍只限于这篇文章的范围。")
        : String(localized: "这些提交已经在本地创建，也会一并推送；当前未提交文件按全部变更范围处理。")
    }
    return confirmation.isScoped
      ? String(localized: "只提交这篇文章和它的图片；仓库里的其他改动不受影响。")
      : String(localized: "包含仓库里所有未提交的改动：文章、图片、配置和主题，以及删除和重命名。")
  }

  private func outgoingHistoryCard(_ history: RepositoryWorktreePushRetrySnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        String(
          format: String(localized: "已有提交历史（%d 个提交）"), history.commitCount),
        systemImage: "clock.arrow.circlepath"
      )
      .font(.workbenchHeadline)
      Text(historyDescription)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(history.commitReviews) { commit in
        DisclosureGroup(
          String(
            format: String(localized: "提交 %@"),
            RepositoryWorktreePublishPresentation.shortSHA(commit.commitSHA))
        ) {
          RepositoryWorktreeReviewFileList(
            entries: commit.entries, reviews: commit.fileReviews)
        }
      }
      Toggle(
        String(localized: "我已逐项审阅这些已有提交，并确认将它们一并推送。"),
        isOn: $outgoingHistoryAcknowledged
      )
      .toggleStyle(.checkbox)
      .font(.workbenchBody.weight(.medium))
      .accessibilityIdentifier("publish-worktree-history-acknowledgement")
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchTheme.warning.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .workbenchAccessibilityContainer(identifier: "publish-worktree-outgoing-history")
  }

  private var historyDescription: String {
    if confirmation.snapshot.paths.isEmpty {
      return String(localized: "确认后会推送这些已经提交的历史；这次没有新的文件提交。")
    }
    return confirmation.isScoped
      ? String(localized: "确认后会推送这些已经提交的历史；当前还有这篇文章范围内的未提交文件。")
      : String(localized: "确认后会推送这些已经提交的历史；当前还有待发布的未提交文件。")
  }

  private var articleSummaryCard: some View {
    let target = confirmation.articleVerificationTarget
    let changes = RepositoryWorktreePublishPresentation.contentChangeSummary(
      entries: confirmation.snapshot.entries,
      articlePath: target?.markdownPath
    )
    let targetURL = target?.publicURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlText = targetURL?.isEmpty == false ? targetURL! : String(localized: "待配置，无法确定")

    return VStack(alignment: .leading, spacing: 10) {
      Label(
        isUpdate ? String(localized: "更新文章") : String(localized: "发布这篇"),
        systemImage: "doc.badge.arrow.up"
      )
      .font(.workbenchHeadline)
      LabeledContent(String(localized: "文章"), value: target?.title ?? subject)
      if !siteName.isEmpty {
        LabeledContent(String(localized: "站点"), value: siteName)
      }
      LabeledContent(String(localized: "预计网址"), value: urlText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "预计网址") + ": " + urlText)
        .accessibilityIdentifier("publish-worktree-target-url")
      VStack(alignment: .leading, spacing: 5) {
        Text(String(localized: "内容变更"))
          .font(.workbenchBody.weight(.medium))
        Text(changes.summaryText)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(changes.summaryText)
          .accessibilityIdentifier("publish-worktree-content-summary")
      }
      if !changes.riskPaths.isEmpty {
        Label(
          String(localized: "包含删除或重命名：\(changes.riskPaths.joined(separator: "、"))"),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.workbenchMetadata.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .workbenchAccessibilityContainer(identifier: "publish-worktree-article-summary")
  }

  private struct AttentionItem: Identifiable {
    let id: String
    let title: String
    let message: String
  }

  /// Only what deserves a second look before publishing is shown up front.
  private var attentionItems: [AttentionItem] {
    var items: [AttentionItem] = []
    if let preflight = confirmation.sitePreflightResult,
      RepositoryWorktreePublishConfirmationPresentationPolicy.isFailed(preflight)
    {
      items.append(
        AttentionItem(
          id: "site-preflight", title: String(localized: "站点构建检查"),
          message: preflight.message))
    }
    items += confirmation.safetyReport.warnings.map {
      AttentionItem(id: $0.id, title: $0.title, message: $0.message)
    }
    items += articleWarningIssues.map {
      AttentionItem(
        id: "article-preflight-\($0.id.uuidString)", title: $0.title, message: $0.message)
    }
    if !isReviewComplete {
      items.append(
        AttentionItem(
          id: "incomplete-review", title: String(localized: "文件差异未能完整读取"),
          message: String(localized: "请取消后重新发布。")))
    }
    return items
  }

  private var articleWarningIssues: [PreflightIssue] {
    RepositoryWorktreePublishConfirmationPresentationPolicy.warningIssues(
      from: confirmation.articlePreflightIssues)
  }

  private var optionalAttentionItems: [AttentionItem] {
    var items: [AttentionItem] = []
    if let preflight = confirmation.sitePreflightResult,
      RepositoryWorktreePublishConfirmationPresentationPolicy.isSkipped(preflight)
    {
      items.append(
        AttentionItem(
          id: "site-preflight", title: String(localized: "站点构建检查"),
          message: preflight.message))
    }
    items += RepositoryWorktreePublishConfirmationPresentationPolicy.optionalIssues(
      from: confirmation.articlePreflightIssues
    ).map {
      AttentionItem(
        id: "article-optional-\($0.id.uuidString)", title: $0.title, message: $0.message)
    }
    return items
  }

  private var attentionCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("发布前请留意", systemImage: "exclamationmark.triangle.fill")
        .font(.workbenchHeadline)
        .foregroundStyle(WorkbenchTheme.warning)
      ForEach(attentionItems) { item in
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title)
            .font(.workbenchBody.weight(.semibold))
          Text(item.message)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      if requiresSafetyAcknowledgement {
        Toggle(
          String(localized: "我已阅读并确认上述提醒，仍要继续发布。"),
          isOn: $safetyWarningsAcknowledged
        )
        .toggleStyle(.checkbox)
        .font(.workbenchBody.weight(.medium))
        .accessibilityIdentifier("publish-worktree-safety-acknowledgement")
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchTheme.warning.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-worktree-attention")
  }

  private var optionalAttentionCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(String(localized: "待补充（不影响发布）"), systemImage: "info.circle")
        .font(.workbenchHeadline)
        .foregroundStyle(.workbenchSecondary)
      ForEach(optionalAttentionItems) { item in
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title)
            .font(.workbenchBody.weight(.semibold))
          Text(item.message)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-worktree-optional-attention")
  }

  private var fileList: some View {
    RepositoryWorktreeReviewFileList(
      entries: confirmation.snapshot.entries,
      reviews: confirmation.fileReviews
    )
    .workbenchAccessibilityContainer(identifier: "publish-worktree-file-list")
  }

  private var technicalDetails: some View {
    DisclosureGroup(String(localized: "技术细节")) {
      VStack(alignment: .leading, spacing: 6) {
        LabeledContent("提交说明", value: confirmation.commitMessage)
        LabeledContent(
          "本地版本",
          value: RepositoryWorktreePublishPresentation.shortSHA(confirmation.snapshot.headSHA))
        LabeledContent(
          "远端版本",
          value: RepositoryWorktreePublishPresentation.shortSHA(
            confirmation.snapshot.remoteBranchSHA))
        LabeledContent("origin", value: confirmation.snapshot.pushOriginURL)
          .textSelection(.enabled)
        if let preflight = confirmation.sitePreflightResult {
          Text(preflight.message)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .fixedSize(horizontal: false, vertical: true)
          ForEach(preflight.diagnostics, id: \.self) { diagnostic in
            Text(diagnostic)
              .font(.workbenchMetadata.monospaced())
              .foregroundStyle(.workbenchSecondary)
              .textSelection(.enabled)
          }
        }
        Text("确认时会再次核对文件和远端分支；如有变化会停止，不会强制推送。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.workbenchMetadata)
      .padding(.top, WorkbenchSpacing.tight)
    }
    .accessibilityIdentifier("publish-worktree-technical-details")
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("取消", action: cancelAction)
        .keyboardShortcut(.cancelAction)
        .disabled(isPublishing)

      Spacer()

      if isPublishing {
        ProgressView()
          .controlSize(.small)
        Text("正在提交并推送…")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }

      Button(
        actionTitle,
        action: confirmAction
      )
      .workbenchProminentActionStyle()
      .keyboardShortcut(.defaultAction)
      .disabled(isPublishing || !isReviewComplete || !canConfirmSafetyWarnings)
      .accessibilityIdentifier("publish-worktree-confirm")
      .accessibilityHint(
        confirmation.snapshot.entries.isEmpty
          ? String(localized: "再次核对已有提交后推送到远端")
          : String(localized: "再次核对文件后创建提交并推送到远端"))
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var isReviewComplete: Bool {
    RepositoryWorktreeFileReview.isComplete(
      entries: confirmation.snapshot.entries,
      reviews: confirmation.fileReviews
    ) && (outgoingHistory?.isHistoryReviewComplete ?? true)
  }

  private var canConfirmSafetyWarnings: Bool {
    RepositoryWorktreePublishConfirmationPresentationPolicy.canConfirm(
      isPublishing: isPublishing,
      isReviewComplete: isReviewComplete,
      requiresAcknowledgement: requiresSafetyAcknowledgement,
      acknowledgementGiven: safetyWarningsAcknowledged,
      historyReviewComplete: outgoingHistory?.isHistoryReviewComplete ?? true,
      historyAcknowledgementGiven: outgoingHistory == nil || outgoingHistoryAcknowledged,
      hasBlockingIssue: !confirmation.safetyReport.canPublish
        || confirmation.sitePreflightResult?.blocksPublication == true
        || confirmation.articlePreflightIssues.contains { $0.severity == .error }
    )
  }

  private var requiresSafetyAcknowledgement: Bool {
    RepositoryWorktreePublishConfirmationPresentationPolicy.requiresAcknowledgement(
      safetyWarningCount: confirmation.safetyReport.warnings.count,
      articleWarningCount: articleWarningIssues.count,
      sitePreflight: confirmation.sitePreflightResult,
    )
  }

  private var outgoingHistory: RepositoryWorktreePushRetrySnapshot? {
    confirmation.snapshot.outgoingHistory
  }
}

enum RepositoryWorktreePublishPresentation {
  struct ContentChangeSummary: Equatable {
    let bodyOperations: [String]
    let imageOperations: [String]
    let otherOperations: [String]
    let riskPaths: [String]

    var summaryText: String {
      var parts: [String] = []
      if !bodyOperations.isEmpty {
        parts.append(String(localized: "正文：\(bodyOperations.joined(separator: "、"))"))
      }
      if !imageOperations.isEmpty {
        parts.append(String(localized: "图片：\(imageOperations.joined(separator: "、"))"))
      }
      if !otherOperations.isEmpty {
        parts.append(String(localized: "其他：\(otherOperations.joined(separator: "、"))"))
      }
      return parts.isEmpty
        ? String(localized: "没有可识别的正文或图片变更。")
        : parts.joined(separator: "；")
    }
  }

  static func operationLabel(for entry: RepositoryWorktreePublishEntry) -> String {
    switch entry.kind {
    case .added: return String(localized: "新增")
    case .modified: return String(localized: "修改")
    case .deleted: return String(localized: "删除")
    case .renamed: return String(localized: "重命名")
    case .copied: return String(localized: "复制")
    case .typeChanged: return String(localized: "类型变化")
    }
  }

  static func contentChangeSummary(
    entries: [RepositoryWorktreePublishEntry], articlePath: String?
  ) -> ContentChangeSummary {
    let normalizedArticlePath = articlePath?.trimmingCharacters(in: .whitespacesAndNewlines)
    var body: [String] = []
    var images: [String] = []
    var other: [String] = []
    var risks: [String] = []
    for entry in entries {
      let paths = [entry.path, entry.sourcePath].compactMap { $0 }
      let isBody = normalizedArticlePath.map { paths.contains($0) } ?? false
      let isImage = paths.contains { path in
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"].contains(
          path.split(separator: ".").last?.lowercased() ?? ""
        )
      }
      let label = operationLabel(for: entry)
      if isBody {
        body.append(label)
      } else if isImage {
        images.append(label)
      } else {
        other.append(label)
      }
      if entry.kind == .deleted || entry.kind == .renamed {
        risks.append(pathDescription(for: entry))
      }
    }
    return ContentChangeSummary(
      bodyOperations: body, imageOperations: images, otherOperations: other, riskPaths: risks)
  }

  static func shortSHA(_ sha: String) -> String {
    String(sha.prefix(12))
  }

  static func pathDescription(for entry: RepositoryWorktreePublishEntry) -> String {
    guard let sourcePath = entry.sourcePath, sourcePath != entry.path else {
      return entry.path
    }
    return "\(sourcePath) → \(entry.path)"
  }

  static func metadataDescription(for entry: RepositoryWorktreePublishEntry) -> String {
    let mode = entry.mode.map { "mode \($0)" } ?? String(localized: "已从索引删除")
    return "\(entry.status) · \(mode)"
  }

  static func accessibilityLabel(for entry: RepositoryWorktreePublishEntry) -> String {
    "\(entry.kind.localizedName)，\(pathDescription(for: entry))，\(metadataDescription(for: entry))"
  }
}
