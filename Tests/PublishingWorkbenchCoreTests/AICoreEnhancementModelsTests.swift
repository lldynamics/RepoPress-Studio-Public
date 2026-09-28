import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

final class AICoreEnhancementModelsTests: XCTestCase {
  func testContextSummaryNamesEverySupportedReferenceWithoutEmbeddingContent() {
    let draftID = UUID()
    let duplicateID = UUID()
    let references = [
      AIContextReference(
        id: duplicateID,
        kind: .currentSelection,
        resourceID: draftID.uuidString,
        sourceRange: AIStructuredEditSourceRange(location: 3, length: 8),
        characterCount: 8
      ),
      AIContextReference(
        id: duplicateID,
        kind: .currentSelection,
        resourceID: draftID.uuidString,
        sourceRange: AIStructuredEditSourceRange(location: 3, length: 8),
        characterCount: 8
      ),
      .currentArticle(draftID: draftID, title: "文章甲", characterCount: 100),
      .specifiedArticle(draftID: UUID(), title: "文章乙", characterCount: 200),
      .knowledgeEntry(documentID: UUID(), title: "写作规范", characterCount: 30),
      .publishCheck(draftID: draftID, issueCount: 2, characterCount: 20),
    ]

    let summary = AIContextTransmissionSummaryService.make(references: references)

    XCTAssertEqual(summary.items.count, 5)
    XCTAssertEqual(summary.totalCharacterCount, 358)
    XCTAssertTrue(summary.displayText.contains("当前选区"))
    XCTAssertTrue(summary.displayText.contains("当前文章：文章甲"))
    XCTAssertTrue(summary.displayText.contains("指定文章：文章乙"))
    XCTAssertTrue(summary.displayText.contains("资料条目：写作规范"))
    XCTAssertTrue(summary.displayText.contains("发布检查：2 项"))
    XCTAssertFalse(summary.displayText.contains("这是一段不应出现的正文"))
  }

  func testTranslationPlanCreatesLinkedUnpublishedDraftWithoutMutatingSource() throws {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "images/cover.png",
      repositoryPath: "static/images/cover.png"
    )
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原文",
      slug: "source",
      tags: ["工具"],
      categories: ["写作"],
      authors: ["作者"],
      draft: false,
      visibility: .public,
      summary: "原摘要",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "# 原文\n\n![封面](images/cover.png)",
      attachments: [attachment],
      status: .published,
      repositoryPath: "content/source.md",
      repositorySHA: "remote-sha",
      repositoryImportFingerprint: "import-fingerprint"
    )
    let originalSource = source
    let destinationID = UUID()
    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      profile: profile,
      targetLanguageCode: "EN_us",
      translatedTitle: "Source",
      translatedSummary: "Summary",
      translatedBodyMarkdown: "# Source\n\n![Cover](images/cover.png)",
      destinationDraftID: destinationID,
      plannedAt: Date(timeIntervalSince1970: 2_000)
    )

    XCTAssertEqual(source, originalSource)
    XCTAssertEqual(plan.sourceDraftID, source.id)
    XCTAssertEqual(plan.targetLanguageCode, "en-us")
    XCTAssertEqual(plan.translatedDraft.id, destinationID)
    XCTAssertNotEqual(plan.translatedDraft.id, source.id)
    XCTAssertEqual(plan.translatedDraft.slug, "source")
    XCTAssertTrue(plan.translatedDraft.draft)
    XCTAssertEqual(plan.translatedDraft.status, .draft)
    XCTAssertNil(plan.translatedDraft.repositoryPath)
    XCTAssertNil(plan.translatedDraft.repositorySHA)
    XCTAssertNil(plan.translatedDraft.repositoryImportFingerprint)
    XCTAssertEqual(plan.translatedDraft.attachments, source.attachments)
    XCTAssertEqual(plan.translatedDraft.coverAttachmentID, attachment.id)
    XCTAssertEqual(plan.link.sourceDraftID, source.id)
    XCTAssertEqual(plan.link.translatedDraftID, destinationID)
    XCTAssertEqual(plan.translatedDraft.translationLink, plan.link)
    XCTAssertEqual(plan.link.sourceMarkdownPath, profile.markdownPath(for: source))
    XCTAssertEqual(
      profile.markdownPath(for: plan.translatedDraft),
      "\(profile.markdownPath(for: source).dropLast(3)).en-us.md"
    )

    let materialized = try AITranslationDraftPlanningService.materialize(
      plan,
      currentSource: source
    )
    XCTAssertEqual(materialized, plan.translatedDraft)
    XCTAssertEqual(materialized.translationFreshness(source: source, profile: profile), .current)
  }

  func testTranslationPlanRejectsStaleSourceAndSourceIdentityReuse() throws {
    let profile = SiteProfile.defaultProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原文",
      slug: "source",
      bodyMarkdown: "需要翻译的正文"
    )
    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.plan(
        source: source,
        targetLanguageCode: "en",
        translatedTitle: "Source",
        translatedSummary: "",
        translatedBodyMarkdown: "Translated body",
        destinationDraftID: source.id
      )
    ) { error in
      XCTAssertEqual(
        error as? AITranslationDraftPlanningError,
        .destinationReusesSourceIdentity
      )
    }

    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      targetLanguageCode: "en",
      translatedTitle: "Source",
      translatedSummary: "",
      translatedBodyMarkdown: "Translated body"
    )
    var changedSource = source
    changedSource.bodyMarkdown = "用户已经修改正文"

    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.materialize(
        plan,
        currentSource: changedSource
      )
    ) { error in
      XCTAssertEqual(
        error as? AITranslationDraftPlanningError,
        .sourceDraftChanged
      )
    }
  }
}

