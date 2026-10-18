import Foundation
import PublishingWorkbenchCore

enum ContentHealthIssueSection: String, CaseIterable, Sendable {
  case errors, warnings, optimizations, maintenance

  var title: String {
    switch self {
    case .errors: String(localized: "错误")
    case .warnings: String(localized: "警告")
    case .optimizations: String(localized: "优化建议")
    case .maintenance: String(localized: "维护")
    }
  }

  var systemImage: String {
    switch self {
    case .errors: "xmark.octagon"
    case .warnings: "exclamationmark.triangle"
    case .optimizations: "wand.and.stars"
    case .maintenance: "wrench.and.screwdriver"
    }
  }
}

/// A presentation-only selection. It retains every affected article/issue or
/// maintenance task so an inspector can bind to it without rescanning.
struct ContentHealthIssueSelection: Identifiable, Equatable, Sendable {
  let id: String
  let section: ContentHealthIssueSection
  let title: String
  let detail: String
  let subgroup: String?
  let articles: [ContentHealthArticleRowModel]
  let siteIssues: [PreflightIssue]
  let maintenanceItems: [MaintenanceActionItem]

  var occurrenceCount: Int {
    articles.reduce(0) { $0 + $1.issues.count } + siteIssues.count + maintenanceItems.count
  }

  var affectedArticleCount: Int {
    Set(articles.map(\.draftID) + maintenanceItems.compactMap(\.draftID)).count
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.section == rhs.section && lhs.title == rhs.title
      && lhs.detail == rhs.detail && lhs.subgroup == rhs.subgroup
      && lhs.siteIssues == rhs.siteIssues && lhs.maintenanceItems == rhs.maintenanceItems
      && lhs.articles.count == rhs.articles.count
      && zip(lhs.articles, rhs.articles).allSatisfy { left, right in
        left.draftID == right.draftID && left.draftTitle == right.draftTitle
          && left.markdownPath == right.markdownPath && left.issues == right.issues
          && left.aiFixItem == right.aiFixItem
      }
  }
}

enum ContentHealthCountFilter: String {
  case errors, warnings, optimizations, maintenance

  func isSelected(severity: ContentHealthSeverityFilter, source: ContentHealthSourceFilter) -> Bool
  {
    switch self {
    case .errors: severity == .errors && source != .maintenance
    case .warnings: severity == .warnings && source != .maintenance
    case .optimizations: severity == .optimizations && source != .maintenance
    case .maintenance: source == .maintenance
    }
  }

  func toggled(
    severity: ContentHealthSeverityFilter, source: ContentHealthSourceFilter
  ) -> (severity: ContentHealthSeverityFilter, source: ContentHealthSourceFilter) {
    if isSelected(severity: severity, source: source) { return (.all, .all) }
    switch self {
    case .errors: return (.errors, .all)
    case .warnings: return (.warnings, .all)
    case .optimizations: return (.optimizations, .all)
    case .maintenance: return (.all, .maintenance)
    }
  }
}

