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

final class TranslationDraftCreationTests: XCTestCase {
  func testHugoKeyRoundTripsYAMLAndTOMLThroughImportEditingAndSnapshot() throws {
    for style in FrontMatterStyle.allCases {
      var profile = hugoProfile()
      profile.frontMatterStyle = style
      let original = ArticleDraft(
        siteProfileID: profile.id, title: "Original", slug: "original",
        translationKey: "shared-\"quoted\"-\\key", bodyMarkdown: "Body"
      )
      let document = FrontMatterRenderer().renderDocument(draft: original, profile: profile)
      XCTAssertTrue(document.contains("translationKey"))
      let imported = try LocalContentImportService(isContentIndexEnabled: false)
        .parseProjectDocument(
          document, repositoryPath: "content/posts/original.md",
          rootURL: FileManager.default.temporaryDirectory, profile: profile)
      XCTAssertEqual(imported.translationKey, original.translationKey)
      let editor = MarkdownFrontMatterEditingService()
      let result = editor.applying(
        editor.render(draft: imported, profile: profile),
        to: imported, profile: profile)
      XCTAssertTrue(result.isValid)
      XCTAssertEqual(result.draft.translationKey, original.translationKey)
      let restored = try JSONDecoder().decode(
        ArticleDraft.self, from: JSONEncoder().encode(result.draft))
      XCTAssertEqual(restored.translationKey, original.translationKey)
      var noKey = restored
      noKey.translationKey = nil
      XCTAssertNotEqual(noKey.repositoryContentFingerprint, restored.repositoryContentFingerprint)
      XCTAssertNotEqual(noKey.metadataProjection, restored.metadataProjection)
      let withoutKey = editor.render(draft: noKey, profile: profile)
      XCTAssertNil(editor.applying(withoutKey, to: restored, profile: profile).draft.translationKey)
    }
  }

