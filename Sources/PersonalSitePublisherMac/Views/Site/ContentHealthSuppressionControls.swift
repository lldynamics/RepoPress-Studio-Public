import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthSuppressionMenu: View {
  let row: ContentHealthIssueSelection
  let suppress: (PreflightIssue, UUID, ContentHealthSuppressionMode) -> Void

  private var eligibleArticles: [ContentHealthArticleRowModel] {
    row.articles.filter { $0.issues.contains(where: \.canSuppressInContentHealth) }
  }

  var body: some View {
    if !eligibleArticles.isEmpty {
      Menu {
        ForEach(eligibleArticles) { article in
          Section(article.draftTitle) {
            if let issue = article.issues.first(where: \.canSuppressInContentHealth) {
              Button("此文章忽略该规则") { suppress(issue, article.draftID, .articleRule) }
              Button("此站点忽略该规则") { suppress(issue, article.draftID, .siteRule) }
              Button("仅忽略当前问题") { suppress(issue, article.draftID, .baseline) }
            }
          }
        }
      } label: {
        Label("忽略", systemImage: "eye.slash")
      }
      .accessibilityLabel("忽略可选检查：\(row.title)")
      .accessibilityIdentifier("content-health-suppress-\(row.id)")
    }
  }
}

struct ContentHealthSuppressionControls: View {
  let configuredCount: Int
  let matchedCount: Int
  let canSaveBaseline: Bool
  let manage: () -> Void
  let saveBaseline: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchSpacing.control) { buttons }
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) { buttons }
      }
      Text("仅可选内容警告和提示可忽略。公开风险、仓库与路径检查、错误仍需处理。")
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      if matchedCount > 0 {
        Text("本次检查已忽略 \(matchedCount) 项。")
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("content-health-suppression-controls")
  }

  private var buttons: some View {
    Group {
      Button(action: saveBaseline) {
        Label("保存当前问题基线", systemImage: "bookmark")
      }
      .disabled(!canSaveBaseline)
      .help("仅保存当前可忽略问题；问题内容变化后会重新显示。")
      .accessibilityIdentifier("content-health-save-baseline")
      Button(action: manage) {
        Label("已忽略设置（\(configuredCount)）", systemImage: "eye.slash")
      }
      .accessibilityIdentifier("content-health-manage-suppressions")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }
}

struct ContentHealthSuppressionSheet: View {
  let store: WorkbenchStore
  let profileID: UUID
  @ObservedObject var healthState: WorkbenchContentHealthFeatureFacade
  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      Text("已忽略的检查")
        .font(.workbenchPageTitle)
      Text("规则忽略适用于后续检查；问题基线只匹配保存时的问题内容。恢复后会重新检查。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
      if let errorMessage {
        AccessibleStatusMessage(message: errorMessage, severity: .error)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          if store.contentHealthSuppressions.isEmpty {
            Text("此站点没有已忽略的检查。")
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
          }
          ForEach(store.contentHealthSuppressions) { suppression in
            row(suppression)
          }
        }
      }
      HStack(spacing: WorkbenchSpacing.control) {
        Button("全部恢复") {
          if !store.restoreAllContentHealthSuppressions(profileID: profileID) {
            errorMessage = String(localized: "忽略设置未能保存，请重新检查或确认存储状态后重试。")
          }
        }
        .disabled(store.contentHealthSuppressions.isEmpty || store.activeProfileID != profileID)
        .accessibilityIdentifier("content-health-restore-all")
        Spacer(minLength: 0)
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(WorkbenchSpacing.page)
    .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 520)
    .onChange(of: store.activeProfileID) { _, _ in dismiss() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("已忽略的检查")
  }