enum ContentHealthIssueListProjection {
  static func rows(
    articles: [ContentHealthArticleRowModel],
    siteIssues: [PreflightIssue],
    maintenanceItems: [MaintenanceActionItem],
    grouping: ContentHealthArticleGrouping,
    profileName: String,
    search: String
  ) -> [ContentHealthIssueSelection] {
    var result: [ContentHealthIssueSelection] = []
    var articleGroups: [String: [ContentHealthArticleRowModel]] = [:]
    var groupIssues: [String: PreflightIssue] = [:]
    var subgroups: [String: String] = [:]

    for article in articles {
      for issue in article.issues where issue.severity != .info {
        guard
          matches(
            search, values: [article.draftTitle, article.markdownPath, issue.title, issue.message])
        else {
          continue
        }
        let partition: String
        let subgroup: String?
        switch grouping {
        case .actionQueue:
          partition = ""
          subgroup = nil
        case .automaticFix:
          partition = article.aiFixItem == nil ? "manual" : "ai"
          subgroup =
            article.aiFixItem == nil
            ? String(localized: "需要手动处理") : String(localized: "可用 AI 修复")
        case .site:
          partition = "site"
          subgroup = profileName
        case .file:
          partition = article.draftID.uuidString
          subgroup = article.markdownPath
        }
        let key = "article:" + identity([partition] + issueIdentity(issue))
        let member = ContentHealthArticleRowModel(
          summary: DraftPreflightSummary(
            draftID: article.draftID, draftTitle: article.draftTitle,
            markdownPath: article.markdownPath, issues: [issue]
          ),
          issues: [issue], aiFixItem: article.aiFixItem
        )
        articleGroups[key, default: []].append(member)
        groupIssues[key] = issue
        subgroups[key] = subgroup
      }
    }
    for (key, members) in articleGroups {
      guard let issue = groupIssues[key] else { continue }
      let merged = Dictionary(grouping: members, by: \.draftID).values.compactMap { items in
        guard let first = items.first else { return nil as ContentHealthArticleRowModel? }
        let issues = items.flatMap(\.issues)
        return ContentHealthArticleRowModel(
          summary: DraftPreflightSummary(
            draftID: first.draftID, draftTitle: first.draftTitle,
            markdownPath: first.markdownPath, issues: issues
          ), issues: issues, aiFixItem: first.aiFixItem
        )
      }.sorted { $0.draftID.uuidString < $1.draftID.uuidString }
      result.append(
        ContentHealthIssueSelection(
          id: key, section: issueSection(for: issue),
          title: issue.title, detail: issue.message, subgroup: subgroups[key],
          articles: merged, siteIssues: [], maintenanceItems: []
        ))
    }

    let matchedSiteIssues = siteIssues.filter {
      $0.severity != .info && matches(search, values: [$0.title, $0.message, $0.field ?? ""])
    }
    for (key, issues) in Dictionary(
      grouping: matchedSiteIssues, by: { identity(issueIdentity($0)) })
    {
      guard let first = issues.first else { continue }
      result.append(
        ContentHealthIssueSelection(
          id: "site:" + key, section: issueSection(for: first),
          title: first.title, detail: first.message, subgroup: nil,
          articles: [], siteIssues: issues, maintenanceItems: []
        ))
    }

    let matchedMaintenance = maintenanceItems.filter {
      matches(search, values: [$0.title, $0.summary, $0.detail, $0.targetPath ?? ""])
    }
    for (key, items) in Dictionary(
      grouping: matchedMaintenance,
      by: { item in
        identity([item.kind.rawValue, String(item.priority.rawValue), maintenanceTitle(item)])
      })
    {
      let sorted = items.sorted { $0.id < $1.id }
      guard let first = sorted.first else { continue }
      result.append(
        ContentHealthIssueSelection(
          id: "maintenance:" + key, section: .maintenance,
          title: maintenanceTitle(first), detail: first.summary, subgroup: nil,
          articles: [], siteIssues: [], maintenanceItems: sorted
        ))
    }

    return result.sorted { left, right in
      let leftRank = ContentHealthIssueSection.allCases.firstIndex(of: left.section) ?? 0
      let rightRank = ContentHealthIssueSection.allCases.firstIndex(of: right.section) ?? 0
      if leftRank != rightRank { return leftRank < rightRank }
      let leftPriority = left.maintenanceItems.first?.priority.rawValue ?? 0
      let rightPriority = right.maintenanceItems.first?.priority.rawValue ?? 0
      if leftPriority != rightPriority { return leftPriority < rightPriority }
      if left.subgroup != right.subgroup { return (left.subgroup ?? "") < (right.subgroup ?? "") }
      let order = left.title.localizedStandardCompare(right.title)
      return order == .orderedSame ? left.id < right.id : order == .orderedAscending
    }
  }

  static func reconciled(
    _ selection: ContentHealthIssueSelection?, rows: [ContentHealthIssueSelection]
  ) -> ContentHealthIssueSelection? {
    guard let selection else { return nil }
    return rows.first { $0.id == selection.id }
  }

  static func moved(
    _ selection: ContentHealthIssueSelection?, offset: Int, rows: [ContentHealthIssueSelection]
  ) -> ContentHealthIssueSelection? {
    guard !rows.isEmpty else { return nil }
    guard let index = rows.firstIndex(where: { $0.id == selection?.id }) else {
      return offset < 0 ? rows.last : rows.first
    }
    return rows[min(max(index + offset, 0), rows.count - 1)]
  }

  private static func issueIdentity(_ issue: PreflightIssue) -> [String] {
    [
      issue.severity.rawValue, issue.category?.rawValue ?? "", issue.field ?? "",
      issue.code?.rawValue ?? "", issue.title,
    ]
  }

  private static func issueSection(for issue: PreflightIssue) -> ContentHealthIssueSection {
    if issue.isOptionalOptimization { return .optimizations }
    return issue.severity == .error ? .errors : .warnings
  }

  private static func identity(_ values: [String]) -> String {
    // Length-prefix each component so titles/paths containing delimiters cannot collide.
    values.map { "\($0.utf8.count):\($0)" }.joined()
  }

  private static func maintenanceTitle(_ item: MaintenanceActionItem) -> String {
    guard item.draftID != nil, let separator = item.title.firstIndex(of: "：") else {
      return item.title
    }
    return String(item.title[..<separator])
  }

  private static func matches(_ query: String, values: [String]) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    let text = values.joined(separator: " ")
    return words.allSatisfy { text.localizedStandardContains(String($0)) }
  }
}

/// A retained snapshot is evidence from the previous scan, not proof that a
/// pending or failed refresh has completed successfully.
enum ContentHealthMaintenanceScanPresentation {
  enum Status: Equatable {
    case ready
    case loading
    case stale
    case failed(String)
  }

  static func status(
    hasSnapshot: Bool, isRefreshing: Bool, isStale: Bool = false, errorMessage: String?
  ) -> Status {
    if isRefreshing { return .loading }
    if let errorMessage { return .failed(errorMessage) }
    if isStale { return .stale }
    return hasSnapshot ? .ready : .loading
  }
}

extension MaintenanceActionItem {
  /// Used in the menu header as well as in individual action labels. Two
  /// link tasks can share a title but must still expose their distinct targets.
  var contentHealthActionTarget: String {
    [summary, detail, targetPath ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
