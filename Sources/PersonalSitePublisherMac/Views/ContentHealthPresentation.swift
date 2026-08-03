import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum ContentHealthIssueScopeFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case publicRisks
  case aiFixes
  case siteIssues

  var id: String { rawValue }

  init(legacyFilter: ContentHealthContextFilter) {
    switch legacyFilter {
    case .publicRisks:
      self = .publicRisks
    case .aiFixes:
      self = .aiFixes
    case .siteIssues:
      self = .siteIssues
    case .overview, .maintenance:
      self = .all
    }
  }

  var title: String {
    switch self {
    case .all:
      return String(localized: "全部问题")
    case .publicRisks:
      return String(localized: "公开风险")
    case .aiFixes:
      return String(localized: "AI 可修复")
    case .siteIssues:
      return String(localized: "站点级问题")
    }
  }

  var systemImage: String {
    switch self {
    case .all:
      return "checklist"
    case .publicRisks:
      return "exclamationmark.shield"
    case .aiFixes:
      return "sparkles"
    case .siteIssues:
      return "globe.badge.chevron.backward"
    }
  }
}

enum ContentHealthSeverityFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case errors
  case warnings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      return String(localized: "全部")
    case .errors:
      return String(localized: "错误")
    case .warnings:
      return String(localized: "警告")
    }
  }

  func filter(_ issues: [PreflightIssue]) -> [PreflightIssue] {
    switch self {
    case .all:
      return issues
    case .errors:
      return issues.filter { $0.severity == .error }
    case .warnings:
      return issues.filter { $0.severity == .warning }
    }
  }
}

struct ContentHealthArticlePresentation: Sendable {
  let snapshotID: UUID
  let issueScope: ContentHealthIssueScopeFilter
  let severityFilter: ContentHealthSeverityFilter
  let rows: [ContentHealthArticleRowModel]
  let rowByDraftID: [UUID: ContentHealthArticleRowModel]
  let siteIssues: [PreflightIssue]
  let recommendedAIFixItem: AIPublishingFixQueueItem?
  let duplicateMarkdownPaths: Set<String>
  let actionQueue: ContentHealthActionQueue

  init(
    snapshot: ContentHealthSnapshot,
    issueScope: ContentHealthIssueScopeFilter,
    severityFilter: ContentHealthSeverityFilter
  ) {
    var aiFixItemByDraftID: [UUID: AIPublishingFixQueueItem] = [:]
    if DistributionFeaturePolicy.allowsExternalAIProviders {
      for item in snapshot.aiFixQueueItems where aiFixItemByDraftID[item.draftID] == nil {
        aiFixItemByDraftID[item.draftID] = item
      }
    }

    let sourceSummaries: [DraftPreflightSummary]
    switch issueScope {
    case .all:
      sourceSummaries = snapshot.contentHealthSummaries
    case .publicRisks:
      sourceSummaries = snapshot.publicRiskDraftSummaries
    case .aiFixes:
      sourceSummaries = snapshot.contentHealthSummaries.filter {
        aiFixItemByDraftID[$0.draftID] != nil
      }
    case .siteIssues:
      sourceSummaries = []
    }

    let rows = sourceSummaries.compactMap { summary -> ContentHealthArticleRowModel? in
      let sourceIssues: [PreflightIssue]
      switch issueScope {
      case .publicRisks:
        sourceIssues = summary.publicRiskIssues
      case .all, .aiFixes, .siteIssues:
        sourceIssues = summary.blockingIssues
      }
      let issues = severityFilter.filter(sourceIssues)
      guard !issues.isEmpty else { return nil }
      return ContentHealthArticleRowModel(
        summary: summary,
        issues: issues,
        aiFixItem: aiFixItemByDraftID[summary.draftID]
      )
    }

    var rowByDraftID: [UUID: ContentHealthArticleRowModel] = [:]
    for row in rows {
      rowByDraftID[row.draftID] = row
    }
    let visibleDraftIDs = Set(rowByDraftID.keys)
    let pathCounts = Dictionary(grouping: rows, by: \.normalizedMarkdownPath)
      .mapValues(\.count)

    snapshotID = snapshot.id
    self.issueScope = issueScope
    self.severityFilter = severityFilter
    self.rows = rows
    self.rowByDraftID = rowByDraftID
    let duplicateMarkdownPaths = Set(
      pathCounts.compactMap { path, count in count > 1 ? path : nil }
    )
    self.duplicateMarkdownPaths = duplicateMarkdownPaths
    actionQueue = ContentHealthActionQueue(
      rows: rows,
      duplicateMarkdownPaths: duplicateMarkdownPaths
    )
    siteIssues = severityFilter.filter(snapshot.sitePreflightIssues)
    recommendedAIFixItem =
      DistributionFeaturePolicy.allowsExternalAIProviders
      ? snapshot.aiFixQueueItems.first { visibleDraftIDs.contains($0.draftID) }
      : nil
  }

