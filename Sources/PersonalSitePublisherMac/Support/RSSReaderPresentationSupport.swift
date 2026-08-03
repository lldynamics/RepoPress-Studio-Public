import Foundation
import PublishingWorkbenchCore

enum RSSArticleSortOrder: String, CaseIterable, Identifiable {
  case newest
  case oldest
  case unreadFirst

  var id: String { rawValue }

  var title: String {
    switch self {
    case .newest: String(localized: "最新优先")
    case .oldest: String(localized: "最早优先")
    case .unreadFirst: String(localized: "未读优先")
    }
  }
}

enum RSSArticleDateRange: String, CaseIterable, Identifiable {
  case all
  case today
  case lastSevenDays
  case lastThirtyDays

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "不限日期")
    case .today: String(localized: "今天")
    case .lastSevenDays: String(localized: "近 7 天")
    case .lastThirtyDays: String(localized: "近 30 天")
    }
  }
}

enum RSSArticleDateSectionKind: Int, CaseIterable, Identifiable {
  case today
  case yesterday
  case lastSevenDays
  case earlier

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .today: String(localized: "今天")
    case .yesterday: String(localized: "昨天")
    case .lastSevenDays: String(localized: "近 7 天")
    case .earlier: String(localized: "更早")
    }
  }
}

struct RSSArticleListSection: Identifiable {
  let kind: RSSArticleDateSectionKind?
  let articles: [RSSArticleHeader]

  var id: String { kind.map { "date-\($0.rawValue)" } ?? "all" }
  var title: String? { kind?.title }
}

enum RSSArticleListPresentationState: Equatable {
  case loading
  case refreshing(cachedCount: Int)
  case staleContent(cachedCount: Int, feedTitle: String, message: String)
  case failed(feedTitle: String, message: String)
  case empty
  case filteredEmpty
  case content
}

