import Foundation
import PublishingWorkbenchCore
import SwiftUI

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
  let filter: ContentHealthContextFilter
  let severityFilter: ContentHealthSeverityFilter
  let rows: [ContentHealthArticleRowModel]
  let rowByDraftID: [UUID: ContentHealthArticleRowModel]
  let siteIssues: [PreflightIssue]
  let recommendedAIFixItem: AIPublishingFixQueueItem?
  let duplicateMarkdownPaths: Set<String>
  let actionQueue: ContentHealthActionQueue

  init(
    snapshot: ContentHealthSnapshot,
    filter: ContentHealthContextFilter,
    severityFilter: ContentHealthSeverityFilter
  ) {
    var aiFixItemByDraftID: [UUID: AIPublishingFixQueueItem] = [:]
    for item in snapshot.aiFixQueueItems where aiFixItemByDraftID[item.draftID] == nil {
      aiFixItemByDraftID[item.draftID] = item
    }

    let sourceSummaries: [DraftPreflightSummary]
    switch filter {
    case .overview, .maintenance:
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
      switch filter {
      case .publicRisks:
        sourceIssues = summary.publicRiskIssues
      case .overview, .aiFixes, .siteIssues, .maintenance:
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
    self.filter = filter
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
    recommendedAIFixItem = snapshot.aiFixQueueItems.first {
      visibleDraftIDs.contains($0.draftID)
    }
  }

  func matches(
    snapshotID: UUID,
    filter: ContentHealthContextFilter,
    severityFilter: ContentHealthSeverityFilter
  ) -> Bool {
    self.snapshotID == snapshotID
      && self.filter == filter
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
    filter: ContentHealthContextFilter,
    severityFilter: ContentHealthSeverityFilter
  ) async throws -> ContentHealthArticlePresentation {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      return ContentHealthArticlePresentation(
        snapshot: snapshot,
        filter: filter,
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

struct FrontMatterFixFieldItem: Identifiable, Hashable {
  let id: String
  let fieldKey: String
  let title: String
  let proposedValue: String
  var isSelected: Bool
}

struct ContentHealthAIFixResultPreview: Identifiable {
  let id = UUID()
  var draftID: UUID? = nil
  let draftTitle: String
  let result: AIPublishingActionResult
}

struct ContentHealthAIFixResultPreviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let preview: ContentHealthAIFixResultPreview
  var onApply: (([FrontMatterFixFieldItem]) -> Void)? = nil

  @State private var fields: [FrontMatterFixFieldItem] = []
  @State private var previewTab: PreviewTab = .fields

  private enum PreviewTab: String, CaseIterable, Identifiable {
    case fields = "逐项勾选"
    case raw = "完整响应"

    var id: String { rawValue }
  }

  init(
    preview: ContentHealthAIFixResultPreview,
    onApply: (([FrontMatterFixFieldItem]) -> Void)? = nil
  ) {
    self.preview = preview
    self.onApply = onApply
    _fields = State(initialValue: Self.parseFields(from: preview.result))
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      Picker("预览视图", selection: $previewTab) {
        ForEach(PreviewTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 240)
      .padding(.vertical, 10)

      Divider()

      if previewTab == .fields {
        fieldsContent
      } else {
        rawResponseContent
      }

      Divider()

      footer
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
    .accessibilityLabel("AI 修复结果预览")
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Label("AI 修复结果预览", systemImage: "sparkles.rectangle.stack")
          .font(.headline)
        Text(preview.draftTitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !preview.result.providerName.isEmpty || !preview.result.model.isEmpty {
        Text(
          [preview.result.providerName, preview.result.model].filter { !$0.isEmpty }.joined(
            separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(WorkbenchBackgroundStyle.control, in: Capsule())
      }

      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(14)
  }

  private var fieldsContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        let selectedCount = fields.filter(\.isSelected).count
        Text("选择要应用的 Front Matter 字段（已选 \(selectedCount)/\(fields.count) 项）：")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer()

        Button("全选") {
          for i in fields.indices {
            fields[i].isSelected = true
          }
        }
        .buttonStyle(.borderless)
        .font(.caption)

        Button("全部取消") {
          for i in fields.indices {
            fields[i].isSelected = false
          }
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)

      if fields.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            Text("未能自动切分出独立字段，可切换至“完整响应”查看或直接应用全量修复内容。")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(preview.result.content)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
          }
          .padding(16)
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach($fields) { $item in
              HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: $item.isSelected)
                  .toggleStyle(.checkbox)
                  .labelsHidden()
                  .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 6) {
                    Text(item.title)
                      .font(.caption.weight(.semibold))
                    Text(item.fieldKey)
                      .font(.caption.monospaced())
                      .foregroundStyle(.secondary)
                      .padding(.horizontal, 4)
                      .padding(.vertical, 1)
                      .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 3))
                  }

                  Text(item.proposedValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                      item.isSelected
                        ? AnyShapeStyle(WorkbenchTheme.success.opacity(0.06))
                        : WorkbenchBackgroundStyle.control,
                      in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay {
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(
                          item.isSelected ? WorkbenchTheme.success.opacity(0.3) : Color.clear,
                          lineWidth: 1
                        )
                    }
                }
              }
              .padding(8)
              .background(
                WorkbenchBackgroundStyle.card,
                in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              )
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 6)
        }
      }
    }
  }

  private var rawResponseContent: some View {
    ScrollView {
      Text(preview.result.content)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18)
    }
  }

  private var footer: some View {
    HStack {
      Button("放弃全部", role: .cancel) {
        dismiss()
      }

      Spacer()

      let selectedFields = fields.filter(\.isSelected)
      Button {
        if !selectedFields.isEmpty {
          onApply?(selectedFields)
        } else {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(preview.result.content, forType: .string)
        }
        dismiss()
      } label: {
        Label(
          selectedFields.isEmpty ? "复制完整内容" : "应用所选 \(selectedFields.count) 个字段",
          systemImage: "checkmark.circle"
        )
      }
      .workbenchProminentActionStyle()
    }
    .padding(14)
  }

  private static func parseFields(from result: AIPublishingActionResult) -> [FrontMatterFixFieldItem] {
    var items: [FrontMatterFixFieldItem] = []

    if let suggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(from: result) {
      if let title = suggestion.titles.first, !title.isEmpty {
        items.append(FrontMatterFixFieldItem(id: "title", fieldKey: "title", title: "标题", proposedValue: title, isSelected: true))
      }
      if let slug = suggestion.slugs.first, !slug.isEmpty {
        items.append(FrontMatterFixFieldItem(id: "slug", fieldKey: "slug", title: "Slug", proposedValue: slug, isSelected: true))
      }
      if let summary = suggestion.summary, !summary.isEmpty {
        items.append(FrontMatterFixFieldItem(id: "summary", fieldKey: "summary", title: "摘要", proposedValue: summary, isSelected: true))
      }
      if !suggestion.tags.isEmpty {
        items.append(FrontMatterFixFieldItem(id: "tags", fieldKey: "tags", title: "标签", proposedValue: suggestion.tags.joined(separator: ", "), isSelected: true))
      }
    }

    if items.isEmpty {
      let lines = result.content.components(separatedBy: .newlines)
      var currentKey: String?
      var currentValueLines: [String] = []

      for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("---"), !line.hasPrefix("```") else { continue }

        if let colonIndex = line.firstIndex(of: ":"), !line.hasPrefix("-") {
          if let key = currentKey {
            items.append(FrontMatterFixFieldItem(
              id: key,
              fieldKey: key,
              title: localizedKeyTitle(key),
              proposedValue: currentValueLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
              isSelected: true
            ))
            currentValueLines.removeAll()
          }
          let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
          let val = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
          currentKey = key
          if !val.isEmpty {
            currentValueLines.append(val)
          }
        } else if currentKey != nil {
          currentValueLines.append(line)
        }
      }

      if let key = currentKey, !currentValueLines.isEmpty {
        items.append(FrontMatterFixFieldItem(
          id: key,
          fieldKey: key,
          title: localizedKeyTitle(key),
          proposedValue: currentValueLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
          isSelected: true
        ))
      }
    }

    return items
  }

  private static func localizedKeyTitle(_ key: String) -> String {
    switch key.lowercased() {
    case "title": return "标题"
    case "slug": return "Slug"
    case "summary", "description": return "摘要"
    case "tags": return "标签"
    case "date": return "日期"
    case "aliases": return "别名"
    case "categories": return "分类"
    case "draft": return "草稿状态"
    default: return key.capitalized
    }
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
