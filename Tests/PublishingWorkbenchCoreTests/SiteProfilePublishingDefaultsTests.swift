import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class SiteProfilePublishingDefaultsTests: XCTestCase {
  func testDefaultPublishingRulesCoverSupportedStaticSiteKinds() {
    let defaultsByKind = Dictionary(
      uniqueKeysWithValues: SiteKind.allCases.map {
        ($0, SiteProfile.defaultPublishingDefaults(for: $0))
      }
    )

    XCTAssertEqual(defaultsByKind[.zola]?.frontMatterStyle, .toml)
    XCTAssertEqual(defaultsByKind[.zola]?.contentRoot, "content")
    XCTAssertEqual(defaultsByKind[.astro]?.frontMatterStyle, .yaml)
    XCTAssertEqual(defaultsByKind[.astro]?.contentRoot, "src/content/blog")
    XCTAssertEqual(defaultsByKind[.hugo]?.markdownPathPattern, "content/posts/{slug}.md")
    XCTAssertEqual(defaultsByKind[.vitePress]?.contentRoot, "docs/posts")
    XCTAssertEqual(defaultsByKind[.vitePress]?.assetRoot, "docs/public")
    XCTAssertEqual(defaultsByKind[.vitePress]?.markdownPathPattern, "docs/posts/{slug}.md")
    XCTAssertEqual(defaultsByKind[.nextJS]?.markdownPathPattern, "content/posts/{slug}.mdx")
    XCTAssertEqual(defaultsByKind[.nextJS]?.assetRoot, "public")
    XCTAssertEqual(defaultsByKind[.quartz]?.contentRoot, "content")
    XCTAssertEqual(defaultsByKind[.quartz]?.slugValidationRule, .relaxed)
    XCTAssertEqual(defaultsByKind[.foam]?.contentRoot, ".")
    XCTAssertEqual(defaultsByKind[.foam]?.markdownPathPattern, "{slug}.md")
    XCTAssertEqual(defaultsByKind[.hexo]?.contentRoot, "source/_posts")
    XCTAssertEqual(
      defaultsByKind[.jekyll]?.markdownPathPattern, "_posts/{year}-{month}-{day}-{slug}.md")
    XCTAssertEqual(defaultsByKind[.jekyll]?.includeDraftFlagInFrontMatter, false)
    XCTAssertEqual(defaultsByKind[.docusaurus]?.contentRoot, "docs")
    XCTAssertEqual(defaultsByKind[.docusaurus]?.assetRoot, "static")
    XCTAssertEqual(defaultsByKind[.docusaurus]?.includeDraftFlagInFrontMatter, true)
    XCTAssertEqual(defaultsByKind[.mkDocs]?.contentRoot, "docs")
    XCTAssertEqual(defaultsByKind[.mkDocs]?.imagePathPattern, "docs/images/{year}/{filename}")
    XCTAssertEqual(defaultsByKind[.mkDocs]?.includeDraftFlagInFrontMatter, false)
  }

  func testStarlightPresetKeepsAstroKindAndUsesDocsCollection() {
    let defaults = SiteProfile.starlightPublishingDefaults

    XCTAssertEqual(defaults.siteKind, .astro)
    XCTAssertEqual(defaults.frontMatterStyle, .yaml)
    XCTAssertEqual(defaults.contentRoot, "src/content/docs")
    XCTAssertEqual(defaults.markdownPathPattern, "src/content/docs/{slug}.md")
    XCTAssertTrue(defaults.includeDraftFlagInFrontMatter)
  }

  func testDocumentationPresetsRenderRecognizedFrontMatterFields() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Getting started",
      slug: "getting-started",
      summary: "Install and configure",
      bodyMarkdown: "Body"
    )
    var starlight = SiteProfile(name: "Starlight", siteKind: .astro)
    starlight.applyPublishingDefaults(SiteProfile.starlightPublishingDefaults)
    let starlightYAML = FrontMatterRenderer().render(draft: draft, profile: starlight)
    XCTAssertTrue(starlightYAML.contains("title:"))
    XCTAssertTrue(starlightYAML.contains("description:"))
    XCTAssertTrue(starlightYAML.contains("slug:"))
    XCTAssertFalse(starlightYAML.contains("date:"))
    XCTAssertFalse(starlightYAML.contains("cover:"))

    var docusaurus = SiteProfile(name: "Docusaurus", siteKind: .docusaurus)
    docusaurus.applyPublishingDefaults(for: .docusaurus)
    let docusaurusYAML = FrontMatterRenderer().render(draft: draft, profile: docusaurus)
    XCTAssertTrue(docusaurusYAML.contains("slug:"))
    XCTAssertFalse(docusaurusYAML.contains("date:"))

    var mkDocs = SiteProfile(name: "MkDocs", siteKind: .mkDocs)
    mkDocs.applyPublishingDefaults(for: .mkDocs)
    let mkDocsYAML = FrontMatterRenderer().render(draft: draft, profile: mkDocs)
    XCTAssertTrue(mkDocsYAML.contains("description:"))
    XCTAssertFalse(mkDocsYAML.contains("slug:"))
    XCTAssertFalse(mkDocsYAML.contains("date:"))
    XCTAssertFalse(mkDocsYAML.contains("cover:"))

    var quartz = SiteProfile(name: "Quartz 4", siteKind: .quartz)
    quartz.applyPublishingDefaults(for: .quartz)
    let quartzYAML = FrontMatterRenderer().render(draft: draft, profile: quartz)
    XCTAssertTrue(quartzYAML.contains("date:"))
    XCTAssertTrue(quartzYAML.contains("draft:"))
    XCTAssertFalse(quartzYAML.contains("slug:"))
    XCTAssertFalse(quartzYAML.contains("categories:"))
  }

  func testApplyingJekyllDefaultsRendersDatedPostPathAndAssetPaths() {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .jekyll)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Jekyll Post",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "jekyll-post",
      bodyMarkdown: "Body"
    )

    XCTAssertEqual(profile.siteKind, .jekyll)
    XCTAssertEqual(profile.frontMatterStyle, .yaml)
    XCTAssertEqual(profile.markdownPath(for: draft), "_posts/2026-08-29-jekyll-post.md")
    XCTAssertEqual(
      profile.imageRepositoryPath(filename: "cover.jpg", draft: draft),
      "assets/images/2026/cover.jpg")
    XCTAssertEqual(
      profile.publicImagePath(filename: "cover.jpg", draft: draft), "/assets/images/2026/cover.jpg")
    XCTAssertEqual(
      profile.videoRepositoryPath(filename: "demo.mp4", draft: draft), "assets/videos/2026/demo.mp4"
    )
    XCTAssertEqual(
      profile.publicVideoPath(filename: "demo.mp4", draft: draft), "/assets/videos/2026/demo.mp4")
  }

  func testPrivateDraftUsesPrivateRepositoryRoot() {
    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Private Post",
      slug: "private-post",
      visibility: .private
    )

    XCTAssertEqual(profile.markdownPath(for: draft), "private/posts/private-post.md")
  }

  func testPrivateDraftPreservesExistingPrivateRepositoryPath() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{year}/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Existing Private Post",
      slug: "renamed-slug",
      visibility: .private,
      repositoryPath: "private/legacy/original-name.md"
    )

    XCTAssertEqual(profile.markdownPath(for: draft), "private/legacy/original-name.md")
  }

  func testStoreAppliesSiteKindDefaultsAndKeepsProfileIdentity() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let profileID = store.activeProfileID

    store.applySiteKindDefaults(.astro)

    XCTAssertEqual(store.activeProfileID, profileID)
    XCTAssertEqual(store.activeProfile.siteKind, .astro)
    XCTAssertEqual(store.activeProfile.frontMatterStyle, .yaml)
    XCTAssertEqual(store.activeProfile.contentRoot, "src/content/blog")
    XCTAssertEqual(store.activeProfile.markdownPathPattern, "src/content/blog/{slug}.mdx")
    XCTAssertEqual(store.activeProfile.imagePathPattern, "public/images/{year}/{filename}")
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PersonalSitePublisherMacPublishingDefaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}
