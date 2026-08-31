import XCTest

@testable import PersonalSitePublisherMac

final class OperationLogPresentationTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)
  private let now = Date(timeIntervalSince1970: 1_780_401_600)  // 2026-06-01 12:00:00 UTC

  func testCombinedFiltersSearchOnlyProjectedSafeFields() {
    let primaryProfileID = UUID()
    let publishing = entry(
      "publish",
      category: .publishing,
      outcome: .succeeded,
      actor: .user,
      title: "发布夏季文章",
      profileID: primaryProfileID,
      dayOffset: 0
    )
    let failedPublishing = entry(
      "failed",
      category: .publishing,
      outcome: .failed,
      actor: .user,
      title: "发布失败",
      profileID: primaryProfileID,
      dayOffset: 0
    )
    let maintenance = entry(
      "maintenance",
      category: .maintenance,
      outcome: .succeeded,
      actor: .user,
      title: "检查链接",
      profileID: UUID(),
      dayOffset: 0
    )

    let result = OperationLogPresentation.filtered(
      [failedPublishing, maintenance, publishing],
      filters: .init(
        searchText: "夏季",
        category: .publishing,
        outcome: .succeeded,
        profileID: primaryProfileID,
        timeRange: .today
      ),
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(result.map(\.id), ["publish"])
  }

  func testSearchMatchesOnlyDisplayProjectionFields() {
    let item = entry(
      "search",
      category: .automation,
      outcome: .recorded,
      actor: .user,
      title: "刷新 RSS",
      summary: "已更新订阅源",
      sourceLabel: "RSS 刷新",
      target: "阅读清单",
      dayOffset: 0
    )

    for query in ["RSS 刷新", "自动化", "已记录", "用户", "阅读清单"] {
      XCTAssertEqual(
        OperationLogPresentation.filtered([item], filters: .init(searchText: query)).map(\.id),
        [item.id]
      )
    }
  }

  func testTimeRangesUseCalendarDaysAndExcludeFutureEntries() {
    let today = entry("today", dayOffset: 0)
    let sevenDaysAgo = entry("seven", dayOffset: -6)
    let eightDaysAgo = entry("eight", dayOffset: -7)
    let thirtyDaysAgo = entry("thirty", dayOffset: -29)
    let thirtyOneDaysAgo = entry("thirty-one", dayOffset: -30)
    let future = entry("future", dayOffset: 1)
    let entries = [today, sevenDaysAgo, eightDaysAgo, thirtyDaysAgo, thirtyOneDaysAgo, future]

    XCTAssertEqual(
      OperationLogPresentation.filtered(
        entries, filters: .init(timeRange: .today), now: now, calendar: calendar
      ).map(\.id),
      ["today"]
    )
    XCTAssertEqual(
      OperationLogPresentation.filtered(
        entries, filters: .init(timeRange: .last7Days), now: now, calendar: calendar
      ).map(\.id),
      ["today", "seven"]
    )
    XCTAssertEqual(
      OperationLogPresentation.filtered(
        entries, filters: .init(timeRange: .last30Days), now: now, calendar: calendar
      ).map(\.id),
      ["today", "seven", "eight", "thirty"]
    )
  }

  func testSectionsAreChronologicalAndPreserveInputOrderForEqualDates() {
    let newest = entry("newest", dayOffset: 0)
    let equalFirst = entry("equal-first", dayOffset: -1)
    let equalSecond = entry("equal-second", dayOffset: -1)
    let older = entry("older", dayOffset: -2)

    let sections = OperationLogPresentation.sections(
      for: [equalFirst, older, newest, equalSecond],
      calendar: calendar
    )

    XCTAssertEqual(
      sections.map { $0.entries.map(\.id) },
      [
        ["newest"],
        ["equal-first", "equal-second"],
        ["older"],
      ])
  }

  func testFilteredSectionsSharesTheFilteredOrderingWithDayGrouping() {
    let newest = entry("newest", dayOffset: 0)
    let equalFirst = entry("equal-first", dayOffset: -1)
    let equalSecond = entry("equal-second", dayOffset: -1)
    let older = entry("older", dayOffset: -2)

    let projection = OperationLogPresentation.filteredSections(
      [equalFirst, older, newest, equalSecond],
      filters: .init(),
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(
      projection.entries.map(\.id), ["newest", "equal-first", "equal-second", "older"])
    XCTAssertEqual(
      projection.sections.flatMap(\.entries).map(\.id),
      projection.entries.map(\.id)
    )
  }

  func testSelectionReconcilesAfterFilteringAndForEmptyResults() {
    let first = entry("first", dayOffset: 0)
    let second = entry("second", dayOffset: -1)

    XCTAssertEqual(
      OperationLogPresentation.reconciledSelection("second", in: [first]),
      "first"
    )
    XCTAssertEqual(
      OperationLogPresentation.reconciledSelection("first", in: [first, second]),
      "first"
    )
    XCTAssertNil(OperationLogPresentation.reconciledSelection("first", in: []))
  }

  func testEmptySearchResultHasNoSections() {
    let result = OperationLogPresentation.filtered(
      [entry("only", title: "发布文章", dayOffset: 0)],
      filters: .init(searchText: "不存在的内容"),
      now: now,
      calendar: calendar
    )

    XCTAssertTrue(result.isEmpty)
    XCTAssertTrue(OperationLogPresentation.sections(for: result, calendar: calendar).isEmpty)
  }

  func testPhaseTwoCategoriesAndRetentionPoliciesExposeStablePresentationValues() {
    XCTAssertEqual(
      Set(OperationLogPresentation.Category.allCases),
      [.publishing, .maintenance, .automation, .ai, .deployment, .importing, .images, .backup]
    )
    XCTAssertEqual(
      OperationLogPresentation.RetentionPolicy.allCases.map(\.rawValue),
      ["thirtyDays", "ninetyDays", "oneYear", "forever"]
    )
  }

  func testExportContainsOnlySafePresentationFields() throws {
    let internalID = "operationEvent:cbfbcd53-b2d5-4cbb-b9f9-3fb84d7799be"
    let data = OperationLogExportDocument.exportData(
      for: [
        entry(
          internalID,
          category: .importing,
          title: "导入完成",
          summary: "已安全生成导入摘要",
          sourceLabel: "活动事件",
          target: "网站",
          dayOffset: 0
        )
      ]
    )
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertFalse(json.contains(internalID))
    XCTAssertFalse(json.contains("sourceReference"))
    XCTAssertFalse(json.contains("/Users/"))
    XCTAssertFalse(json.contains("https://"))
    XCTAssertFalse(json.contains("rawError"))

    let objects = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    )
    let firstObject = try XCTUnwrap(objects.first)
    XCTAssertEqual(
      Set(firstObject.keys),
      Set(["occurredAt", "source", "category", "outcome", "actor", "title", "summary", "target"])
    )
  }

  func testClearConfirmationIsHiddenForQuickHideAndEmptyProjection() {
    let visibleEntry = entry("visible", dayOffset: 0)

    XCTAssertTrue(
      OperationLogPresentation.canPresentClearConfirmation(
        isQuickHideActive: false,
        visibleEntries: [visibleEntry]
      )
    )
    XCTAssertFalse(
      OperationLogPresentation.canPresentClearConfirmation(
        isQuickHideActive: true,
        visibleEntries: [visibleEntry]
      )
    )
    XCTAssertFalse(
      OperationLogPresentation.canPresentClearConfirmation(
        isQuickHideActive: false,
        visibleEntries: []
      )
    )
  }

  private func entry(
    _ id: String,
    category: OperationLogPresentation.Category = .publishing,
    outcome: OperationLogPresentation.Outcome = .succeeded,
    actor: OperationLogPresentation.Actor = .user,
    title: String = "活动",
    summary: String = "活动摘要",
    sourceLabel: String = "测试记录",
    profileID: UUID? = nil,
    target: String? = "测试站点",
    dayOffset: Int
  ) -> OperationLogPresentation.Entry {
    let date = calendar.date(byAdding: .day, value: dayOffset, to: now)!
    return .init(
      id: id,
      sourceLabel: sourceLabel,
      category: category,
      outcome: outcome,
      actor: actor,
      title: title,
      summary: summary,
      profileID: profileID,
      targetLabel: target,
      occurredAt: date,
      systemImage: "clock"
    )
  }
}
