import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class GeneralDraftLibraryServiceTests: XCTestCase {
  func testReportGroupsGeneralDraftsReusableCandidatesAndAssets() {
    let generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let publishingProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/cover.jpg",
      repositoryPath: "static/images/cover.jpg",
      altText: "",
      caption: "封面",
      byteSize: 1024
    )
    let libraryDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法",
      slug: "idea",
      bodyMarkdown: "Shared idea",
      attachments: [attachment]
    )
    let reusableDraft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "站点草稿",
      slug: "site-draft",
      draft: true,
      bodyMarkdown: "Draft body",
      repositoryPath: nil
    )
    let publishedDraft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "已发布文章",
      slug: "published",
      draft: false,
      bodyMarkdown: "Published body",
      status: .published,
      repositoryPath: "content/posts/published.md"
    )

    let report = GeneralDraftLibraryService().report(
      drafts: [publishedDraft, reusableDraft, libraryDraft],
      profiles: [generalProfile, publishingProfile]
    )

    XCTAssertEqual(report.totalDraftCount, 3)
    XCTAssertEqual(report.generalDraftCount, 1)
    XCTAssertEqual(report.crossSiteCandidateCount, 1)
    XCTAssertEqual(report.attachmentCount, 1)
    XCTAssertEqual(report.generalProfileCount, 1)
    XCTAssertEqual(report.publishingProfileCount, 1)
    XCTAssertEqual(report.items.map(\.reuseStatus), [.libraryDraft, .reusableCandidate, .siteSpecific])
    XCTAssertEqual(report.assets.first?.originalFilename, "cover.jpg")
    XCTAssertEqual(report.assets.first?.isMissingAltText, true)
    XCTAssertEqual(report.assets.first?.isMissingCaption, false)
  }

  func testStoreCreatesGeneralDraftProfileAndCopiesDraftToActiveProfile() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let publishingProfileID = store.activeProfileID
    let generalProfile = store.ensureGeneralDraftProfile()

    XCTAssertEqual(generalProfile.purpose, .generalDraftBackup)
    XCTAssertEqual(store.activeProfileID, generalProfile.id)
    XCTAssertEqual(store.selectedSection, .generalDrafts)

    let generalDraft = store.createGeneralDraft()
    XCTAssertEqual(generalDraft.siteProfileID, generalProfile.id)
    XCTAssertEqual(store.generalDraftLibraryReport.generalDraftCount, 1)

    store.selectProfile(publishingProfileID)
    let copied = try XCTUnwrap(store.copyDraftToActiveProfile(generalDraft.id))

    XCTAssertEqual(copied.siteProfileID, publishingProfileID)
    XCTAssertEqual(copied.status, .draft)
    XCTAssertNil(copied.repositoryPath)
    XCTAssertNil(copied.repositorySHA)
    XCTAssertEqual(store.selectedDraftID, copied.id)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.drafts.contains { $0.id == generalDraft.id && $0.siteProfileID == generalProfile.id })
    let reusePlan = try XCTUnwrap(store.latestGeneralDraftReusePlan)
    XCTAssertEqual(reusePlan.sourceDraftID, generalDraft.id)
    XCTAssertEqual(reusePlan.targetDraftID, copied.id)
    XCTAssertEqual(reusePlan.sourceProfileName, generalProfile.name)
    XCTAssertEqual(reusePlan.targetProfileName, store.activeProfile.name)
    XCTAssertEqual(reusePlan.targetMarkdownPath, store.activeProfile.markdownPath(for: copied))
    XCTAssertTrue(store.publishActionMessage?.contains(reusePlan.targetMarkdownPath) == true)
  }

  func testReusePlanSummarizesTargetPathAndAttachmentFollowups() throws {
    var sourceProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    sourceProfile.applyPublishingDefaults(for: .zola)
    var targetProfile = SiteProfile(name: "Jekyll 站点", purpose: .publishing)
    targetProfile.applyPublishingDefaults(for: .jekyll)
    let sourceDraft = ArticleDraft(
      siteProfileID: sourceProfile.id,
      title: "跨站复用",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "cross-site-reuse",
      bodyMarkdown: "正文包含 [旧站内链](/old/path/) 和 TODO。",
      attachments: [
        DraftAttachment(
          originalFilename: "cover.jpg",
          relativePublishPath: "/images/cover.jpg",
          repositoryPath: "static/images/2026/cover.jpg",
          altText: "",
          caption: "",
          byteSize: 1024
        )
      ],
      repositoryPath: "content/posts/2026/cross-site-reuse.md"
    )
    var copiedDraft = sourceDraft
    copiedDraft.id = UUID()
    copiedDraft.siteProfileID = targetProfile.id
    copiedDraft.repositoryPath = nil

    let plan = GeneralDraftLibraryService().reusePlan(
      sourceDraft: sourceDraft,
      copiedDraft: copiedDraft,
      sourceProfile: sourceProfile,
      targetProfile: targetProfile
    )

    XCTAssertEqual(plan.targetMarkdownPath, "_posts/2026-08-29-cross-site-reuse.md")
    XCTAssertEqual(plan.sourceRepositoryPath, "content/posts/2026/cross-site-reuse.md")
    XCTAssertEqual(plan.attachmentCount, 1)
    XCTAssertEqual(plan.missingAltTextCount, 1)
    XCTAssertEqual(plan.missingCaptionCount, 1)
    XCTAssertEqual(plan.riskLevel, .high)
    XCTAssertTrue(plan.riskItems.contains { $0.contains("站点类型从 zola 变为 jekyll") })
    XCTAssertTrue(plan.riskItems.contains { $0.contains("已绑定发布路径") })
    XCTAssertTrue(plan.riskItems.contains { $0.contains("站内绝对链接") })
    XCTAssertTrue(plan.riskItems.contains { $0.contains("TODO") })
    XCTAssertTrue(plan.checklistItems.contains { $0.contains("front matter") })
    XCTAssertTrue(plan.checklistMarkdown.contains("跨站点复用计划：跨站复用"))
    XCTAssertTrue(plan.checklistMarkdown.contains("建议发布路径：_posts/2026-08-29-cross-site-reuse.md"))
    XCTAssertTrue(plan.checklistMarkdown.contains("附件待补：alt 1 个，caption 1 个"))
    XCTAssertTrue(plan.checklistMarkdown.contains("风险等级：高风险"))
    XCTAssertTrue(plan.checklistMarkdown.contains("## 复用风险"))
  }

  func testReusePlanMarksCleanSameFrameworkCopyAsReadyWithContextReminder() throws {
    var sourceProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    sourceProfile.applyPublishingDefaults(for: .zola)
    var targetProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    targetProfile.applyPublishingDefaults(for: .zola)
    let sourceDraft = ArticleDraft(
      siteProfileID: sourceProfile.id,
      title: "干净复用",
      slug: "clean-reuse",
      tags: ["写作"],
      summary: "这是一段可直接作为社交摘要的通用素材说明。",
      bodyMarkdown: "正文用于跨站点复用，内容边界清晰。"
    )
    var copiedDraft = sourceDraft
    copiedDraft.id = UUID()
    copiedDraft.siteProfileID = targetProfile.id

    let plan = GeneralDraftLibraryService().reusePlan(
      sourceDraft: sourceDraft,
      copiedDraft: copiedDraft,
      sourceProfile: sourceProfile,
      targetProfile: targetProfile
    )

    XCTAssertEqual(plan.riskLevel, .ready)
    XCTAssertEqual(plan.riskItems, ["没有发现明显跨站复用风险；仍需按发布前检查确认目标站点语境。"])
    XCTAssertTrue(plan.checklistMarkdown.contains("风险等级：可复用"))
  }

  func testSourceFieldDiffsDetectChangedTitleSlugSummaryTagsCategoriesAndBodyLength() throws {
    let sourceProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let targetProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let sourceDraft = ArticleDraft(
      siteProfileID: sourceProfile.id,
      title: "Original title",
      slug: "source-slug",
      tags: ["a", "b"],
      categories: ["x", "y"],
      summary: "这是复用前的摘要。",
      bodyMarkdown: String(repeating: "原始正文 ", count: 3)
    )
    var copiedDraft = sourceDraft
    copiedDraft.id = UUID()
    copiedDraft.siteProfileID = targetProfile.id
    copiedDraft.title = "Rewritten title"
    copiedDraft.slug = "rewritten-slug"
    copiedDraft.summary = "这是重写后的摘要。"
    copiedDraft.tags = ["b", "c"]
    copiedDraft.categories = ["x", "z"]
    copiedDraft.draft = false
    copiedDraft.bodyMarkdown = String(repeating: "更新正文 ", count: 8)

    let plan = GeneralDraftLibraryService().reusePlan(
      sourceDraft: sourceDraft,
      copiedDraft: copiedDraft,
      sourceProfile: sourceProfile,
      targetProfile: targetProfile
    )

    XCTAssertEqual(plan.sourceFieldDiffs.count, 7)
    XCTAssertTrue(plan.sourceFieldDiffs.contains("标题：\"Original title\" -> \"Rewritten title\""))
    XCTAssertTrue(plan.sourceFieldDiffs.contains("Slug：\"source-slug\" -> \"rewritten-slug\""))
    XCTAssertTrue(plan.sourceFieldDiffs.contains("摘要：\"这是复用前的摘要。\" -> \"这是重写后的摘要。\""))
    XCTAssertTrue(plan.sourceFieldDiffs.contains("标签：a、b -> b、c"))
    XCTAssertTrue(plan.sourceFieldDiffs.contains("分类：x、y -> x、z"))
    XCTAssertTrue(plan.sourceFieldDiffs.contains("发布状态：草稿 -> 已发布"))
    XCTAssertTrue(plan.sourceFieldDiffs.contains("正文长度：\(sourceDraft.bodyMarkdown.count) -> \(copiedDraft.bodyMarkdown.count)"))
  }

  func testSourceFieldDiffsFromSnapshotDetectsChangedTitleSlugSummaryTagsCategoriesAndBodyLength() throws {
    let sourceDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Original title",
      slug: "source-slug",
      tags: ["a", "b"],
      categories: ["x", "y"],
      summary: "这是复用前的摘要。",
      bodyMarkdown: String(repeating: "原始正文 ", count: 3)
    )
    let snapshot = GeneralDraftReuseSourceSnapshot.make(
      from: sourceDraft,
      sourceProfileName: "来源站点"
    )

    var copiedDraft = sourceDraft
    copiedDraft.id = UUID()
    copiedDraft.siteProfileID = UUID()
    copiedDraft.title = "Rewritten title"
    copiedDraft.slug = "rewritten-slug"
    copiedDraft.summary = "这是重写后的摘要。"
    copiedDraft.tags = ["b", "c"]
    copiedDraft.categories = ["x", "z"]
    copiedDraft.draft = false
    copiedDraft.bodyMarkdown = String(repeating: "更新正文 ", count: 8)

    let diffs = GeneralDraftLibraryService().sourceFieldDiffs(
      from: snapshot,
      to: copiedDraft
    )

    XCTAssertEqual(diffs.count, 7)
    XCTAssertTrue(diffs.contains("标题：\"Original title\" -> \"Rewritten title\""))
    XCTAssertTrue(diffs.contains("Slug：\"source-slug\" -> \"rewritten-slug\""))
    XCTAssertTrue(diffs.contains("摘要：\"这是复用前的摘要。\" -> \"这是重写后的摘要。\""))
    XCTAssertTrue(diffs.contains("标签：a、b -> b、c"))
    XCTAssertTrue(diffs.contains("分类：x、y -> x、z"))
    XCTAssertTrue(diffs.contains("发布状态：草稿 -> 已发布"))
    XCTAssertTrue(diffs.contains("正文长度：\(sourceDraft.bodyMarkdown.count) -> \(copiedDraft.bodyMarkdown.count)"))
  }

  func testLibraryItemReuseChecklistMarkdownIncludesCrossSiteChecks() throws {
    let generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let draft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "跨站点素材",
      slug: "shared-material",
      tags: ["素材"],
      categories: ["Ideas"],
      summary: "可复用摘要",
      bodyMarkdown: "这是一篇可以复用的通用草稿。",
      attachments: [
        DraftAttachment(
          originalFilename: "cover.jpg",
          relativePublishPath: "/images/cover.jpg",
          repositoryPath: "static/images/cover.jpg",
          byteSize: 1024
        )
      ]
    )

    let report = GeneralDraftLibraryService().report(
      drafts: [draft],
      profiles: [generalProfile]
    )
    let item = try XCTUnwrap(report.items.first)
    let markdown = item.reuseChecklistMarkdown

    XCTAssertTrue(markdown.contains("# 素材复用清单：跨站点素材"))
    XCTAssertTrue(markdown.contains("- 来源 Profile：通用库"))
    XCTAssertTrue(markdown.contains("- 状态：通用素材"))
    XCTAssertTrue(markdown.contains("- Slug：shared-material"))
    XCTAssertTrue(markdown.contains("- 标签：素材"))
    XCTAssertTrue(markdown.contains("- 分类：Ideas"))
    XCTAssertTrue(markdown.contains("## 复用前检查"))
    XCTAssertTrue(markdown.contains("复制到目标站点后"))
    XCTAssertTrue(markdown.contains("## 附件处理"))
    XCTAssertTrue(markdown.contains("重新检查 alt、caption"))
  }

  func testReportSummarizesTagAndCategoryDistribution() throws {
    let generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let publishingProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let drafts: [ArticleDraft] = [
      ArticleDraft(
        siteProfileID: generalProfile.id,
        title: "通用 A",
        slug: "general-a",
        tags: ["Swift", "AI"],
        categories: ["技术", "实践"],
        bodyMarkdown: "通用库 A"
      ),
      ArticleDraft(
        siteProfileID: generalProfile.id,
        title: "通用 B",
        slug: "general-b",
        tags: ["Swift"],
        categories: ["案例"],
        bodyMarkdown: "通用库 B"
      ),
      ArticleDraft(
        siteProfileID: publishingProfile.id,
        title: "站点草稿",
        slug: "site-draft",
        tags: ["写作"],
        categories: ["实践"],
        draft: true,
        bodyMarkdown: "站点草稿"
      )
    ]

    let report = GeneralDraftLibraryService().report(
      drafts: drafts,
      profiles: [generalProfile, publishingProfile]
    )

    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: report.tagSummaries.map { ($0.label, $0.draftCount) })["Swift"],
      2
    )
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: report.tagSummaries.map { ($0.label, $0.draftCount) })["AI"],
      1
    )
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: report.categorySummaries.map { ($0.label, $0.draftCount) })["技术"],
      1
    )
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: report.categorySummaries.map { ($0.label, $0.draftCount) })["实践"],
      2
    )
  }

  func testGeneralDraftLibraryPackagePlanExportRoundTrip() throws {
    let profile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "导出复用稿",
      slug: "exported-draft",
      tags: ["Swift", "Draft"],
      categories: ["实践", "案例"],
      summary: "可复用摘要。",
      bodyMarkdown: "这是导出并回填后的正文。"
    )
    let service = GeneralDraftLibraryService()
    let packagePlan = service.packagePlan(
      drafts: [draft],
      profile: profile,
      now: Date(timeIntervalSince1970: 1_780_000_000)
    )

    XCTAssertEqual(packagePlan.files.count, 1)
    XCTAssertTrue(packagePlan.packageText.contains("<!-- path: \(packagePlan.files[0].relativePath) -->"))
    let entries = service.parsePackageEntries(from: packagePlan.packageText)
    XCTAssertEqual(entries.count, 1)

    let importedDraft = service.draft(from: entries[0], profile: profile)
    XCTAssertEqual(importedDraft.siteProfileID, profile.id)
    XCTAssertEqual(importedDraft.repositoryPath, entries[0].relativePath)
    XCTAssertEqual(importedDraft.title, draft.title)
    XCTAssertEqual(importedDraft.slug, draft.slug)
    XCTAssertEqual(importedDraft.tags.sorted(), draft.tags.sorted())
    XCTAssertEqual(importedDraft.categories.sorted(), draft.categories.sorted())
    XCTAssertEqual(importedDraft.summary, draft.summary)
    XCTAssertEqual(importedDraft.bodyMarkdown, draft.bodyMarkdown)
  }

  func testReportBuildsCrossSiteMaterialPackageMarkdown() throws {
    let generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let publishingProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/cover.jpg",
      repositoryPath: "static/images/cover.jpg",
      altText: "",
      caption: "",
      byteSize: 2048
    )
    let libraryDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "跨站点素材",
      slug: "shared-material",
      tags: ["素材"],
      categories: ["Ideas"],
      summary: "可复用摘要",
      bodyMarkdown: "这是一篇可以复用的通用草稿。",
      attachments: [attachment],
      updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let reusableDraft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "站点草稿",
      slug: "",
      draft: true,
      bodyMarkdown: "仍在构思。",
      updatedAt: Date(timeIntervalSince1970: 1_899_000_000),
      repositoryPath: nil
    )

    let report = GeneralDraftLibraryService().report(
      drafts: [reusableDraft, libraryDraft],
      profiles: [generalProfile, publishingProfile],
      now: Date(timeIntervalSince1970: 1_901_000_000)
    )
    let markdown = report.crossSiteMaterialPackageMarkdown

    XCTAssertTrue(markdown.contains("# 跨站点素材包"))
    XCTAssertTrue(markdown.contains("- 通用素材：1"))
    XCTAssertTrue(markdown.contains("- 复用候选：1"))
    XCTAssertTrue(markdown.contains("## 复用队列"))
    XCTAssertTrue(markdown.contains("[通用素材] 跨站点素材"))
    XCTAssertTrue(markdown.contains("Profile：通用库"))
    XCTAssertTrue(markdown.contains("Slug：shared-material"))
    XCTAssertTrue(markdown.contains("标签：素材"))
    XCTAssertTrue(markdown.contains("[可复用候选] 站点草稿"))
    XCTAssertTrue(markdown.contains("Slug：未设置"))
    XCTAssertTrue(markdown.contains("## 附件素材"))
    XCTAssertTrue(markdown.contains("cover.jpg"))
    XCTAssertTrue(markdown.contains("路径：static/images/cover.jpg"))
    XCTAssertTrue(markdown.contains("待补：alt、caption"))
    XCTAssertTrue(markdown.contains("## 工作流"))
    XCTAssertTrue(markdown.contains("备份素材库"))
  }

  func testReportBuildsDistributionChecklistMarkdown() throws {
    let generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let publishingProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/cover.jpg",
      repositoryPath: "static/images/cover.jpg",
      altText: "",
      caption: "",
      byteSize: 2048
    )
    let libraryDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用素材",
      slug: "shared-material",
      tags: ["素材"],
      categories: ["Ideas"],
      summary: "可复用摘要",
      bodyMarkdown: "这是一篇可以复用的通用草稿。",
      attachments: [attachment],
      updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let reusableDraft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "站点候选",
      slug: "",
      draft: true,
      bodyMarkdown: "仍在构思。",
      updatedAt: Date(timeIntervalSince1970: 1_899_000_000),
      repositoryPath: nil
    )
    let siteSpecificDraft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "已发布专用文章",
      slug: "published",
      draft: false,
      bodyMarkdown: "已发布内容。",
      status: .published,
      repositoryPath: "content/posts/published.md"
    )

    let report = GeneralDraftLibraryService().report(
      drafts: [siteSpecificDraft, reusableDraft, libraryDraft],
      profiles: [generalProfile, publishingProfile],
      now: Date(timeIntervalSince1970: 1_901_000_000)
    )
    let markdown = report.distributionChecklistMarkdown

    XCTAssertTrue(markdown.contains("# 素材分发清单"))
    XCTAssertTrue(markdown.contains("- 待收进素材库候选：1"))
    XCTAssertTrue(markdown.contains("## 优先分发候选"))
    XCTAssertTrue(markdown.contains("[可复用候选] 站点候选"))
    XCTAssertTrue(markdown.contains("动作：先收进素材库，再复制到目标站点"))
    XCTAssertTrue(markdown.contains("Slug：未设置"))
    XCTAssertTrue(markdown.contains("## 素材库"))
    XCTAssertTrue(markdown.contains("[通用素材] 通用素材"))
    XCTAssertTrue(markdown.contains("动作：复制到目标站点后重查站点语境"))
    XCTAssertTrue(markdown.contains("附件：1 个，分发前重查路径、alt 和 caption"))
    XCTAssertTrue(markdown.contains("## 暂缓复用"))
    XCTAssertTrue(markdown.contains("[站点专用] 已发布专用文章"))
    XCTAssertTrue(markdown.contains("## 附件分发"))
    XCTAssertTrue(markdown.contains("cover.jpg"))
    XCTAssertTrue(markdown.contains("处理：补 alt、补 caption"))
    XCTAssertTrue(markdown.contains("## 发布前执行"))
    XCTAssertTrue(markdown.contains("把复用计划发送到 AI 对话页"))
    XCTAssertTrue(markdown.contains("备份素材库"))
  }

  func testReusableCandidateChecklistKeepsSourceDraftSafe() throws {
    let publishingProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let draft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "站点草稿",
      slug: "",
      draft: true,
      bodyMarkdown: "仍在构思。",
      repositoryPath: nil
    )

    let report = GeneralDraftLibraryService().report(
      drafts: [draft],
      profiles: [publishingProfile]
    )
    let item = try XCTUnwrap(report.items.first)
    let markdown = item.reuseChecklistMarkdown

    XCTAssertEqual(item.reuseStatus, .reusableCandidate)
    XCTAssertTrue(markdown.contains("- Slug：未设置"))
    XCTAssertTrue(markdown.contains("先收进素材库，保留原站点草稿不动"))
    XCTAssertTrue(markdown.contains("清理只属于原站点的路径"))
  }

  func testStoreCopiesReusableCandidateIntoGeneralLibrary() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let publishingProfileID = store.activeProfileID
    let source = ArticleDraft(
      siteProfileID: publishingProfileID,
      title: "跨站点选题",
      slug: "shared-topic",
      tags: ["工程"],
      categories: ["Ideas"],
      draft: true,
      summary: "可复用摘要",
      bodyMarkdown: "这是一篇可以沉淀为通用素材的草稿。",
      status: .ready,
      repositoryPath: "content/posts/shared-topic.md",
      repositorySHA: "source-sha"
    )
    store.setDrafts([source])
    store.setSelectedDraftID(source.id)

    let copied = try XCTUnwrap(store.copyDraftToGeneralLibrary(source.id))
    let generalProfile = try XCTUnwrap(store.profiles.first { $0.purpose == .generalDraftBackup })

    XCTAssertEqual(copied.siteProfileID, generalProfile.id)
    XCTAssertEqual(copied.title, "跨站点选题")
    XCTAssertEqual(copied.slug, "shared-topic")
    XCTAssertEqual(copied.tags, ["工程"])
    XCTAssertEqual(copied.categories, ["Ideas"])
    XCTAssertEqual(copied.status, .draft)
    XCTAssertTrue(copied.draft)
    XCTAssertNil(copied.repositoryPath)
    XCTAssertNil(copied.repositorySHA)
    XCTAssertEqual(store.selectedDraftID, copied.id)
    XCTAssertEqual(store.selectedSection, .generalDrafts)
    XCTAssertTrue(store.drafts.contains { $0.id == source.id && $0.siteProfileID == publishingProfileID })
    XCTAssertTrue(store.generalDraftLibraryReport.items.contains { $0.draftID == copied.id && $0.reuseStatus == .libraryDraft })
    XCTAssertEqual(store.publishActionMessage, "已收进通用草稿库：跨站点选题")
  }

  func testStoreImportGeneralDraftLibraryPackageUpdatesExistingAndInsertsNew() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let generalProfile = store.ensureGeneralDraftProfile()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let existingDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "已存在草稿",
      date: now,
      slug: "existing-draft",
      tags: ["原始标签"],
      summary: "旧摘要",
      bodyMarkdown: "旧正文。",
      repositoryPath: "general-drafts/existing-draft.md"
    )

    var updatedIncoming = existingDraft
    updatedIncoming.id = UUID()
    updatedIncoming.title = "更新后的草稿"
    updatedIncoming.tags = ["更新标签"]
    updatedIncoming.bodyMarkdown = "更新后的正文。"
    updatedIncoming.summary = "更新后的摘要。"
    updatedIncoming.repositorySHA = nil

    let insertedIncoming = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "新增草稿",
      date: now,
      slug: "new-draft",
      tags: ["新标签"],
      summary: "新增摘要",
      bodyMarkdown: "新增正文。",
      repositoryPath: "general-drafts/new-draft.md"
    )

    let service = GeneralDraftLibraryService()
    let packageText = service.packagePlan(
      drafts: [updatedIncoming, insertedIncoming],
      profile: generalProfile,
      now: now
    ).packageText

    store.setDrafts([existingDraft])
    let summary = store.importGeneralDraftLibraryPackage(from: packageText)

    XCTAssertEqual(summary.insertedCount, 1)
    XCTAssertEqual(summary.updatedCount, 1)
    XCTAssertEqual(summary.skippedCount, 0)
    XCTAssertTrue(store.publishActionMessage?.contains("已从素材包导入 1 篇、更新 1 篇") == true)

    let updated = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "general-drafts/existing-draft.md" })
    XCTAssertEqual(updated.id, existingDraft.id)
    XCTAssertEqual(updated.title, "更新后的草稿")
    XCTAssertEqual(updated.tags, ["更新标签"])
    XCTAssertEqual(updated.summary, "更新后的摘要。")
    XCTAssertEqual(updated.siteProfileID, generalProfile.id)

    let inserted = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "general-drafts/new-draft.md" })
    XCTAssertEqual(inserted.title, "新增草稿")
    XCTAssertEqual(inserted.siteProfileID, generalProfile.id)
  }

  func testCopyingExistingGeneralDraftToGeneralLibraryFocusesOriginal() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let generalProfile = store.ensureGeneralDraftProfile()
    let source = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "已有通用草稿",
      slug: "existing-general",
      bodyMarkdown: "已有内容。"
    )
    store.setDrafts([source])

    let copied = try XCTUnwrap(store.copyDraftToGeneralLibrary(source.id))

    XCTAssertEqual(copied.id, source.id)
    XCTAssertEqual(store.drafts.count, 1)
    XCTAssertEqual(store.selectedDraftID, source.id)
    XCTAssertEqual(store.selectedSection, .generalDrafts)
    XCTAssertEqual(store.publishActionMessage, "这篇已经在通用草稿库中。")
  }

  func testBackupPlanExportsOnlyGeneralDraftsWithManifestAndCommands() throws {
    var generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    generalProfile.localRepositoryRootPath = "/tmp/general draft backup"
    generalProfile.branch = "draft-backup"
    let publishingProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let date = Date(timeIntervalSince1970: 1_720_000_000)
    let firstDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法 A",
      date: date,
      slug: "shared-idea",
      tags: ["素材"],
      summary: "可复用摘要",
      bodyMarkdown: "第一篇通用草稿。",
      updatedAt: date.addingTimeInterval(20)
    )
    let duplicateSlugDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法 B",
      date: date,
      slug: "shared-idea",
      bodyMarkdown: "第二篇通用草稿。",
      updatedAt: date.addingTimeInterval(10)
    )
    let siteDraft = ArticleDraft(
      siteProfileID: publishingProfile.id,
      title: "站点草稿",
      slug: "site-draft",
      bodyMarkdown: "不应该进入通用草稿备份。"
    )

    let plan = GeneralDraftLibraryService().backupPlan(
      drafts: [siteDraft, duplicateSlugDraft, firstDraft],
      profile: generalProfile,
      now: date
    )

    XCTAssertTrue(plan.isReady)
    XCTAssertEqual(plan.files.map(\.title), ["通用想法 A", "通用想法 B"])
    XCTAssertEqual(plan.files.map(\.relativePath), [
      "general-drafts/shared-idea.md",
      "general-drafts/shared-idea-2.md"
    ])
    XCTAssertTrue(plan.files[0].markdown.contains("通用想法 A"))
    XCTAssertTrue(plan.files[0].markdown.contains("素材"))
    XCTAssertFalse(plan.files.map(\.markdown).joined().contains("不应该进入通用草稿备份"))
    XCTAssertTrue(plan.manifestMarkdown.contains("# 素材备份"))
    XCTAssertTrue(plan.manifestMarkdown.contains("general-drafts/shared-idea.md"))
    XCTAssertTrue(plan.packageText.contains("# 素材备份"))
    XCTAssertTrue(plan.packageText.contains("<!-- path: general-drafts/shared-idea.md -->"))
    XCTAssertTrue(plan.packageText.contains("<!-- path: general-drafts/shared-idea-2.md -->"))
    XCTAssertTrue(plan.packageText.contains("第一篇通用草稿。"))
    XCTAssertTrue(plan.packageText.contains("第二篇通用草稿。"))
    XCTAssertEqual(plan.commandLines.first, "cd '/tmp/general draft backup'")
    XCTAssertTrue(plan.commandText.contains("git add general-drafts"))
    XCTAssertTrue(plan.commandText.contains("git push origin 'draft-backup'"))
  }

  func testBackupPlanWaitsForRepositoryWhenRootIsMissing() {
    let generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let draft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法",
      slug: "idea",
      bodyMarkdown: "通用草稿正文。"
    )

    let plan = GeneralDraftLibraryService().backupPlan(
      drafts: [draft],
      profile: generalProfile
    )

    XCTAssertFalse(plan.isReady)
    XCTAssertEqual(plan.files.count, 1)
    XCTAssertTrue(plan.commandLines.isEmpty)
    XCTAssertTrue(plan.statusMessage.contains("选择备份仓库"))
  }

  func testWriteBackupPersistsManifestAndGeneralDraftFiles() throws {
    var generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    generalProfile.localRepositoryRootPath = try temporaryDirectoryURL().path
    generalProfile.branch = "draft-backup"
    let date = Date(timeIntervalSince1970: 1_720_000_000)
    let firstDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法 A",
      date: date,
      slug: "shared-idea",
      bodyMarkdown: "第一篇通用草稿。",
      updatedAt: date.addingTimeInterval(20)
    )
    let duplicateSlugDraft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法 B",
      date: date,
      slug: "shared-idea",
      bodyMarkdown: "第二篇通用草稿。",
      updatedAt: date.addingTimeInterval(10)
    )
    let service = GeneralDraftLibraryService()
    let plan = service.backupPlan(
      drafts: [duplicateSlugDraft, firstDraft],
      profile: generalProfile,
      now: date
    )

    let result = try service.writeBackup(plan)

    XCTAssertEqual(result.manifestPath, "general-drafts/MANIFEST.md")
    XCTAssertEqual(result.writtenPaths, [
      "general-drafts/shared-idea.md",
      "general-drafts/shared-idea-2.md"
    ])
    let rootURL = URL(fileURLWithPath: result.rootPath, isDirectory: true)
    let manifest = try String(
      contentsOf: rootURL.appendingPathComponent("general-drafts/MANIFEST.md"),
      encoding: .utf8
    )
    let firstMarkdown = try String(
      contentsOf: rootURL.appendingPathComponent("general-drafts/shared-idea.md"),
      encoding: .utf8
    )
    let secondMarkdown = try String(
      contentsOf: rootURL.appendingPathComponent("general-drafts/shared-idea-2.md"),
      encoding: .utf8
    )

    XCTAssertTrue(manifest.contains("# 素材备份"))
    XCTAssertTrue(manifest.contains("general-drafts/shared-idea.md"))
    XCTAssertTrue(firstMarkdown.contains("第一篇通用草稿。"))
    XCTAssertTrue(secondMarkdown.contains("第二篇通用草稿。"))
  }

  func testWriteBackupPrunesOnlyStaleTopLevelGeneralDraftMarkdownFiles() throws {
    var generalProfile = SiteProfile(name: "通用库", purpose: .generalDraftBackup)
    let rootURL = try temporaryDirectoryURL()
    let draftsURL = rootURL.appendingPathComponent("general-drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: draftsURL, withIntermediateDirectories: true)
    try "stale".write(to: draftsURL.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
    try "manual".write(to: draftsURL.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
    try "manifest".write(to: draftsURL.appendingPathComponent("MANIFEST.md"), atomically: true, encoding: .utf8)
    let nestedURL = draftsURL.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    try "nested".write(to: nestedURL.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)

    generalProfile.localRepositoryRootPath = rootURL.path
    let draft = ArticleDraft(
      siteProfileID: generalProfile.id,
      title: "通用想法",
      slug: "shared-idea",
      bodyMarkdown: "当前通用草稿。"
    )
    let service = GeneralDraftLibraryService()
    let plan = service.backupPlan(drafts: [draft], profile: generalProfile)

    let result = try service.writeBackup(plan)

    XCTAssertEqual(result.deletedStalePaths, ["general-drafts/old.md"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: draftsURL.appendingPathComponent("old.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: draftsURL.appendingPathComponent("shared-idea.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: draftsURL.appendingPathComponent("manual.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: draftsURL.appendingPathComponent("MANIFEST.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.appendingPathComponent("old.md").path))
    XCTAssertTrue(result.statusMessage.contains("清理 1 个过期备份"))
  }

  func testWriteBackupRejectsUnsafeRelativePaths() throws {
    let rootURL = try temporaryDirectoryURL()
    let unsafeFile = GeneralDraftBackupFile(
      id: UUID(),
      draftID: UUID(),
      title: "越界草稿",
      relativePath: "general-drafts/../leak.md",
      markdown: "不应写出",
      byteCount: 12
    )
    let plan = GeneralDraftBackupPlan(
      generatedAt: Date(),
      profileID: UUID(),
      profileName: "通用库",
      repositoryRootPath: rootURL.path,
      branch: "main",
      files: [unsafeFile],
      manifestMarkdown: "# 通用草稿备份\n",
      commandLines: [],
      statusMessage: "测试"
    )

    XCTAssertThrowsError(try GeneralDraftLibraryService().writeBackup(plan)) { error in
      guard case GeneralDraftBackupWriteError.invalidRelativePath("general-drafts/../leak.md") = error else {
        return XCTFail("Expected invalidRelativePath, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("leak.md").path))
  }

  func testStoreWritesGeneralDraftBackupToRepositoryAndUpdatesMessage() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let rootURL = try temporaryDirectoryURL()
    _ = store.ensureGeneralDraftProfile()
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.branch = "draft-backup"
    }
    let draft = store.createGeneralDraft()

    let result = try XCTUnwrap(store.writeGeneralDraftBackupToRepository())

    XCTAssertEqual(result.rootPath, rootURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(result.manifestPath).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(result.writtenPaths[0]).path))
    XCTAssertTrue(result.writtenPaths[0].contains(draft.slug))
    XCTAssertEqual(store.latestGeneralDraftBackupWriteResult, result)
    XCTAssertTrue(store.publishActionMessage?.contains("已写入") == true)
  }

  func testStoreBackupWriteReportsPrunedStaleGeneralDrafts() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let rootURL = try temporaryDirectoryURL()
    let draftsURL = rootURL.appendingPathComponent("general-drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: draftsURL, withIntermediateDirectories: true)
    try "stale".write(to: draftsURL.appendingPathComponent("removed.md"), atomically: true, encoding: .utf8)

    _ = store.ensureGeneralDraftProfile()
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.branch = "draft-backup"
    }
    _ = store.createGeneralDraft()

    let result = try XCTUnwrap(store.writeGeneralDraftBackupToRepository())

    XCTAssertEqual(result.deletedStalePaths, ["general-drafts/removed.md"])
    XCTAssertEqual(store.latestGeneralDraftBackupWriteResult?.deletedStalePaths, ["general-drafts/removed.md"])
    XCTAssertTrue(store.publishActionMessage?.contains("已清理：general-drafts/removed.md") == true)
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = try temporaryDirectoryURL()
    return directory.appendingPathComponent("workbench.json")
  }

  private func temporaryDirectoryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("GeneralDraftLibraryServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