enum RSSArticlePresentationSupport {
  static func applyFiltersAndSort(
    to articles: [RSSArticleHeader],
    sourceID: UUID?,
    author: String?,
    tag: String?,
    dateRange: RSSArticleDateRange,
    sortOrder: RSSArticleSortOrder,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [RSSArticleHeader] {
    let filtered = articles
      .filter { article in
        guard let sourceID else { return true }
        return article.feedID == sourceID
      }
      .filter { article in
        guard let author else { return true }
        return article.author?.localizedCaseInsensitiveCompare(author) == .orderedSame
      }
      .filter { article in
        guard let tag else { return true }
        return article.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
      }
      .filter { article in
        includes(
          article.publishedAt ?? article.fetchedAt,
          in: dateRange,
          now: now,
          calendar: calendar
        )
      }
    // RSSReaderStore already supplies newest-first order. Preserve it for the
    // default view instead of sorting the full local archive a second time.
    guard sortOrder != .newest else { return filtered }
    return filtered.sorted { lhs, rhs in
      precedes(lhs, rhs, order: sortOrder)
    }
  }

  static func sections(
    for articles: [RSSArticleHeader],
    groupsByDate: Bool,
    sortOrder: RSSArticleSortOrder,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [RSSArticleListSection] {
    guard groupsByDate else {
      return articles.isEmpty ? [] : [RSSArticleListSection(kind: nil, articles: articles)]
    }

    let buckets = Dictionary(grouping: articles) { article in
      dateSection(
        for: article.publishedAt ?? article.fetchedAt,
        now: now,
        calendar: calendar
      )
    }
    let normalOrder: [RSSArticleDateSectionKind] = [.today, .yesterday, .lastSevenDays, .earlier]
    let order = sortOrder == .oldest ? Array(normalOrder.reversed()) : normalOrder
    return order.compactMap { kind in
      guard let values = buckets[kind], !values.isEmpty else { return nil }
      return RSSArticleListSection(kind: kind, articles: values)
    }
  }

  static func listState(
    isRefreshing: Bool,
    cachedCount: Int,
    visibleCount: Int,
    hasActiveFilters: Bool,
    failedFeedTitle: String?,
    failedFeedMessage: String?
  ) -> RSSArticleListPresentationState {
    if visibleCount > 0 {
      if isRefreshing { return .refreshing(cachedCount: visibleCount) }
      if let failedFeedTitle, let failedFeedMessage {
        return .staleContent(
          cachedCount: visibleCount,
          feedTitle: failedFeedTitle,
          message: failedFeedMessage
        )
      }
      return .content
    }
    if isRefreshing, cachedCount == 0 {
      return .loading
    }
    if let failedFeedTitle, let failedFeedMessage {
      if cachedCount > 0 {
        return .staleContent(
          cachedCount: 0,
          feedTitle: failedFeedTitle,
          message: failedFeedMessage
        )
      }
      return .failed(feedTitle: failedFeedTitle, message: failedFeedMessage)
    }
    if hasActiveFilters {
      return .filteredEmpty
    }
    return .empty
  }

  static func feedNeedsAttention(_ feed: RSSFeed, now: Date = Date()) -> Bool {
    feed.lastIssue != nil || feed.lastError != nil || feed.healthStatus(now: now) == .backingOff
  }

  static func feedAccessibilityValue(
    _ feed: RSSFeed,
    unreadCount: Int,
    now: Date = Date()
  ) -> String {
    var components = [
      unreadCount > 0
        ? String(localized: "\(unreadCount) 篇未读")
        : String(localized: "没有未读文章")
    ]
    switch feed.healthStatus(now: now) {
    case .never:
      components.append(String(localized: "尚未成功刷新"))
    case .healthy:
      components.append(String(localized: "订阅正常"))
    case .failing:
      components.append(String(localized: "订阅刷新失败"))
    case .backingOff:
      components.append(String(localized: "订阅正在等待重试"))
    }
    if let error = (feed.lastIssue?.userMessage ?? feed.lastError)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
      components.append(String(localized: "原因：\(error)"))
    }
    if let retryAt = feed.nextRetryAt ?? feed.lastIssue?.retryAt,
       retryAt > now,
       feed.lastIssue?.shouldRetryAutomatically != false {
      components.append(
        String(localized: "下次重试：\(retryAt.formatted(date: .omitted, time: .shortened))")
      )
    } else if feed.lastIssue?.retryStrategy == .requiresAction {
      components.append(String(localized: "需要修改地址或访问条件"))
    }
    return components.joined(separator: "，")
  }

  private static func includes(
    _ date: Date,
    in range: RSSArticleDateRange,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    switch range {
    case .all:
      return true
    case .today:
      return calendar.isDate(date, inSameDayAs: now)
    case .lastSevenDays:
      let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
      return date >= start && date <= now
    case .lastThirtyDays:
      let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
      return date >= start && date <= now
    }
  }

  private static func precedes(
    _ lhs: RSSArticleHeader,
    _ rhs: RSSArticleHeader,
    order: RSSArticleSortOrder
  ) -> Bool {
    let lhsDate = lhs.publishedAt ?? lhs.fetchedAt
    let rhsDate = rhs.publishedAt ?? rhs.fetchedAt
    switch order {
    case .newest:
      if lhsDate != rhsDate { return lhsDate > rhsDate }
    case .oldest:
      if lhsDate != rhsDate { return lhsDate < rhsDate }
    case .unreadFirst:
      if lhs.isRead != rhs.isRead { return !lhs.isRead }
      if lhsDate != rhsDate { return lhsDate > rhsDate }
    }
    return lhs.id < rhs.id
  }

  private static func dateSection(
    for date: Date,
    now: Date,
    calendar: Calendar
  ) -> RSSArticleDateSectionKind {
    if calendar.isDate(date, inSameDayAs: now) { return .today }
    if calendar.isDateInYesterday(date) { return .yesterday }
    let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
    return date >= start ? .lastSevenDays : .earlier
  }
}

enum RSSArticleLanguageResolver {
  static func languageTag(for article: RSSArticle) -> String {
    languageTag(
      for: [article.title, article.author ?? "", article.readableText]
        .joined(separator: "\n")
    )
  }

  static func languageTag(for text: String) -> String {
    var han = 0
    var japanese = 0
    var hangul = 0
    var cyrillic = 0
    var latin = 0

    for scalar in text.unicodeScalars.prefix(8_000) {
      switch scalar.value {
      case 0x3040...0x30FF:
        japanese += 1
      case 0xAC00...0xD7AF:
        hangul += 1
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
        han += 1
      case 0x0400...0x04FF:
        cyrillic += 1
      case 0x0041...0x005A, 0x0061...0x007A:
        latin += 1
      default:
        break
      }
    }

    if japanese > 0 { return "ja" }
    if hangul > 0 { return "ko" }
    if han > 0 { return "zh-CN" }
    if cyrillic > latin / 3 { return "ru" }
    if latin > 0 { return "en" }
    return "und"
  }
}
