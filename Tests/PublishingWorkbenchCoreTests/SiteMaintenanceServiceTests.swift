import XCTest
@testable import PublishingWorkbenchCore

final class SiteMaintenanceServiceTests: XCTestCase {
  func testReportBuildsCalendarTaxonomyStaleArticlesAndLinkAudit() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let now = date(year: 2026, month: 7, day: 6)
    let oldDraftID = UUID(uuidString: "9B12FDF0-BAC6-42B9-87F0-08D00B0838A6")!
    let newDraftID = UUID(uuidString: "9C3A4144-064E-4EA8-8E09-68B8FE292C3F")!
    let privateDraftID = UUID(uuidString: "E3406F03-2E14-4DDC-83DC-AF9295A0B9CC")!

    let old = ArticleDraft(
      id: oldDraftID,
      siteProfileID: profile.id,
      title: "旧文",
      date: date(year: 2025, month: 1, day: 1),
      slug: "old-note",
      tags: ["Swift"],
      categories: [],
      draft: false,
      summary: "旧文摘要",
      bodyMarkdown: "[新文](/new-note/) [缺失](/missing-note/) [go](https://example.com)",
      status: .published,
      updatedAt: date(year: 2025, month: 12, day: 1)
    )
    let newer = ArticleDraft(
      id: newDraftID,
      siteProfileID: profile.id,
      title: "新文",
      date: date(year: 2026, month: 6, day: 15),
      slug: "new-note",
      tags: ["Swift", "Mac"],
      categories: ["Tech"],
      draft: false,
      summary: "新文摘要",
      bodyMarkdown: "正文",
      status: .ready,
      updatedAt: date(year: 2026, month: 6, day: 20)
    )
    let privateDraft = ArticleDraft(
      id: privateDraftID,
      siteProfileID: profile.id,
      title: "私密",
      date: date(year: 2026, month: 6, day: 20),
      slug: "private",
      tags: [],
      categories: [],
      visibility: .private,
      bodyMarkdown: "私密正文"
    )

    let report = SiteMaintenanceService(calendar: utcCalendar).report(
      drafts: [old, newer, privateDraft],
      profile: profile,
      releaseRecords: [],
      now: now
    )