  func matches(
    snapshotID: UUID,
    issueScope: ContentHealthIssueScopeFilter,
    severityFilter: ContentHealthSeverityFilter
  ) -> Bool {
    self.snapshotID == snapshotID
      && self.issueScope == issueScope
      && self.severityFilter == severityFilter
  }
}

struct ContentHealthSnapshot: Sendable {
  var id: UUID
  var generatedAt: Date
  var profileID: UUID
  var profileName: String
  var publicRiskDraftSummaries: [DraftPreflightSummary]
  var aiFixQueueItems: [AIPublishingFixQueueItem]
  var sitePreflightIssues: [PreflightIssue]
  var contentHealthSummaries: [DraftPreflightSummary]
  var errorCount: Int
  var warningCount: Int
  var passingDraftCount: Int
}

struct ContentHealthPresentationService: Sendable {
  func snapshot(
    profileID: UUID,
    profileName: String,
    report: ContentHealthReport,
    generatedAt: Date = Date()
  ) async throws -> ContentHealthSnapshot {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      var errorCount = report.sitePreflightIssues.reduce(into: 0) { count, issue in
        if issue.severity == .error { count += 1 }
      }
      var warningCount = report.sitePreflightIssues.reduce(into: 0) { count, issue in
        if issue.severity == .warning { count += 1 }
      }
      var passingDraftCount = 0
      for summary in report.draftSummaries {
        try Task.checkCancellation()
        var draftHasBlockingIssue = false
        for issue in summary.issues {
          switch issue.severity {
          case .error:
            errorCount += 1
            draftHasBlockingIssue = true
          case .warning:
            warningCount += 1
            draftHasBlockingIssue = true
          case .info:
            break
          }
        }
        if !draftHasBlockingIssue {
          passingDraftCount += 1
        }
      }
      return ContentHealthSnapshot(
        id: UUID(),
        generatedAt: generatedAt,
        profileID: profileID,
        profileName: profileName,
        publicRiskDraftSummaries: report.publicRiskDraftSummaries,
        aiFixQueueItems: report.aiFixQueueItems,
        sitePreflightIssues: report.sitePreflightIssues,
        contentHealthSummaries: report.draftSummaries,
        errorCount: errorCount,
        warningCount: warningCount,
        passingDraftCount: passingDraftCount
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func articlePresentation(
    snapshot: ContentHealthSnapshot,
    issueScope: ContentHealthIssueScopeFilter,
    severityFilter: ContentHealthSeverityFilter
  ) async throws -> ContentHealthArticlePresentation {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      return ContentHealthArticlePresentation(
        snapshot: snapshot,
        issueScope: issueScope,
        severityFilter: severityFilter
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

struct ContentHealthAIFixResultPreview: Identifiable {
  let id = UUID()
  let draftTitle: String
  let result: AIPublishingActionResult
}

struct ContentHealthAIFixResultPreviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let preview: ContentHealthAIFixResultPreview

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("AI 修复结果预览", systemImage: "sparkles.rectangle.stack")
          .font(.headline)
        Spacer()
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(preview.draftTitle)
            .font(.title3.weight(.semibold))
          if !preview.result.providerName.isEmpty || !preview.result.model.isEmpty {
            Text(
              [preview.result.providerName, preview.result.model].filter { !$0.isEmpty }.joined(
                separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Text(preview.result.content)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
      }
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
    .accessibilityLabel("AI 修复结果预览")
  }
}

struct ContentHealthIssueCard: View {
  let issue: PreflightIssue
  let onFocus: (() -> Void)?

  init(issue: PreflightIssue, onFocus: (() -> Void)? = nil) {
    self.issue = issue
    self.onFocus = onFocus
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      SeverityBadge(severity: issue.severity)
      Text(issue.title)
        .font(.workbenchItemTitle)
      Text(issue.message)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let onFocus {
        HStack {
          Spacer(minLength: 0)
          Button {
            onFocus()
          } label: {
            Label("定位到\(issue.contentHealthFocusTargetTitle)", systemImage: "arrow.right.circle")
          }
          .buttonStyle(.link)
          .controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension PreflightIssue {
  var contentHealthFocusTargetTitle: String {
    switch structuredField {
    case .body:
      return String(localized: "正文")
    case .summary:
      return String(localized: "摘要")
    case .attachments, .cover, .coverAlt:
      return String(localized: "图片")
    case .repository, .contentRoot, .assetRoot, .markdownPathPattern, .repositoryPath:
      return String(localized: "仓库")
    default:
      return String(localized: "元数据")
    }
  }
}
