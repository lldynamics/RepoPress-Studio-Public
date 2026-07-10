import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class SiteProfilePublishingDefaultsTests: XCTestCase {
  func testDefaultPublishingRulesCoverSupportedStaticSiteKinds() {
    let defaultsByKind = Dictionary(
      uniqueKeysWithValues: SiteKind.allCases.map { ($0, SiteProfile.defaultPublishingDefaults(for: $0)) }
    )

    XCTAssertEqual(defaultsByKind[.zola]?.frontMatterStyle, .toml)
    XCTAssertEqual(defaultsByKind[.zola]?.contentRoot, "content")
    XCTAssertEqual(defaultsByKind[.astro]?.frontMatterStyle, .yaml)
    XCTAssertEqual(defaultsByKind[.astro]?.contentRoot, "src/content/blog")
    XCTAssertEqual(defaultsByKind[.hugo]?.markdownPathPattern, "content/posts/{slug}.md")
    XCTAssertEqual(defaultsByKind[.hexo]?.contentRoot, "source/_posts")
    XCTAssertEqual(defaultsByKind[.jekyll]?.markdownPathPattern, "_posts/{year}-{month}-{day}-{slug}.md")
    XCTAssertEqual(defaultsByKind[.jekyll]?.includeDraftFlagInFrontMatter, false)
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
    XCTAssertEqual(profile.imageRepositoryPath(filename: "cover.jpg", draft: draft), "assets/images/2026/cover.jpg")
    XCTAssertEqual(profile.publicImagePath(filename: "cover.jpg", draft: draft), "/assets/images/2026/cover.jpg")
  }

  func testStoreAppliesSiteKindDefaultsAndKeepsProfileIdentity() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
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
      .appendingPathComponent("PersonalSitePublisherMacPublishingDefaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}