  func testZolaPreservesUnknownImportedHugoKeyWithoutAdoptingOrCopyingIt() throws {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)
    let document = """
      +++
      title = "Zola"
      date = "2026-10-09"
      translationKey = "hugo-only"
      +++

      Body
      """
    let imported = try LocalContentImportService(isContentIndexEnabled: false)
      .parseProjectDocument(
        document, repositoryPath: "content/posts/2026/zola.md",
        rootURL: FileManager.default.temporaryDirectory, profile: profile)
    XCTAssertNil(imported.translationKey)
    let originalHeader = try XCTUnwrap(imported.importedFrontMatter?.rawBlock)
    XCTAssertTrue(originalHeader.contains("translationKey = \"hugo-only\""))
    var source = imported
    source.translationKey = "stored-from-an-earlier-hugo-profile"
    let plan = try makePlan(source: source, profile: profile)
    XCTAssertNil(plan.sourceTranslationKey)
    XCTAssertNil(plan.translatedDraft.translationKey)
    // The imported key belongs to the original document, not Zola's editable
    // translation metadata. A legacy model value must not replace its bytes.
    XCTAssertEqual(FrontMatterRenderer().render(draft: source, profile: profile), originalHeader)
    XCTAssertEqual(
      MarkdownFrontMatterEditingService().render(draft: source, profile: profile), originalHeader)
    XCTAssertNil(plan.translatedDraft.importedFrontMatter)
    XCTAssertFalse(
      FrontMatterRenderer().render(draft: plan.translatedDraft, profile: profile).contains(
        "translationKey"))
    var freshDraft = source
    freshDraft.importedFrontMatter = nil
    XCTAssertFalse(
      FrontMatterRenderer().render(draft: freshDraft, profile: profile).contains("translationKey"))
    XCTAssertEqual(
      MarkdownFrontMatterEditingService().applying(
        document.components(separatedBy: "\n\n")[0],
        to: source, profile: profile
      ).draft.translationKey, source.translationKey)
  }

  func testPlanAndCancellationArePureAndConfirmedCreationSharesSourceKey() throws {
    let profile = hugoProfile()
    let source = makeSource(profile: profile)
    let original = source
    let plan = try makePlan(source: source, profile: profile)
    XCTAssertEqual(source, original)
    XCTAssertNil(source.translationKey)
    XCTAssertNotNil(plan.translatedDraft.translationKey)
    XCTAssertNil(plan.translatedDraft.publishReminderAt)
    let canceledPlan = try JSONDecoder().decode(
      AITranslationDraftPlan.self, from: JSONEncoder().encode(plan))
    XCTAssertEqual(canceledPlan, plan)
    XCTAssertEqual(source, original)

    let creation = try AITranslationDraftPlanningService.materializeCreation(
      plan, currentSource: source, profile: profile, existingDrafts: [source])
    let keyedSource = try XCTUnwrap(creation.updatedSource)
    XCTAssertEqual(keyedSource.translationKey, creation.translatedDraft.translationKey)
    XCTAssertEqual(keyedSource.translationContentFingerprint, source.translationContentFingerprint)
    XCTAssertEqual(keyedSource.bodyMarkdown, source.bodyMarkdown)
    XCTAssertEqual(keyedSource.publishReminderAt, source.publishReminderAt)
    XCTAssertNil(creation.translatedDraft.publishReminderAt)
    XCTAssertEqual(
      creation.translatedDraft.translationFreshness(source: keyedSource, profile: profile), .current
    )
  }

  func testExistingHugoKeyAndBundleIndexPathArePreserved() throws {
    var profile = hugoProfile()
    profile.markdownPathPattern = "content/posts/{slug}/index.md"
    var source = makeSource(profile: profile)
    source.translationKey = "manually-chosen-key"
    let plan = try makePlan(source: source, profile: profile)
    XCTAssertEqual(plan.sourceTranslationKey, source.translationKey)
    XCTAssertEqual(plan.destinationMarkdownPath, "content/posts/source/index.en.md")
    let creation = try AITranslationDraftPlanningService.materializeCreation(
      plan, currentSource: source, profile: profile, existingDrafts: [source])
    XCTAssertNil(creation.updatedSource)
    XCTAssertEqual(creation.translatedDraft.translationKey, source.translationKey)
    XCTAssertEqual(
      profile.markdownPath(for: creation.translatedDraft), plan.destinationMarkdownPath)
  }

  func testConfirmationRejectsDuplicatePathLanguageAndChangedPathSettings() throws {
    let profile = hugoProfile()
    let source = makeSource(profile: profile)
    let plan = try makePlan(source: source, profile: profile)
    var occupied = ArticleDraft(
      siteProfileID: profile.id, title: "Other", slug: "other", bodyMarkdown: "Other")
    occupied.repositoryPath = plan.destinationMarkdownPath
    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.materializeCreation(
        plan, currentSource: source, profile: profile, existingDrafts: [source, occupied])
    ) { error in
      XCTAssertEqual(error as? AITranslationDraftPlanningError, .destinationPathExists)
    }
    var movedProfile = profile
    movedProfile.translationMarkdownPathPattern = "content/{language}/posts/{sourceSlug}.md"
    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.materializeCreation(
        plan, currentSource: source, profile: movedProfile, existingDrafts: [source])
    ) { error in
      XCTAssertEqual(error as? AITranslationDraftPlanningError, .destinationPathChanged)
    }
    let newPlan = try makePlan(source: source, profile: movedProfile)
    XCTAssertEqual(newPlan.destinationMarkdownPath, "content/en/posts/source.md")
    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.materializeCreation(
        newPlan, currentSource: source, profile: movedProfile,
        existingDrafts: [source, plan.translatedDraft])
    ) { error in
      XCTAssertEqual(error as? AITranslationDraftPlanningError, .targetLanguageAlreadyExists)
    }
  }

  func testImportMergeKeepsRepositoryKeyRelationshipAndLocalReminder() throws {
    let profile = hugoProfile()
    let source = makeSource(profile: profile)
    var existing = try makePlan(source: source, profile: profile).translatedDraft
    existing.repositoryPath = "content/posts/source.en.md"
    existing.publishReminderAt = Date(timeIntervalSince1970: 12345)
    var imported = existing
    imported.id = UUID()
    imported.translationLink = nil
    imported.translationKey = "key-from-repository"
    imported.publishReminderAt = nil
    imported.bodyMarkdown = "Repository edit"
    let merged = LocalContentImportMergeService().makePlan(
      existingDrafts: [existing],
      result: LocalContentImportResult(importedDrafts: [imported], skippedPaths: []))
    XCTAssertEqual(merged.drafts.count, 1)
    XCTAssertEqual(merged.drafts[0].translationKey, imported.translationKey)
    XCTAssertEqual(merged.drafts[0].translationLink, existing.translationLink)
    XCTAssertEqual(merged.drafts[0].publishReminderAt, existing.publishReminderAt)
  }

  func testOldSnapshotWithoutKeyAndPlanFieldsRemainCompatible() throws {
    let profile = hugoProfile()
    let source = makeSource(profile: profile)
    let plan = try makePlan(source: source, profile: profile)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    object.removeValue(forKey: "sourceTranslationKey")
    object.removeValue(forKey: "destinationMarkdownPath")
    var translated = try XCTUnwrap(object["translatedDraft"] as? [String: Any])
    translated.removeValue(forKey: "translationKey")
    object["translatedDraft"] = translated
    let legacy = try JSONDecoder().decode(
      AITranslationDraftPlan.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.sourceTranslationKey)
    XCTAssertNil(legacy.translatedDraft.translationKey)
    let creation = try AITranslationDraftPlanningService.materializeCreation(
      legacy, currentSource: source, profile: profile, existingDrafts: [source])
    XCTAssertEqual(creation.updatedSource?.translationKey, creation.translatedDraft.translationKey)
  }

  func testOldImportCacheIsReparsedToRecoverHugoKey() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("project", isDirectory: true)
    let cache = directory.appendingPathComponent("cache", isDirectory: true)
    let content = root.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    let profile = hugoProfile()
    let source = ArticleDraft(
      siteProfileID: profile.id, title: "Source", slug: "source",
      translationKey: "key-from-markdown", bodyMarkdown: "Body")
    let file = content.appendingPathComponent("source.md")
    try FrontMatterRenderer().renderDocument(draft: source, profile: profile).write(
      to: file, atomically: true, encoding: .utf8)
    let importer = LocalContentImportService(contentIndexDirectoryURL: cache)
    let first = importer.importDrafts(rootURL: root, profile: profile)
    XCTAssertEqual(first.importedDrafts.first?.translationKey, source.translationKey)
    let indexStore = LocalContentImportIndexStore(directoryURL: cache)
    var oldIndex = indexStore.snapshot(profile: profile, rootURL: root)
    oldIndex.schemaVersion = 4
    oldIndex.entries = oldIndex.entries.mapValues { entry in
      var entry = entry
      entry.draft.translationKey = nil
      return entry
    }
    indexStore.save(oldIndex)
    let refreshed = importer.importDrafts(rootURL: root, profile: profile)
    XCTAssertEqual(refreshed.importedDrafts.first?.translationKey, source.translationKey)
  }

  @MainActor
  func testDismissingEntryPreviewLeavesWorkspaceSourceAndVersionsUnchanged() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workspace.json")), safeMode: true)
    var profile = store.activeProfile
    profile.applyPublishingDefaults(for: .hugo)
    store.updateActiveProfile(profile)
    store.updateDraft(makeSource(profile: profile))
    XCTAssertTrue(store.saveCurrentStateSynchronously())
    let source = try XCTUnwrap(store.selectedDraft)
    let beforeDrafts = store.drafts
    let beforeVersions = store.publishingStore.draftVersions
    _ = try store.ai.translationCreationPreview(
      source: source,
      target: AIPublishingChatTranslationDraftService.supportedTargets[0])
    XCTAssertEqual(store.drafts, beforeDrafts)
    XCTAssertEqual(store.publishingStore.draftVersions, beforeVersions)
    XCTAssertEqual(store.selectedDraftID, source.id)
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  @MainActor
  func testConfirmAtomicallyPersistsSourceKeyTranslationAndPreviousSourceVersion() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchPersistence(
      fileURL: directory.appendingPathComponent("workspace.json"))
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    var profile = store.activeProfile
    profile.applyPublishingDefaults(for: .hugo)
    store.updateActiveProfile(profile)
    let source = makeSource(profile: profile)
    store.updateDraft(source)
    XCTAssertTrue(store.saveCurrentStateSynchronously())
    let current = try XCTUnwrap(store.drafts.first { $0.id == source.id })
    let plan = try makePlan(source: current, profile: profile)
    let translated = try XCTUnwrap(store.ai.createLinkedTranslationDraft(from: plan))
    let saved = try XCTUnwrap(persistence.load())
    let savedSource = try XCTUnwrap(saved.drafts.first { $0.id == source.id })
    let savedTranslation = try XCTUnwrap(saved.drafts.first { $0.id == translated.id })
    XCTAssertEqual(savedSource.translationKey, savedTranslation.translationKey)
    XCTAssertNotNil(savedSource.translationKey)
    XCTAssertEqual(savedSource.bodyMarkdown, source.bodyMarkdown)
    XCTAssertEqual(savedSource.publishReminderAt, source.publishReminderAt)
    XCTAssertNil(savedTranslation.publishReminderAt)
    XCTAssertTrue(
      saved.draftVersions.contains { $0.draftID == source.id && $0.draft.translationKey == nil })
    XCTAssertFalse(store.hasUnsavedChanges)
    let countBeforeRepeat = store.drafts.count
    XCTAssertEqual(store.ai.createLinkedTranslationDraft(from: plan)?.id, translated.id)
    XCTAssertEqual(store.drafts.count, countBeforeRepeat)
  }

  @MainActor
  func testPrimarySaveFailureLeavesDraftsVersionsAndSelectionUnchanged() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("workspace.json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL), safeMode: true)
    var profile = store.activeProfile
    profile.applyPublishingDefaults(for: .hugo)
    store.updateActiveProfile(profile)
    store.updateDraft(makeSource(profile: profile))
    XCTAssertTrue(store.saveCurrentStateSynchronously())
    let source = try XCTUnwrap(store.selectedDraft)
    let plan = try makePlan(source: source, profile: profile)
    let beforeDrafts = store.drafts
    let beforeVersions = store.publishingStore.draftVersions
    let beforeSelection = store.selectedDraftID
    try FileManager.default.removeItem(at: fileURL)
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    XCTAssertNil(store.ai.createLinkedTranslationDraft(from: plan))
    XCTAssertEqual(store.drafts, beforeDrafts)
    XCTAssertEqual(store.publishingStore.draftVersions, beforeVersions)
    XCTAssertEqual(store.selectedDraftID, beforeSelection)
    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertNotNil(store.persistenceStore.lastSaveError)
  }

  @MainActor
  func testRecoveryProtectionDoesNotCreateEitherDraftOrVersion() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workspace.json")), safeMode: true)
    var profile = store.activeProfile
    profile.applyPublishingDefaults(for: .hugo)
    store.updateActiveProfile(profile)
    store.updateDraft(makeSource(profile: profile))
    let source = try XCTUnwrap(store.selectedDraft)
    let plan = try makePlan(source: source, profile: profile)
    let beforeDrafts = store.drafts
    let beforeVersions = store.publishingStore.draftVersions
    store.persistenceStore.protectWritesForUnrecoverableSnapshot(message: "test")
    XCTAssertNil(store.ai.createLinkedTranslationDraft(from: plan))
    XCTAssertEqual(store.drafts, beforeDrafts)
    XCTAssertEqual(store.publishingStore.draftVersions, beforeVersions)
    XCTAssertEqual(store.selectedDraftID, source.id)
  }

  func testEntryCommandsUseExistingExplicitTranslationParsing() throws {
    for target in AIPublishingChatTranslationDraftService.supportedTargets {
      let command = try XCTUnwrap(
        AIPublishingChatTranslationDraftService.creationRequest(target: target))
      let parsed = try XCTUnwrap(AIPublishingChatTranslationDraftService.target(for: command))
      XCTAssertEqual(parsed.languageCode, target.languageCode)
    }
  }

  private func hugoProfile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .hugo)
    return profile
  }

  private func makeSource(profile: SiteProfile) -> ArticleDraft {
    var source = ArticleDraft(
      siteProfileID: profile.id, title: "原稿", slug: "source",
      summary: "原摘要", bodyMarkdown: "# 原稿\n\n原文正文")
    source.publishReminderAt = Date(timeIntervalSince1970: 2_000_000_000)
    return source
  }

  private func makePlan(source: ArticleDraft, profile: SiteProfile) throws -> AITranslationDraftPlan
  {
    try AITranslationDraftPlanningService.plan(
      source: source, profile: profile,
      targetLanguageCode: "en", translatedTitle: "Translation", translatedSummary: "Summary",
      translatedBodyMarkdown: "# Translation\n\nTranslated body")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "translation-creation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
