import XCTest
@testable import PublishingWorkbenchCore

final class ModernSiteFrameworkSupportTests: XCTestCase {
  func testRepositoryScanDetectsNextQuartzAndFoamMarkers() throws {
    let fixtures: [(SiteKind, String, Bool)] = [
      (.nextJS, "contentlayer.config.ts", false),
      (.nextJS, "velite.config.mts", false),
      (.quartz, "quartz.config.ts", false),
      (.foam, ".foam", true),
    ]

    for (siteKind, marker, markerIsDirectory) in fixtures {
      let rootURL = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      var profile = SiteProfile.defaultProfile
      profile.applyPublishingDefaults(for: siteKind)
      profile.rememberLocalRepositoryRoot(rootURL)

      let contentRoot = profile.contentRoot.normalizedRelativePath()
      if !contentRoot.isEmpty {
        try FileManager.default.createDirectory(
          at: rootURL.appendingPathComponent(contentRoot, isDirectory: true),
          withIntermediateDirectories: true
        )
      }
      let assetRoot = profile.assetRoot.normalizedRelativePath()
      if !assetRoot.isEmpty {
        try FileManager.default.createDirectory(
          at: rootURL.appendingPathComponent(assetRoot, isDirectory: true),
          withIntermediateDirectories: true
        )
      }
      if markerIsDirectory {
        try FileManager.default.createDirectory(
          at: rootURL.appendingPathComponent(marker, isDirectory: true),
          withIntermediateDirectories: true
        )
      } else {
        try "export default {}\n".write(
          to: rootURL.appendingPathComponent(marker),
          atomically: true,
          encoding: .utf8
        )
      }
      if siteKind == .foam {
        try "# Workspace note\n".write(
          to: rootURL.appendingPathComponent("workspace-note.md"),
          atomically: true,
          encoding: .utf8
        )
        let dependencyDirectory = rootURL.appendingPathComponent("node_modules/example", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyDirectory, withIntermediateDirectories: true)
        try "# Dependency readme\n".write(
          to: dependencyDirectory.appendingPathComponent("README.md"),
          atomically: true,
          encoding: .utf8
        )
      }

      let report = LocalRepositoryService().scan(profile: profile)
      XCTAssertEqual(report.detectedKind, siteKind)
      XCTAssertTrue(report.contentRootExists)
      XCTAssertTrue(report.assetRootExists)
      if siteKind == .foam {
        XCTAssertEqual(report.markdownFileCount, 1)
      }
    }
  }

