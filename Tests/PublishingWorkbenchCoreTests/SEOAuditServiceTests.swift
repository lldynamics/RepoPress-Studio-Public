import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

final class SEOAuditServiceTests: XCTestCase {
  func testReportPassesCoreSEOFieldsForPublicArticle() {
    let profile = SiteProfile.defaultProfile
    let attachmentID = UUID(uuidString: "07B42021-7E75-4623-84A8-A72F086DF198")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "static/images/2026/cover.jpg",
      altText: "Cover"
    )
    let summary = "这篇文章说明 macOS 发布控制台如何把本地仓库、预检、图片、SEO 和发布说明收进一个清晰的桌面工作流，减少发布前来回切换。"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "macOS RepoPress实践",
      slug: "mac-publishing-console",
      tags: ["Mac", "发布"],
      draft: false,
      summary: summary,
      coverAttachmentID: attachmentID,
      bodyMarkdown: """
        # macOS 发布控制台概览

        This article is long enough to exercise the local SEO audit path.
        """,
      attachments: [attachment]
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertEqual(report.warningCount, 0)
    XCTAssertEqual(report.errorCount, 0)
    XCTAssertEqual(report.h1Count, 1)
    XCTAssertTrue(report.hasPublishableCoverImage)
    XCTAssertTrue(report.frontMatterPreview.contains("og_preview_img"))
  }

  func testReportFlagsMissingSummaryCoverTagsAndHeading() {
    var profile = SiteProfile.defaultProfile
    profile.defaultTags = []
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "短题",
      slug: "short-title",
      tags: [],
      draft: false,
      summary: "",
      bodyMarkdown: "Body without a top level heading but enough text to check SEO hints."
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertTrue(report.findings.contains { $0.title == "标题偏短" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "摘要为空" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "无法确认页面 H1" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "缺少预览图" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "标签为空" && $0.severity == .warning })
  }

  func testPrivateArticleDoesNotRequirePublishableCoverImage() {
    let profile = SiteProfile.defaultProfile
    let attachmentID = UUID(uuidString: "3E4D3DD1-CBC6-4FB2-A9E8-D7D9B3098200")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "private-cover.jpg",
      relativePublishPath: "/images/2026/private-cover.jpg",
      repositoryPath: "static/images/2026/private-cover.jpg",
      altText: "Private cover"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "私密草稿发布前检查记录",
      slug: "private-seo",
      draft: true,
      visibility: .private,
      summary: "这篇私密草稿只用于验证本地发布控制台不会把封面图写进公开 SEO 元数据。",
      coverAttachmentID: attachmentID,
      bodyMarkdown: "# 私密草稿发布前检查记录\n\nPrivate body content for local checks.",
      attachments: [attachment]
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertFalse(report.findings.contains { $0.title == "缺少预览图" })
    XCTAssertTrue(report.findings.contains { $0.title == "私密文章不输出预览图" && $0.severity == .info })
    XCTAssertFalse(report.frontMatterPreview.contains("private-cover.jpg"))
  }

  func testDuplicateNormalizedH1AndTitleProducesWarningWhenEnabled() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "  RepoPress\u{00A0}发布指南  ",
      slug: "repopress-guide",
      tags: ["发布"],
      summary: "这是一段足够长的摘要，用于验证正文标题重复提示不会影响其他 SEO 审计字段。",
      bodyMarkdown: "# repopress 发布指南\n\n正文内容。"
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertTrue(
      report.findings.contains {
        $0.title == "正文 H1 与标题重复" && $0.severity == .warning
      })
  }

  func testKnownThemeTitleH1AvoidsMissingBodyH1Warning() {
    var profile = SiteProfile.defaultProfile
    profile.themeProvidesTitleH1 = true
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "主题提供页面标题",
      slug: "theme-title-h1",
      tags: ["SEO"],
      summary: "这是一段足够长的摘要，用于验证主题已知提供 H1 时正文无需重复添加一级标题。",
      bodyMarkdown: "正文直接从导语开始。"
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertFalse(report.findings.contains { $0.title == "页面缺少 H1" })
    XCTAssertFalse(report.findings.contains { $0.title == "无法确认页面 H1" })
    XCTAssertTrue(
      report.findings.contains { $0.title == "主题提供页面 H1" && $0.severity == .info })
  }

  func testDuplicateH1AndTitleDoesNotProduceWarningWhenDisabled() {
    var profile = SiteProfile.defaultProfile
    profile.resolvedWarnsWhenBodyH1DuplicatesTitle = false
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "RepoPress 发布指南",
      slug: "repopress-guide",
      tags: ["发布"],
      summary: "这是一段足够长的摘要，用于验证关闭正文标题重复提示后报告会立即更新。",
      bodyMarkdown: "# RepoPress 发布指南\n\n正文内容。"
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertFalse(report.findings.contains { $0.title == "正文 H1 与标题重复" })
    XCTAssertTrue(report.findings.contains { $0.title == "正文 H1 已设置" && $0.severity == .info })
  }

  func testLegacyProfileWithoutH1DuplicateWarningPreferenceDefaultsToEnabled() throws {
    let encoded = try JSONEncoder.workbench.encode(SiteProfile(name: "旧站点"))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "warnsWhenBodyH1DuplicatesTitle")
    object.removeValue(forKey: "themeProvidesTitleH1")
    object.removeValue(forKey: "defaultSocialImagePath")
    object.removeValue(forKey: "defaultSocialImageAltText")
    object.removeValue(forKey: "seoArticleSocialImagePreferences")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder.workbench.decode(SiteProfile.self, from: legacyData)

    XCTAssertNil(decoded.warnsWhenBodyH1DuplicatesTitle)
    XCTAssertTrue(decoded.resolvedWarnsWhenBodyH1DuplicatesTitle)
    XCTAssertNil(decoded.themeProvidesTitleH1)
    XCTAssertNil(decoded.resolvedDefaultSocialImagePath)
    XCTAssertNil(decoded.seoArticleSocialImagePreferences)
  }

  func testHugoThemeTitleHeadingControlsAutomaticDuplicateWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SEOAuditThemeH1-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let template = root.appendingPathComponent("themes/paper/layouts/_default/single.html")
    try FileManager.default.createDirectory(
      at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "theme = \"paper\"\n".write(
      to: root.appendingPathComponent("hugo.toml"), atomically: true, encoding: .utf8)
    var profile = SiteProfile(
      name: "主题站点", siteKind: .hugo, localRepositoryRootPath: root.path)
    let draft = duplicateTitleDraft(profile: profile)

    try "<article><h1>{{ .Title }}</h1></article>".write(
      to: template, atomically: true, encoding: .utf8)
    let detector = ThemeTitleH1Detector()
    let providesH1 = detector.cachedOrDetect(profile: profile, repositoryRevision: UUID())
    XCTAssertTrue(providesH1 ?? false)
    XCTAssertTrue(profile.resolvedWarnsWhenBodyH1DuplicatesTitle)
    profile.themeProvidesTitleH1 = providesH1
    XCTAssertTrue(hasDuplicateTitleWarning(draft: draft, profile: profile))

    try "<article><h2>{{ .Title }}</h2></article>".write(
      to: template, atomically: true, encoding: .utf8)
    XCTAssertTrue(profile.resolvedWarnsWhenBodyH1DuplicatesTitle)
    profile.themeProvidesTitleH1 = nil
    let doesNotProvideH1 = detector.cachedOrDetect(profile: profile, repositoryRevision: UUID())
    XCTAssertFalse(doesNotProvideH1 ?? true)
    XCTAssertTrue(profile.resolvedWarnsWhenBodyH1DuplicatesTitle)
    profile.themeProvidesTitleH1 = doesNotProvideH1
    XCTAssertFalse(hasDuplicateTitleWarning(draft: draft, profile: profile))

    profile.resolvedWarnsWhenBodyH1DuplicatesTitle = true
    XCTAssertFalse(hasDuplicateTitleWarning(draft: draft, profile: profile))
    profile.themeProvidesTitleH1 = true
    XCTAssertTrue(hasDuplicateTitleWarning(draft: draft, profile: profile))
    profile.resolvedWarnsWhenBodyH1DuplicatesTitle = false
    XCTAssertFalse(hasDuplicateTitleWarning(draft: draft, profile: profile))
  }

  func testConcurrentEditorThemeResolutionUsesEachCompletedDetection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SEOAuditConcurrentH1-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let template = root.appendingPathComponent("themes/paper/layouts/_default/single.html")
    try FileManager.default.createDirectory(
      at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "theme = \"paper\"\n".write(
      to: root.appendingPathComponent("hugo.toml"), atomically: true, encoding: .utf8)
    try "<article><h2>{{ .Title }}</h2></article>".write(
      to: template, atomically: true, encoding: .utf8)
    let profile = SiteProfile(
      name: "并发主题站点", siteKind: .hugo, localRepositoryRootPath: root.path)
    let revision = UUID()
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<24 {
        group.addTask { await profile.resolveBodyH1DuplicateWarning(repositoryRevision: revision) }
      }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }
    XCTAssertEqual(results.count, 24)
    XCTAssertTrue(results.allSatisfy { !$0 })
  }

  func testUnknownThemeLayoutKeepsConservativeAdvisoryWithoutInventingKnownFact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SEOAuditUnknownH1-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let template = root.appendingPathComponent("templates/page.html")
    try FileManager.default.createDirectory(
      at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{% include \"article-title.html\" %}".write(
      to: template, atomically: true, encoding: .utf8)
    let profile = SiteProfile(
      name: "Zola 主题站点", siteKind: .zola, localRepositoryRootPath: root.path)

    let resolution = await profile.resolveThemeTitleH1(repositoryRevision: UUID())

    XCTAssertNil(resolution.providesTitleH1)
    XCTAssertEqual(resolution.source, .unknown)
    XCTAssertTrue(profile.resolvedWarnsWhenBodyH1DuplicatesTitle)
    XCTAssertTrue(
      hasDuplicateTitleWarning(draft: duplicateTitleDraft(profile: profile), profile: profile))
  }

  @MainActor
  func testSynchronousStoreReportUsesOnlyMatchingCompletedThemeCacheAndExplicitOverride() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SEOAuditSynchronousCache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let template = root.appendingPathComponent("layouts/_default/single.html")
    try FileManager.default.createDirectory(
      at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "<article><h2>{{ .Title }}</h2></article>".write(
      to: template, atomically: true, encoding: .utf8)

    let persistenceURL = root.appendingPathComponent("workbench.json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      safeMode: true
    )
    store.updateActiveProfile { profile in
      profile.siteKind = .hugo
      profile.localRepositoryRootPath = root.path
      profile.themeProvidesTitleH1 = nil
    }
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "同步 SEO 报告"
    draft.bodyMarkdown = "正文没有一级标题。"
    let profile = store.profile(for: draft)
    let currentRevision = store.repositoryReportRevision
    let staleRevision = UUID()
    let detector = ThemeTitleH1Detector()

    XCTAssertFalse(
      detector.cachedOrDetect(profile: profile, repositoryRevision: staleRevision) ?? true)
    XCTAssertNil(detector.cachedResult(profile: profile, repositoryRevision: currentRevision))
    let unknownReport = store.seoReport(for: draft)
    XCTAssertTrue(unknownReport.findings.contains { $0.title == "无法确认页面 H1" })
    XCTAssertFalse(unknownReport.findings.contains { $0.title == "页面缺少 H1" })

    XCTAssertFalse(
      detector.cachedOrDetect(profile: profile, repositoryRevision: currentRevision) ?? true)
    try FileManager.default.removeItem(at: template)
    XCTAssertFalse(
      store.seoReport(for: draft).findings.contains { $0.title == "无法确认页面 H1" })
    XCTAssertTrue(
      store.seoReport(for: draft).findings.contains { $0.title == "页面缺少 H1" })

    store.setSEOThemeProvidesTitleH1(true, forProfileID: profile.id)
    let explicitReport = store.seoReport(for: draft)
    XCTAssertTrue(explicitReport.findings.contains { $0.title == "主题提供页面 H1" })
    XCTAssertFalse(explicitReport.findings.contains { $0.title == "页面缺少 H1" })
  }

  func testSynchronousThemeCacheReadRejectsStaleRevisionAndPreservesUnknown() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SEOAuditRevisionCache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let template = root.appendingPathComponent("templates/page.html")
    try FileManager.default.createDirectory(
      at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "<article><h2>{{ page.title }}</h2></article>".write(
      to: template, atomically: true, encoding: .utf8)
    let profile = SiteProfile(
      name: "缓存 revision 站点", siteKind: .zola, localRepositoryRootPath: root.path)
    let completedRevision = UUID()
    let staleRevision = UUID()
    let detector = ThemeTitleH1Detector()

    XCTAssertFalse(
      detector.cachedOrDetect(profile: profile, repositoryRevision: completedRevision) ?? true)
    XCTAssertEqual(
      detector.cachedResult(profile: profile, repositoryRevision: completedRevision), false)
    XCTAssertNil(detector.cachedResult(profile: profile, repositoryRevision: staleRevision))

    try "{% include \"article-title.html\" %}".write(
      to: template, atomically: true, encoding: .utf8)
    XCTAssertNil(detector.cachedOrDetect(profile: profile, repositoryRevision: staleRevision))
    XCTAssertNil(detector.cachedResult(profile: profile, repositoryRevision: staleRevision))
    XCTAssertNil(detector.cachedResult(profile: profile, repositoryRevision: completedRevision))
  }

  private func duplicateTitleDraft(profile: SiteProfile) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: "RepoPress 发布指南",
      slug: "repopress-guide",
      summary: "这是一段足够长的摘要，用于验证主题标题渲染对重复 H1 提示默认值的影响。",
      bodyMarkdown: "# RepoPress 发布指南\n\n正文内容。"
    )
  }

  private func hasDuplicateTitleWarning(draft: ArticleDraft, profile: SiteProfile) -> Bool {
    SEOAuditService().report(draft: draft, profile: profile).findings.contains {
      $0.title == "正文 H1 与标题重复" && $0.severity == .warning
    }
  }
}