  private func row(_ suppression: ContentHealthSuppression) -> some View {
    HStack(alignment: .top, spacing: WorkbenchSpacing.control) {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
        Text(ContentHealthSuppressionPresentation.ruleTitle(suppression.ruleID))
          .font(.workbenchItemTitle)
        Text(scopeTitle(suppression))
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
        if suppression.mode == .baseline {
          Text("问题变化后自动重新显示")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      Button("恢复") {
        errorMessage = nil
        if !store.restoreContentHealthSuppression(suppression) {
          errorMessage = String(localized: "忽略设置未能保存，请重新检查或确认存储状态后重试。")
        }
      }
      .disabled(store.activeProfileID != profileID)
      .accessibilityLabel(
        "恢复检查：\(ContentHealthSuppressionPresentation.ruleTitle(suppression.ruleID))"
      )
      .accessibilityIdentifier("content-health-restore-\(suppression.id)")
    }
    .padding(WorkbenchSpacing.card)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func scopeTitle(_ suppression: ContentHealthSuppression) -> String {
    if suppression.mode == .siteRule { return String(localized: "整个站点 · 规则忽略") }
    let title: String
    if let draftID = suppression.draftID, let draft = store.draft(for: draftID) {
      title = store.privateContentDisplay(for: draft).title
    } else {
      title = String(localized: "原文章已移除")
    }
    return suppression.mode == .baseline
      ? String(localized: "\(title) · 问题基线") : String(localized: "\(title) · 规则忽略")
  }
}

enum ContentHealthSuppressionPresentation {
  static func ruleTitle(_ ruleID: String) -> String {
    switch ContentHealthRuleID(rawValue: ruleID) {
    case .shortBody: String(localized: "正文偏短")
    case .draftFlag: String(localized: "仍是草稿")
    case .futureDate: String(localized: "日期在未来")
    case .slugFormat: String(localized: "Slug 格式非法")
    case .missingMediaAlt: String(localized: "图片缺少 alt")
    case .unregisteredBodyImage: String(localized: "正文图片未登记")
    case .missingCaption: String(localized: "图片缺少说明")
    case .largeFile: String(localized: "图片体积偏大")
    case .largeDimensions: String(localized: "图片尺寸偏大")
    case .unreferencedAttachment: String(localized: "图片未在正文引用")
    case .duplicateMarkdownReference: String(localized: "图片重复引用")
    case .missingCoverAttachment: String(localized: "封面图片缺失")
    case .brokenInternalLink: String(localized: "内部链接无法解析")
    case .unreachableExternalLink: String(localized: "外部链接无法访问")
    case .none: String(localized: "未知检查规则")
    }
  }
}

/// Editorial notices stay separate from blocking counts, but retain the same ignore controls.
struct ContentHealthOptionalNotices: View {
  let summaries: [DraftPreflightSummary]
  let suppress: (PreflightIssue, UUID, ContentHealthSuppressionMode) -> Void

  private var articles: [DraftPreflightSummary] {
    summaries.filter {
      $0.issues.contains { $0.severity == .info && $0.canSuppressInContentHealth }
    }
  }

  var body: some View {
    if !articles.isEmpty {
      DisclosureGroup("可选内容提示") {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
          ForEach(articles) { summary in
            VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
              Text(summary.draftTitle)
                .font(.workbenchItemTitle)
              ForEach(
                summary.issues.filter { $0.severity == .info && $0.canSuppressInContentHealth }
              ) { issue in
                HStack(alignment: .top, spacing: WorkbenchSpacing.control) {
                  ContentHealthIssueCard(issue: issue)
                  Menu {
                    Button("此文章忽略该规则") { suppress(issue, summary.draftID, .articleRule) }
                    Button("此站点忽略该规则") { suppress(issue, summary.draftID, .siteRule) }
                    Button("仅忽略当前问题") { suppress(issue, summary.draftID, .baseline) }
                  } label: {
                    Label("忽略", systemImage: "eye.slash")
                  }
                  .accessibilityLabel("忽略可选检查：\(issue.title)")
                }
              }
            }
          }
        }
        .padding(.top, WorkbenchSpacing.control)
      }
      .font(.workbenchSupporting)
      .padding(WorkbenchSpacing.card)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .accessibilityIdentifier("content-health-optional-notices")
    }
  }
}