final class ArticleTranslationIntegrationTests: XCTestCase {
  @MainActor
  func testConfirmedAITranslationPersistsArticleRelationship() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "translation-store-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchPersistence(
      fileURL: directory.appendingPathComponent("workbench.json")
    )
    let store = WorkbenchStore(persistence: persistence)
    let profile = store.activeProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原稿",
      slug: "source",
      bodyMarkdown: "需要翻译的正文。"
    )
    store.updateDraft(source)
    store.save()
    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      profile: profile,
      targetLanguageCode: "en",
      translatedTitle: "Source",
      translatedSummary: "",
      translatedBodyMarkdown: "Translated body."
    )

    let created = try XCTUnwrap(store.ai.createLinkedTranslationDraft(from: plan))
    XCTAssertEqual(created.translationLink, plan.link)
    XCTAssertTrue(store.flushPendingChanges())

    let reopened = WorkbenchStore(persistence: persistence)
    let saved = try XCTUnwrap(reopened.drafts.first(where: { $0.id == created.id }))
    let savedLink = try XCTUnwrap(saved.translationLink)
    XCTAssertEqual(savedLink.sourceDraftID, plan.link.sourceDraftID)
    XCTAssertEqual(savedLink.translatedDraftID, plan.link.translatedDraftID)
    XCTAssertEqual(savedLink.targetLanguageCode, plan.link.targetLanguageCode)
    XCTAssertEqual(savedLink.sourceContentFingerprint, plan.link.sourceContentFingerprint)
    XCTAssertEqual(savedLink.sourceMarkdownPath, plan.link.sourceMarkdownPath)
    XCTAssertLessThan(abs(savedLink.createdAt.timeIntervalSince(plan.link.createdAt)), 1)
    XCTAssertEqual(saved.translationFreshness(source: source, profile: profile), .current)
  }

  func testNativePathLinkSurvivesSnapshotAndMarksSourceChangesStale() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Same title",
      slug: "post",
      bodyMarkdown: String(repeating: "Source body. ", count: 12)
    )
    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      profile: profile,
      targetLanguageCode: "EN",
      translatedTitle: "Same title",
      translatedSummary: "Summary",
      translatedBodyMarkdown: String(repeating: "Translated body. ", count: 12)
    )
    let translated = try AITranslationDraftPlanningService.materialize(
      plan,
      currentSource: source,
      profile: profile
    )

    XCTAssertEqual(profile.markdownPath(for: translated), "content/posts/post.en.md")
    XCTAssertEqual(translated.translationLink?.sourceDraftID, source.id)
    XCTAssertEqual(translated.translationFreshness(source: source, profile: profile), .current)

    let restored = try JSONDecoder().decode(
      ArticleDraft.self,
      from: JSONEncoder().encode(translated)
    )
    XCTAssertEqual(restored.translationLink, translated.translationLink)
    XCTAssertEqual(restored.translationFreshness(source: source, profile: profile), .current)

    var changedSource = source
    changedSource.bodyMarkdown += "Updated."
    XCTAssertEqual(restored.translationFreshness(source: changedSource, profile: profile), .stale)
    XCTAssertEqual(restored.translationFreshness(source: nil), .sourceMissing)

    var movedProfile = profile
    movedProfile.markdownPathPattern = "content/new/{slug}.md"
    XCTAssertEqual(restored.translationFreshness(source: source, profile: movedProfile), .stale)

    let issues = PreflightCheckService().run(
      draft: restored,
      allDrafts: [source, restored],
      profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertFalse(issues.contains { $0.title == "标题重复" })
    let staleIssues = PreflightCheckService().run(
      draft: restored,
      allDrafts: [changedSource, restored],
      profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertTrue(staleIssues.contains { $0.title == "译文已过期" })
  }

  func testPublishingMetadataDoesNotExpireTranslationButWordsDo() throws {
    let profile = SiteProfile.defaultProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原稿",
      slug: "source",
      summary: "原摘要",
      bodyMarkdown: String(repeating: "原稿正文。", count: 20)
    )
    var translated = try AITranslationDraftPlanningService.plan(
      source: source,
      profile: profile,
      targetLanguageCode: "en",
      translatedTitle: "Translation",
      translatedSummary: "Summary",
      translatedBodyMarkdown: String(repeating: "Translated body. ", count: 12)
    ).translatedDraft
    XCTAssertNotNil(translated.translationLink?.sourceTranslationFingerprint)

    var published = source
    published.status = .published
    published.draft = false
    published.date = published.date.addingTimeInterval(86_400)
    published.tags = ["new-tag"]
    XCTAssertNotEqual(source.repositoryContentFingerprint, published.repositoryContentFingerprint)
    XCTAssertEqual(source.translationContentFingerprint, published.translationContentFingerprint)
    XCTAssertEqual(translated.translationFreshness(source: published, profile: profile), .current)
    let publishedIssues = PreflightCheckService().run(
      draft: translated,
      allDrafts: [published, translated],
      profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertFalse(publishedIssues.contains { $0.title == "译文已过期" })

    published.summary = "修改后的摘要"
    XCTAssertEqual(translated.translationFreshness(source: published, profile: profile), .stale)
    XCTAssertTrue(translated.markTranslationReviewed(source: published, profile: profile))
    XCTAssertEqual(translated.translationFreshness(source: published, profile: profile), .current)
    let restored = try JSONDecoder().decode(
      ArticleDraft.self, from: JSONEncoder().encode(translated)
    )
    XCTAssertEqual(restored.translationFreshness(source: published, profile: profile), .current)
    published.bodyMarkdown += "新增段落"
    XCTAssertEqual(restored.translationFreshness(source: published, profile: profile), .stale)
    XCTAssertFalse(translated.markTranslationReviewed(source: nil, profile: profile))
  }

  func testLegacyTranslationRemainsCurrentWhenOnlyPublicationStateChanges() throws {
    let profile = SiteProfile.defaultProfile
    var source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原稿",
      slug: "source",
      bodyMarkdown: "原稿正文"
    )
    source.status = .ready
    source.draft = false
    let translatedID = UUID()
    let translated = ArticleDraft(
      id: translatedID,
      siteProfileID: profile.id,
      title: "Translation",
      bodyMarkdown: "Translated body",
      translationLink: AITranslationDraftLink(
        sourceDraftID: source.id,
        translatedDraftID: translatedID,
        targetLanguageCode: "en",
        sourceContentFingerprint: source.repositoryContentFingerprint,
        createdAt: Date(),
        sourceMarkdownPath: profile.markdownPath(for: source)
      )
    )
    let restored = try JSONDecoder().decode(
      ArticleDraft.self, from: JSONEncoder().encode(translated)
    )
    XCTAssertNil(restored.translationLink?.sourceTranslationFingerprint)
    source.status = .published
    XCTAssertEqual(restored.translationFreshness(source: source, profile: profile), .current)
    source.title = "内容变了"
    XCTAssertEqual(restored.translationFreshness(source: source, profile: profile), .stale)
  }

  func testHugoAndLanguageDirectoryPathsFollowSourceFilename() throws {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .hugo)
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原稿",
      slug: "original",
      bodyMarkdown: "原稿正文"
    )
    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      profile: profile,
      targetLanguageCode: "en",
      translatedTitle: "A localized title",
      translatedSummary: "",
      translatedBodyMarkdown: "Translated body",
      translatedSlug: "localized-url"
    )
    XCTAssertEqual(plan.translatedDraft.slug, "localized-url")
    XCTAssertEqual(profile.markdownPath(for: plan.translatedDraft), "content/posts/original.en.md")

    var privateSource = source
    privateSource.visibility = .private
    let privatePlan = try AITranslationDraftPlanningService.plan(
      source: privateSource,
      profile: profile,
      targetLanguageCode: "en",
      translatedTitle: "Private translation",
      translatedSummary: "",
      translatedBodyMarkdown: "Private translated body"
    )
    XCTAssertEqual(
      profile.markdownPath(for: privatePlan.translatedDraft),
      "private/posts/original.en.md"
    )

    profile.translationMarkdownPathPattern = "content/{language}/posts/{sourceSlug}.md"
    XCTAssertEqual(
      profile.markdownPath(for: plan.translatedDraft),
      "content/en/posts/original.md"
    )

    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.plan(
        source: source,
        profile: profile,
        targetLanguageCode: "../../en",
        translatedTitle: "Unsafe",
        translatedSummary: "",
        translatedBodyMarkdown: "Translated body"
      )
    )
  }

  func testNativeAndDirectoryTranslationFilesImportWithoutLosingExistingLink() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let document = """
      +++
      title = "Translated title"
      slug = "localized-url"
      +++

      Translated body.
      """
    let root = FileManager.default.temporaryDirectory
    let importer = LocalContentImportService(isContentIndexEnabled: false)
    let native = try importer.parseProjectDocument(
      document,
      repositoryPath: "content/posts/original.en.md",
      rootURL: root,
      profile: profile
    )
    XCTAssertEqual(profile.markdownPath(for: native), "content/posts/original.en.md")
    XCTAssertEqual(profile.translationLanguageCode(for: native), "en")

    profile.translationMarkdownPathPattern = "content/{language}/posts/{sourceSlug}.md"
    let directory = try importer.parseProjectDocument(
      document,
      repositoryPath: "content/en/posts/original.md",
      rootURL: root,
      profile: profile
    )
    XCTAssertEqual(profile.markdownPath(for: directory), "content/en/posts/original.md")
    XCTAssertEqual(profile.translationLanguageCode(for: directory), "en")

    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Translated title",
      slug: "original",
      bodyMarkdown: "Source body"
    )
    let importedIssues = PreflightCheckService().run(
      draft: directory,
      allDrafts: [source, directory],
      profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertFalse(importedIssues.contains { $0.title == "标题重复" })
    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      profile: profile,
      targetLanguageCode: "en",
      translatedTitle: "Translated title",
      translatedSummary: "",
      translatedBodyMarkdown: "Translated body"
    )
    var linked = plan.translatedDraft
    linked.repositoryPath = "content/en/posts/original.md"
    let merge = LocalContentImportMergeService().makePlan(
      existingDrafts: [linked],
      result: LocalContentImportResult(importedDrafts: [directory], skippedPaths: [])
    )
    XCTAssertEqual(merge.drafts.count, 1)
    XCTAssertEqual(merge.drafts[0].id, linked.id)
    XCTAssertEqual(merge.drafts[0].translationLink, linked.translationLink)
  }
}
