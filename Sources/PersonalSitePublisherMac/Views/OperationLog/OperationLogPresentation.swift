import Foundation

/// A value-only projection for the activity-record window.  The projection is
/// deliberately limited to fields that are safe to render and search, so the
/// UI never needs to inspect the underlying operation records.
enum OperationLogPresentation {
  enum Category: String, CaseIterable, Hashable, Sendable {
    case publishing
    case maintenance
    case automation
    case ai
    case deployment
    case importing
    case images
    case backup

    var title: String {
      switch self {
      case .publishing: String(localized: "发布")
      case .maintenance: String(localized: "维护")
      case .automation: String(localized: "自动化")
      case .ai: String(localized: "AI")
      case .deployment: String(localized: "部署")
      case .importing: String(localized: "导入")
      case .images: String(localized: "图片")
      case .backup: String(localized: "备份")
      }
    }
  }

  enum Outcome: String, CaseIterable, Hashable, Sendable {
    case succeeded
    case partial
    case failed
    case cancelled
    case recorded
    case observed

    var title: String {
      switch self {
      case .succeeded: String(localized: "已完成")
      case .partial: String(localized: "部分完成")
      case .failed: String(localized: "失败")
      case .cancelled: String(localized: "已取消")
      case .recorded: String(localized: "已记录")
      case .observed: String(localized: "已观察")
      }
    }
  }

  enum Actor: String, CaseIterable, Hashable, Sendable {
    case user
    case automation
    case background

    var title: String {
      switch self {
      case .user: String(localized: "用户")
      case .automation: String(localized: "自动化")
      case .background: String(localized: "后台")
      }
    }
  }

  enum TimeRange: String, CaseIterable, Hashable, Sendable {
    case all
    case today
    case last7Days
    case last30Days

    var title: String {
      switch self {
      case .all: String(localized: "全部时间")
      case .today: String(localized: "今天")
      case .last7Days: String(localized: "近 7 天")
      case .last30Days: String(localized: "近 30 天")
      }
    }
  }

  /// UI-owned mirror of the persistence policy. Keeping this value type in
  /// the presentation layer lets the window remain independent of Core while
  /// the scene performs the small boundary mapping.
  enum RetentionPolicy: String, CaseIterable, Hashable, Identifiable, Sendable {
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    var id: String { rawValue }

    var title: String {
      switch self {
      case .thirtyDays: String(localized: "30 天")
      case .ninetyDays: String(localized: "90 天")
      case .oneYear: String(localized: "1 年")
      case .forever: String(localized: "永久保留")
      }
    }
  }