  func testModernFrameworkRoutesUseProfileRootsIndexesAndPermalinks() {
    let resolver = SiteArticleURLResolver()

    var vitePress = SiteProfile.defaultProfile
    vitePress.applyPublishingDefaults(for: .vitePress)
    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "docs/posts/guide/index.md",
        profile: vitePress
      ),
      "/guide/"
    )

    var next = SiteProfile.defaultProfile
    next.applyPublishingDefaults(for: .nextJS)
    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/posts/releases/version-2.mdx",
        profile: next
      ),
      "/blog/releases/version-2/"
    )
    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/posts/releases/version-2.mdx",
        profile: next,
        permalink: "/changelog/v2/"
      ),
      "/changelog/v2/"
    )
    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/posts/releases/version-2.mdx",
        profile: next,
        permalink: "https://outside.example/redirect"
      ),
      "/blog/releases/version-2/"
    )

    var quartz = SiteProfile.defaultProfile
    quartz.applyPublishingDefaults(for: .quartz)
    XCTAssertEqual(
      resolver.relativeWebPath(from: "content/garden/index.md", profile: quartz),
      "/garden/"
    )

    var foam = SiteProfile.defaultProfile
    foam.applyPublishingDefaults(for: .foam)
    XCTAssertEqual(
      resolver.relativeWebPath(from: "projects/README.md", profile: foam),
      "/projects/"
    )
  }

  func testQuartzAndFoamFrontMatterPreservesDigitalGardenMetadata() throws {
    let coverID = UUID()
    let cover = DraftAttachment(
      id: coverID,
      originalFilename: "garden.png",
      relativePublishPath: "/attachments/garden.png",
      repositoryPath: "content/attachments/garden.png"
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Connected Notes",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "connected-notes",
      tags: ["garden", "links"],
      aliases: ["Linked Notes", "Garden Entry"],
      permalink: "/knowledge/connected-notes/",
      draft: true,
      summary: "A linked-note entry.",
      coverAttachmentID: coverID,
      bodyMarkdown: "[[Other Note]]",
      attachments: [cover]
    )

    var quartz = SiteProfile.defaultProfile
    quartz.applyPublishingDefaults(for: .quartz)
    let quartzFrontMatter = FrontMatterRenderer().render(draft: draft, profile: quartz)
    XCTAssertTrue(quartzFrontMatter.contains("aliases: [\"Linked Notes\", \"Garden Entry\"]"))
    XCTAssertTrue(quartzFrontMatter.contains("permalink: \"/knowledge/connected-notes/\""))
    XCTAssertTrue(quartzFrontMatter.contains("draft: true"))
    XCTAssertTrue(quartzFrontMatter.contains("socialImage: \"/attachments/garden.png\""))

    var foam = SiteProfile.defaultProfile
    foam.applyPublishingDefaults(for: .foam)
    let foamFrontMatter = FrontMatterRenderer().render(draft: draft, profile: foam)
    XCTAssertTrue(foamFrontMatter.contains("created: \"2026-08-29\""))
    XCTAssertTrue(foamFrontMatter.contains("status: \"draft\""))
    XCTAssertTrue(foamFrontMatter.contains("aliases: [\"Linked Notes\", \"Garden Entry\"]"))
  }

  func testQuartzPermalinkFlowsIntoSEOCanonicalURL() {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .quartz)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Permanent Garden Note",
      slug: "source-filename",
      permalink: "/garden/permanent-note/",
      draft: false,
      summary: "Stable digital-garden URL."
    )

    let snapshot = SEOSocialPreviewService().snapshot(
      draft: draft,
      profile: profile,
      localPreviewURL: URL(string: "https://example.com/")
    )

    XCTAssertEqual(snapshot.canonicalURLText, "https://example.com/garden/permanent-note")
    XCTAssertEqual(
      snapshot.metaTags.first { $0.property == "og:url" }?.content,
      "https://example.com/garden/permanent-note"
    )
  }

  func testImportsQuartzAliasesPermalinkAndMetadataAliases() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    ---
    title: "Quartz Entry"
    created: "2026-08-29"
    tag: [garden, quartz]
    alias: ["Linked Entry", "Permanent Note"]
    permalink: /garden/permanent-entry/
    socialDescription: "A Quartz digital-garden entry."
    publish: false
    ---

    [[Related Note]]
    """.write(
      to: rootURL.appendingPathComponent("content/quartz-entry.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .quartz)
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)

    XCTAssertEqual(draft.tags, ["garden", "quartz"])
    XCTAssertEqual(draft.aliases, ["Linked Entry", "Permanent Note"])
    XCTAssertEqual(draft.permalink, "/garden/permanent-entry/")
    XCTAssertEqual(draft.summary, "A Quartz digital-garden entry.")
    XCTAssertTrue(draft.draft)
  }

  func testImportsFoamWorkspaceRootAndDraftStatus() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try """
    ---
    title: "Foam Note"
    created: "2026-08-29"
    tags: [foam, notes]
    status: draft
    ---

    [[Inbox]]
    """.write(
      to: rootURL.appendingPathComponent("foam-note.md"),
      atomically: true,
      encoding: .utf8
    )
    let dependencyDirectory = rootURL.appendingPathComponent("node_modules/example", isDirectory: true)
    try FileManager.default.createDirectory(at: dependencyDirectory, withIntermediateDirectories: true)
    try "# Dependency readme\n".write(
      to: dependencyDirectory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .foam)
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)

    XCTAssertEqual(result.importedDrafts.count, 1)
    XCTAssertEqual(draft.repositoryPath, "foam-note.md")
    XCTAssertEqual(draft.tags, ["foam", "notes"])
    XCTAssertTrue(draft.draft)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModernSiteFrameworkSupport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