    XCTAssertEqual(report.draftCount, 3)
    XCTAssertEqual(report.publicDraftCount, 2)
    XCTAssertEqual(report.privateDraftCount, 1)
    XCTAssertEqual(report.readyCount, 1)
    XCTAssertEqual(report.calendarBuckets.map(\.monthKey), ["2026-06", "2025-01"])
    XCTAssertEqual(report.calendarBuckets.first?.articleCount, 2)
    XCTAssertTrue(report.calendarInsights.contains { $0.id == "current-month-no-published" })
    XCTAssertEqual(report.calendarScheduleItems.map(\.draftID), [newDraftID])
    XCTAssertEqual(report.calendarScheduleItems.first?.scheduledDate, now)
    XCTAssertTrue(report.calendarScheduleItems.first?.reason.contains("重新排期") == true)
    XCTAssertEqual(report.tagSummary.missingCount, 1)
    XCTAssertEqual(report.categorySummary.missingCount, 2)
    XCTAssertEqual(report.tagSummary.entries.first?.name, "Swift")
    XCTAssertEqual(report.tagSummary.entries.first?.count, 2)
    XCTAssertEqual(report.staleArticles.map(\.draftID), [oldDraftID])
    XCTAssertEqual(report.relationSuggestions.count, 1)
    XCTAssertEqual(report.relationSuggestions.first?.sourceDraftID, newDraftID)
    XCTAssertEqual(report.relationSuggestions.first?.targetDraftID, oldDraftID)
    XCTAssertEqual(report.relationSuggestions.first?.sharedLabels, ["Swift"])
    XCTAssertEqual(report.linkAuditItems.count, 2)
    XCTAssertTrue(report.linkAuditItems.contains { $0.target == "/missing-note/" && $0.severity == .warning })
    XCTAssertTrue(report.linkAuditItems.contains { $0.target == "https://example.com" && $0.severity == .info })
    XCTAssertEqual(report.actionItems.first?.kind, .staleArticle)
    XCTAssertEqual(report.actionItems.first?.priority, .high)
    XCTAssertEqual(report.actionItems.first?.draftID, oldDraftID)
    XCTAssertTrue(report.actionItems.contains { $0.kind == .linkAudit && $0.draftID == oldDraftID })
    XCTAssertTrue(report.actionItems.contains { $0.kind == .taxonomy && $0.title == "补齐缺失标签" })
    XCTAssertTrue(report.actionItems.contains { $0.kind == .relationSuggestion && $0.priority == .low })
    XCTAssertEqual(report.healthSummary.level, .urgent)
    XCTAssertLessThan(report.healthSummary.score, 45)
    XCTAssertTrue(report.healthSummary.drivers.contains { $0.contains("高优先级维护项") })
    XCTAssertTrue(report.healthSummary.drivers.contains { $0.contains("链接风险") })
    XCTAssertTrue(report.healthSummary.nextAction.contains("复查旧文：旧文"))
  }

  func testReportBuildsStableMaintenanceHealthSummaryForCleanRecentSite() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let now = date(year: 2026, month: 7, day: 6)
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "近期维护",
      date: date(year: 2026, month: 7, day: 2),
      slug: "recent-maintenance",
      tags: ["维护"],
      categories: ["工具"],
      draft: false,
      summary: "近期维护摘要",
      bodyMarkdown: "正文里链接到 [维护复盘](/maintenance-review/)。",
      status: .published,
      updatedAt: date(year: 2026, month: 7, day: 3)
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "维护复盘",
      date: date(year: 2026, month: 7, day: 4),
      slug: "maintenance-review",
      tags: ["维护"],
      categories: ["工具"],
      draft: false,
      summary: "维护复盘摘要",
      bodyMarkdown: "正文里链接到 [近期维护](/recent-maintenance/)。",
      status: .published,
      updatedAt: date(year: 2026, month: 7, day: 4)
    )

    let report = SiteMaintenanceService(calendar: utcCalendar).report(
      drafts: [first, second],
      profile: profile,
      releaseRecords: [
        ReleaseRecord(
          kind: .remoteDirectCommit,
          title: "线上提交：近期维护",
          summary: "GitHub · main",
          siteProfileID: profile.id,
          createdAt: date(year: 2026, month: 7, day: 3)
        )
      ],
      now: now
    )

    XCTAssertEqual(report.healthSummary.level, .stable)
    XCTAssertEqual(report.healthSummary.score, 100)
    XCTAssertTrue(report.healthSummary.drivers.contains("内容日历、分类和链接审计未发现阻断项"))
    XCTAssertEqual(report.healthSummary.nextAction, "保持当前维护节奏，发布后继续记录操作日志。")
  }

  func testMaintenanceActionItemClipboardMarkdownIncludesTaskChecklist() {
    let item = MaintenanceActionItem(
      id: "link-test",
      kind: .linkAudit,
      priority: .high,
      title: "修复空链接：旧文",
      summary: "链接目标为空。",
      detail: "/missing-page/",
      draftID: UUID(),
      targetPath: "/missing-page/",
      systemImage: "xmark.octagon"
    )

    let markdown = item.clipboardMarkdown

    XCTAssertTrue(markdown.contains("# 维护任务：修复空链接：旧文"))
    XCTAssertTrue(markdown.contains("- 类型：链接审计"))
    XCTAssertTrue(markdown.contains("- 优先级：高"))
    XCTAssertTrue(markdown.contains("- 目标路径：/missing-page/"))
    XCTAssertTrue(markdown.contains("## 处理清单"))
    XCTAssertTrue(markdown.contains("确认链接目标是否仍然有效"))
  }

  func testReportBuildsCalendarCadenceInsightsForBacklogAndPublishGaps() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let published = ArticleDraft(
      siteProfileID: profile.id,
      title: "年初发布",
      date: date(year: 2026, month: 1, day: 5),
      slug: "january-note",
      tags: ["维护"],
      categories: ["工具"],
      draft: false,
      bodyMarkdown: "正文",
      status: .published,
      updatedAt: date(year: 2026, month: 1, day: 5)
    )
    let readyA = ArticleDraft(
      siteProfileID: profile.id,
      title: "待发布 A",
      date: date(year: 2026, month: 7, day: 1),
      slug: "ready-a",
      tags: ["维护"],
      categories: ["工具"],
      bodyMarkdown: "正文",
      status: .ready,
      updatedAt: date(year: 2026, month: 7, day: 1)
    )
    let readyB = ArticleDraft(
      siteProfileID: profile.id,
      title: "待发布 B",
      date: date(year: 2026, month: 6, day: 20),
      slug: "ready-b",
      tags: ["维护"],
      categories: ["工具"],
      bodyMarkdown: "正文",
      status: .ready,
      updatedAt: date(year: 2026, month: 6, day: 20)
    )

    let report = SiteMaintenanceService(calendar: utcCalendar).report(
      drafts: [published, readyA, readyB],
      profile: profile,
      releaseRecords: [],
      now: date(year: 2026, month: 7, day: 6)
    )

    XCTAssertTrue(report.calendarInsights.contains {
      $0.id == "ready-backlog"
        && $0.summary.contains("2 篇公开文章已经标记待发布")
        && $0.priority == .medium
    })
    XCTAssertTrue(report.calendarInsights.contains {
      $0.id == "current-month-no-published"
        && $0.title == "本月还没有公开发布"
    })
    XCTAssertTrue(report.calendarInsights.contains {
      $0.id == "publish-gap"
        && $0.summary.contains("约 6 个月")
        && $0.priority == .high
    })
    XCTAssertEqual(report.calendarScheduleItems.map(\.title), ["待发布 B", "待发布 A"])
    XCTAssertEqual(report.calendarScheduleItems.map(\.scheduledDate), [
      date(year: 2026, month: 7, day: 6),
      date(year: 2026, month: 7, day: 9),
    ])
    XCTAssertTrue(report.calendarScheduleItems.allSatisfy { $0.reason.contains("重新排期") })
  }

  func testReportKeepsFutureReadyDraftDatesInCalendarSchedule() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let futureID = UUID(uuidString: "889613FD-3C69-489B-8129-A83F63D6FE23")!
    let futureReady = ArticleDraft(
      id: futureID,
      siteProfileID: profile.id,
      title: "未来发布",
      date: date(year: 2026, month: 7, day: 12),
      slug: "future-ready",
      tags: ["维护"],
      categories: ["工具"],
      bodyMarkdown: "正文",
      status: .ready,
      updatedAt: date(year: 2026, month: 7, day: 5)
    )

    let report = SiteMaintenanceService(calendar: utcCalendar).report(
      drafts: [futureReady],
      profile: profile,
      releaseRecords: [],
      now: date(year: 2026, month: 7, day: 6)
    )

    XCTAssertEqual(report.calendarScheduleItems.count, 1)
    XCTAssertEqual(report.calendarScheduleItems.first?.draftID, futureID)
    XCTAssertEqual(report.calendarScheduleItems.first?.scheduledDate, date(year: 2026, month: 7, day: 12))
    XCTAssertTrue(report.calendarScheduleItems.first?.reason.contains("沿用文章日期") == true)
    XCTAssertEqual(report.calendarScheduleItems.first?.markdownPath, "content/posts/future-ready.md")
  }

  func testReportSuggestsInternalLinksFromSharedTaxonomy() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let sourceID = UUID(uuidString: "76A794A0-852C-4D7A-B472-AFDABCA1B0B3")!
    let targetID = UUID(uuidString: "8E6B7E40-00A7-4B99-8385-EA02614BA520")!
    let alreadyLinkedID = UUID(uuidString: "60776684-9831-4586-AEF9-C3BF8943F4E0")!
    let unpublishedTargetID = UUID(uuidString: "88E96C5A-F9D4-46CB-9647-E6428F05290C")!

    let source = ArticleDraft(
      id: sourceID,
      siteProfileID: profile.id,
      title: "Mac 发布流程",
      date: date(year: 2026, month: 7, day: 1),
      slug: "mac-publish-flow",
      tags: ["Swift", "发布"],
      categories: ["工具"],
      draft: false,
      bodyMarkdown: "正文里已经链接了 [清单](/release-checklist/)。",
      status: .ready
    )
    let target = ArticleDraft(
      id: targetID,
      siteProfileID: profile.id,
      title: "SwiftUI 工作台",
      date: date(year: 2026, month: 6, day: 20),
      slug: "swiftui-workbench",
      tags: ["Swift"],
      categories: ["工具"],
      draft: false,
      bodyMarkdown: "正文",
      status: .published
    )
    let alreadyLinked = ArticleDraft(
      id: alreadyLinkedID,
      siteProfileID: profile.id,
      title: "发布清单",
      date: date(year: 2026, month: 6, day: 18),
      slug: "release-checklist",
      tags: ["发布"],
      categories: ["工具"],
      draft: false,
      bodyMarkdown: "正文",
      status: .published
    )
    let unpublishedTarget = ArticleDraft(
      id: unpublishedTargetID,
      siteProfileID: profile.id,
      title: "未上线 Swift 文章",
      date: date(year: 2026, month: 6, day: 22),
      slug: "unpublished-swift",
      tags: ["Swift"],
      categories: ["工具"],
      draft: false,
      bodyMarkdown: "正文",
      status: .ready
    )

    let report = SiteMaintenanceService().report(
      drafts: [source, target, alreadyLinked, unpublishedTarget],
      profile: profile,
      releaseRecords: [],
      now: date(year: 2026, month: 7, day: 6)
    )

    XCTAssertTrue(report.relationSuggestions.contains {
      $0.sourceDraftID == sourceID
        && $0.targetDraftID == targetID
        && $0.targetPath == "/swiftui-workbench/"
        && $0.sharedLabels == ["Swift", "工具"]
    })
    XCTAssertFalse(report.relationSuggestions.contains {
      $0.sourceDraftID == sourceID && $0.targetDraftID == alreadyLinkedID
    })
    XCTAssertFalse(report.relationSuggestions.contains {
      $0.sourceDraftID == sourceID && $0.targetDraftID == unpublishedTargetID
    })
  }

  func testMaintenanceChecklistMarkdownSummarizesActionableWorkbenchSections() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let now = date(year: 2026, month: 7, day: 6)
    let oldID = UUID(uuidString: "C2BC7219-3C9C-4E8D-9B4F-FAD57D1E2BD8")!
    let relatedID = UUID(uuidString: "3A5A6420-4E0D-475A-8017-50A5C8E20E1F")!
    let old = ArticleDraft(
      id: oldID,
      siteProfileID: profile.id,
      title: "旧文维护",
      date: date(year: 2025, month: 1, day: 1),
      slug: "old-maintenance",
      tags: ["Swift"],
      categories: [],
      draft: false,
      bodyMarkdown: "[缺失](/missing-page/) TODO",
      status: .published,
      updatedAt: date(year: 2025, month: 1, day: 2)
    )
    let related = ArticleDraft(
      id: relatedID,
      siteProfileID: profile.id,
      title: "Swift 新文",
      date: date(year: 2026, month: 7, day: 1),
      slug: "swift-new",
      tags: ["Swift"],
      categories: ["工具"],
      draft: false,
      bodyMarkdown: "正文",
      status: .ready,
      updatedAt: date(year: 2026, month: 7, day: 2)
    )
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：维护清单",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profile.id,
      createdAt: date(year: 2026, month: 7, day: 3)
    )

    let report = SiteMaintenanceService().report(
      drafts: [old, related],
      profile: profile,
      releaseRecords: [record],
      now: now
    )
    let markdown = report.maintenanceChecklistMarkdown
    let sprint = report.maintenanceSprintPlanMarkdown

    XCTAssertTrue(markdown.contains("# 站点维护清单"))
    XCTAssertTrue(markdown.contains("- 文章：2"))
    XCTAssertTrue(markdown.contains("- 健康分："))
    XCTAssertTrue(markdown.contains("## 维护健康摘要"))
    XCTAssertTrue(markdown.contains("- 下一步："))
    XCTAssertTrue(markdown.contains("## 维护行动队列"))
    XCTAssertTrue(markdown.contains("复查旧文：旧文维护"))
    XCTAssertTrue(markdown.contains("## 内容日历"))
    XCTAssertTrue(markdown.contains("2026 年 7 月"))
    XCTAssertTrue(markdown.contains("## 内容节奏提示"))
    XCTAssertTrue(markdown.contains("## 待发布排期"))
    XCTAssertTrue(markdown.contains("Swift 新文"))
    XCTAssertTrue(markdown.contains("## 标签治理"))
    XCTAssertTrue(markdown.contains("- Swift：2 篇"))
    XCTAssertTrue(markdown.contains("## 分类治理"))
    XCTAssertTrue(markdown.contains("- 缺失：1"))
    XCTAssertTrue(markdown.contains("## 旧文整理"))
    XCTAssertTrue(markdown.contains("content/posts/old-maintenance.md"))
    XCTAssertTrue(markdown.contains("## 文章关系 / 内链机会"))
    XCTAssertTrue(markdown.contains("Swift 新文 -> 旧文维护"))
    XCTAssertTrue(markdown.contains("## 链接审计"))
    XCTAssertTrue(markdown.contains("[警告] 旧文维护：/missing-page/"))
    XCTAssertTrue(markdown.contains("## 操作日志"))
    XCTAssertTrue(markdown.contains("线上提交：维护清单"))

    XCTAssertTrue(sprint.contains("# 站点维护冲刺计划"))
    XCTAssertTrue(sprint.contains("## 今日优先"))
    XCTAssertTrue(sprint.contains("复查旧文：旧文维护"))
    XCTAssertTrue(sprint.contains("可操作：打开草稿，必要时交给 AI 生成修复草案。"))
    XCTAssertTrue(sprint.contains("## 本轮排期"))
    XCTAssertTrue(sprint.contains("Swift 新文"))
    XCTAssertTrue(sprint.contains("## 旧文和链接"))
    XCTAssertTrue(sprint.contains("[警告] 旧文维护：/missing-page/"))
    XCTAssertTrue(sprint.contains("## 内链机会"))
    XCTAssertTrue(sprint.contains("Swift 新文 -> 旧文维护"))
    XCTAssertTrue(sprint.contains("## 完成标准"))
    XCTAssertTrue(sprint.contains("重新生成 SEO / Social 快照"))
  }

  func testReportIncludesRecentReleaseRecordsAsOperationLog() {
    let profile = SiteProfile.defaultProfile
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：维护测试",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profile.id,
      createdAt: date(year: 2026, month: 7, day: 1)
    )

    let report = SiteMaintenanceService().report(
      drafts: [],
      profile: profile,
      releaseRecords: [record],
      now: date(year: 2026, month: 7, day: 6)
    )

    XCTAssertEqual(report.operationLogEntries.count, 1)
    XCTAssertEqual(report.operationLogEntries.first?.id, record.id)
    XCTAssertEqual(report.operationLogEntries.first?.systemImage, ReleaseRecordKind.remoteDirectCommit.systemImage)
  }

  func testReportIncludesRecordedMaintenanceOperationsInOperationLog() {
    let profile = SiteProfile.defaultProfile
    let maintenanceRecord = MaintenanceOperationRecord(
      profileID: profile.id,
      actionKind: .linkAudit,
      actionTitle: "修复链接：旧文",
      summary: "已确认缺失内链并补充目标页面。",
      targetPath: "content/posts/old.md",
      createdAt: date(year: 2026, month: 7, day: 5)
    )
    let releaseRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：维护测试",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profile.id,
      createdAt: date(year: 2026, month: 7, day: 1)
    )

    let report = SiteMaintenanceService().report(
      drafts: [],
      profile: profile,
      releaseRecords: [releaseRecord],
      maintenanceOperationRecords: [maintenanceRecord],
      now: date(year: 2026, month: 7, day: 6)
    )

    XCTAssertEqual(report.operationLogEntries.map(\.id), [maintenanceRecord.id, releaseRecord.id])
    XCTAssertEqual(report.operationLogEntries.first?.title, "维护处理：修复链接：旧文")
    XCTAssertEqual(report.operationLogEntries.first?.systemImage, MaintenanceActionKind.linkAudit.systemImage)
    XCTAssertTrue(report.maintenanceChecklistMarkdown.contains("维护处理：修复链接：旧文"))
    XCTAssertTrue(report.maintenanceChecklistMarkdown.contains("已确认缺失内链并补充目标页面。"))
    XCTAssertTrue(report.maintenanceChecklistMarkdown.contains("线上提交：维护测试"))
  }

  @MainActor
  func testStoreRecordsMaintenanceOperationAndPersistsItAcrossReloads() async throws {
    let url = try temporaryPersistenceURL()
    let profile = SiteProfile.defaultProfile
    _ = try WorkbenchPersistence(fileURL: url).save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [],
        releaseRecords: []
      )
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    let item = MaintenanceActionItem(
      id: "link-old",
      kind: .linkAudit,
      priority: .high,
      title: "修复链接：旧文",
      summary: "缺失内链需要处理。",
      detail: "/missing-page/",
      draftID: nil,
      targetPath: "content/posts/old.md",
      systemImage: MaintenanceActionKind.linkAudit.systemImage
    )

    let record = store.recordMaintenanceOperation(for: item, summary: "已修复缺失内链。")

    XCTAssertEqual(store.publishActionMessage, "已记录维护操作。")
    XCTAssertEqual(store.maintenanceOperationRecords.first?.id, record.id)
    await store.refreshSiteMaintenanceSnapshot(force: true)
    let report = try XCTUnwrap(store.siteMaintenanceSnapshot?.report)
    XCTAssertTrue(report.operationLogEntries.contains { $0.id == record.id })

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertTrue(reloaded.maintenanceOperationRecords.contains { $0.id == record.id })
    await reloaded.refreshSiteMaintenanceSnapshot(force: true)
    let reloadedReport = try XCTUnwrap(reloaded.siteMaintenanceSnapshot?.report)
    XCTAssertTrue(reloadedReport.maintenanceChecklistMarkdown.contains("维护处理：修复链接：旧文"))
    XCTAssertTrue(reloadedReport.maintenanceChecklistMarkdown.contains("已修复缺失内链。"))
  }

  @MainActor
  func testStoreAppliesSuggestedMaintenanceScheduleAndPersistsDraftDates() async throws {
    let url = try temporaryPersistenceURL()
    let profile = SiteProfile.defaultProfile
    let draftID = UUID(uuidString: "45AFB1C2-F2BB-4C03-8E1D-BC8892865F21")!
    let oldDate = date(year: 2020, month: 1, day: 1)
    let readyDraft = ArticleDraft(
      id: draftID,
      siteProfileID: profile.id,
      title: "待排期文章",
      date: oldDate,
      slug: "ready-schedule",
      tags: ["维护"],
      categories: ["工具"],
      bodyMarkdown: "正文",
      status: .ready,
      updatedAt: oldDate
    )
    _ = try WorkbenchPersistence(fileURL: url).save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [readyDraft],
        releaseRecords: []
      )
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    await store.refreshSiteMaintenanceSnapshot(force: true)
    let report = try XCTUnwrap(store.siteMaintenanceSnapshot?.report)
    let suggestedDate = try XCTUnwrap(report.calendarScheduleItems.first?.scheduledDate)

    await store.applySuggestedMaintenanceSchedule()

    let updatedDraft = try XCTUnwrap(store.drafts.first { $0.id == draftID })
    XCTAssertEqual(updatedDraft.date, suggestedDate)
    XCTAssertEqual(store.publishActionMessage, "已应用 1 篇待发布文章的建议排期。")

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.drafts.first { $0.id == draftID }?.date, suggestedDate)
  }

  func testOperationLogIsScopedToCurrentProfileAndKeepsLegacyRecords() {
    let profile = SiteProfile.defaultProfile
    let otherProfileID = UUID()
    let currentRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "当前站点发布",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profile.id,
      createdAt: date(year: 2026, month: 7, day: 3)
    )
    let legacyRecord = ReleaseRecord(
      kind: .directCommit,
      title: "旧版无站点记录",
      summary: "本地 · main · 1 个文件",
      siteProfileID: nil,
      createdAt: date(year: 2026, month: 7, day: 4)
    )
    let otherRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "其他站点发布",
      summary: "GitLab · main · 1 个文件",
      siteProfileID: otherProfileID,
      createdAt: date(year: 2026, month: 7, day: 1)
    )

    let report = SiteMaintenanceService().report(
      drafts: [],
      profile: profile,
      releaseRecords: [otherRecord, currentRecord, legacyRecord],
      now: date(year: 2026, month: 7, day: 6)
    )

    XCTAssertEqual(report.operationLogEntries.map(\.id), [legacyRecord.id, currentRecord.id])
    XCTAssertTrue(report.maintenanceChecklistMarkdown.contains("当前站点发布"))
    XCTAssertTrue(report.maintenanceChecklistMarkdown.contains("旧版无站点记录"))
    XCTAssertFalse(report.maintenanceChecklistMarkdown.contains("其他站点发布"))
  }

  func testLegacySnapshotDecodesWithEmptyMaintenanceOperationRecords() throws {
    let profile = SiteProfile.defaultProfile
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [],
        releaseRecords: [],
        maintenanceOperationRecords: [
          MaintenanceOperationRecord(
            profileID: profile.id,
            actionKind: .taxonomy,
            actionTitle: "补齐缺失标签",
            summary: "已补齐。"
          )
        ]
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "maintenanceOperationRecords")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertTrue(snapshot.maintenanceOperationRecords.isEmpty)
  }

  private func date(year: Int, month: Int, day: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    return components.date!
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SiteMaintenanceServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}