  struct SiteProfileOption: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
  }

  struct Entry: Identifiable, Hashable, Sendable {
    let id: String
    let sourceLabel: String
    let category: Category
    let categoryDisplayName: String
    let outcome: Outcome
    let outcomeDisplayName: String
    let actor: Actor
    let actorDisplayName: String
    let title: String
    let summary: String
    let profileID: UUID?
    let targetLabel: String?
    let occurredAt: Date
    let systemImage: String

    init(
      id: String,
      sourceLabel: String,
      category: Category,
      categoryDisplayName: String? = nil,
      outcome: Outcome,
      outcomeDisplayName: String? = nil,
      actor: Actor,
      actorDisplayName: String? = nil,
      title: String,
      summary: String,
      profileID: UUID? = nil,
      targetLabel: String? = nil,
      occurredAt: Date,
      systemImage: String
    ) {
      self.id = id
      self.sourceLabel = sourceLabel
      self.category = category
      self.categoryDisplayName = categoryDisplayName ?? category.title
      self.outcome = outcome
      self.outcomeDisplayName = outcomeDisplayName ?? outcome.title
      self.actor = actor
      self.actorDisplayName = actorDisplayName ?? actor.title
      self.title = title
      self.summary = summary
      self.profileID = profileID
      let normalizedTarget = targetLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self.targetLabel = normalizedTarget.isEmpty ? nil : normalizedTarget
      self.occurredAt = occurredAt
      self.systemImage = systemImage
    }

    fileprivate var searchableText: [String] {
      [
        sourceLabel,
        categoryDisplayName,
        outcomeDisplayName,
        actorDisplayName,
        title,
        summary,
        targetLabel ?? "",
      ]
    }
  }

  struct Filters: Equatable, Sendable {
    var searchText = ""
    var category: Category?
    var outcome: Outcome?
    var profileID: UUID?
    var timeRange: TimeRange = .all
  }

  struct DaySection: Identifiable, Equatable, Sendable {
    let day: Date
    var entries: [Entry]

    var id: Date { day }
  }

  static func filtered(
    _ entries: [Entry],
    filters: Filters,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> [Entry] {
    let normalizedSearch = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = dateInterval(for: filters.timeRange, now: now, calendar: calendar)

    return entries.enumerated()
      .filter { _, entry in
        guard filters.category == nil || entry.category == filters.category else { return false }
        guard filters.outcome == nil || entry.outcome == filters.outcome else { return false }
        guard filters.profileID == nil || entry.profileID == filters.profileID else { return false }
        guard range?.contains(entry.occurredAt) ?? true else { return false }
        return normalizedSearch.isEmpty
          || entry.searchableText.contains {
            $0.range(
              of: normalizedSearch,
              options: [.caseInsensitive, .diacriticInsensitive],
              range: nil,
              locale: .autoupdatingCurrent
            ) != nil
          }
      }
      .sorted { lhs, rhs in
        if lhs.element.occurredAt != rhs.element.occurredAt {
          return lhs.element.occurredAt > rhs.element.occurredAt
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  static func sections(
    for entries: [Entry],
    calendar: Calendar = .autoupdatingCurrent
  ) -> [DaySection] {
    let orderedEntries = ordered(entries)
    return sections(forOrderedEntries: orderedEntries, calendar: calendar)
  }

  /// The window uses this path so filtering and day grouping share one sort.
  static func filteredSections(
    _ entries: [Entry],
    filters: Filters,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> (entries: [Entry], sections: [DaySection]) {
    let filteredEntries = filtered(entries, filters: filters, now: now, calendar: calendar)
    return (filteredEntries, sections(forOrderedEntries: filteredEntries, calendar: calendar))
  }

  private static func sections(
    forOrderedEntries orderedEntries: [Entry],
    calendar: Calendar
  ) -> [DaySection] {
    var sections: [DaySection] = []
    var indices: [Date: Int] = [:]
    for entry in orderedEntries {
      let day = calendar.startOfDay(for: entry.occurredAt)
      if let index = indices[day] {
        sections[index].entries.append(entry)
      } else {
        indices[day] = sections.count
        sections.append(DaySection(day: day, entries: [entry]))
      }
    }
    return sections
  }

  private static func ordered(_ entries: [Entry]) -> [Entry] {
    entries.enumerated().sorted { lhs, rhs in
      if lhs.element.occurredAt != rhs.element.occurredAt {
        return lhs.element.occurredAt > rhs.element.occurredAt
      }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  static func reconciledSelection(_ selection: String?, in entries: [Entry]) -> String? {
    guard let selection, entries.contains(where: { $0.id == selection }) else {
      return entries.first?.id
    }
    return selection
  }

  static func canPresentClearConfirmation(
    isQuickHideActive: Bool,
    visibleEntries: [Entry]
  ) -> Bool {
    !isQuickHideActive && !visibleEntries.isEmpty
  }

  private static func dateInterval(
    for timeRange: TimeRange,
    now: Date,
    calendar: Calendar
  ) -> DateInterval? {
    guard timeRange != .all else { return nil }
    let today = calendar.startOfDay(for: now)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
    let days: Int
    switch timeRange {
    case .all: return nil
    case .today: days = 1
    case .last7Days: days = 7
    case .last30Days: days = 30
    }
    let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    return DateInterval(start: start, end: tomorrow)
  }
}
