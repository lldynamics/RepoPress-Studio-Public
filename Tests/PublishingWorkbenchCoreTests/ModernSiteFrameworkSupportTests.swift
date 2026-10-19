import PublishingDomainContracts
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
        let dependencyDirectory = rootURL.appendingPathComponent(
          "node_modules/example", isDirectory: true)
        try FileManager.default.createDirectory(
          at: dependencyDirectory, withIntermediateDirectories: true)
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

  func testRepositoryScanDetectsDocusaurusAndMkDocsMarkers() throws {
    let fixtures: [(SiteKind, String, String)] = [
      (.docusaurus, "docusaurus.config.ts", "docs"),
      (.mkDocs, "mkdocs.yml", "docs"),
    ]

    for (siteKind, marker, contentRoot) in fixtures {
      let rootURL = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      var profile = SiteProfile.defaultProfile
      profile.applyPublishingDefaults(for: siteKind)
      profile.rememberLocalRepositoryRoot(rootURL)

      try FileManager.default.createDirectory(
        at: rootURL.appendingPathComponent(contentRoot, isDirectory: true),
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: rootURL.appendingPathComponent(profile.assetRoot, isDirectory: true),
        withIntermediateDirectories: true
      )
      let markerContents = siteKind == .mkDocs ? "site_name: Docs\n" : "export default {}\n"
      try markerContents.write(
        to: rootURL.appendingPathComponent(marker), atomically: true, encoding: .utf8
      )

      let report = LocalRepositoryService().scan(profile: profile)
      XCTAssertEqual(report.detectedKind, siteKind)
      XCTAssertTrue(report.contentRootExists)
      XCTAssertTrue(report.assetRootExists)
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

  func testImportsSummaryAndPublishDateAliasesFromYAMLAndTOML() throws {
    let fixtures: [(FrontMatterStyle, String, String, String)] = [
      (.yaml, "socialDescription", "publishDate", "YAML camel aliases"),
      (.yaml, "socialdescription", "publishdate", "YAML lowercase aliases"),
      (.toml, "socialDescription", "publishDate", "TOML camel aliases"),
      (.toml, "socialdescription", "publishdate", "TOML lowercase aliases"),
    ]

    for (style, summaryKey, dateKey, title) in fixtures {
      let rootURL = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      var profile = SiteProfile.defaultProfile
      profile.applyPublishingDefaults(for: style == .toml ? .zola : .quartz)
      profile.frontMatterStyle = style
      profile.markdownPathPattern = "content/{slug}.md"
      let (delimiter, assignment) = style == .toml ? ("+++", " = ") : ("---", ": ")
      let source = """
        \(delimiter)
        title\(assignment)"\(title)"
        \(dateKey)\(assignment)"2026-08-29"
        \(summaryKey)\(assignment)"Imported summary"
        \(delimiter)

        Body
        """
      try FileManager.default.createDirectory(
        at: rootURL.appendingPathComponent("content", isDirectory: true),
        withIntermediateDirectories: true
      )
      try source.write(
        to: rootURL.appendingPathComponent(
          "content/\(title.replacingOccurrences(of: " ", with: "-").lowercased()).md"),
        atomically: true,
        encoding: .utf8
      )

      let result = LocalContentImportService(isContentIndexEnabled: false).importDrafts(
        rootURL: rootURL, profile: profile)
      let draft = try XCTUnwrap(result.importedDrafts.first)
      XCTAssertEqual(draft.summary, "Imported summary", "\(style) \(summaryKey)")
      XCTAssertEqual(formattedDate(draft.date), "2026-08-29", "\(style) \(dateKey)")
    }
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
    let dependencyDirectory = rootURL.appendingPathComponent(
      "node_modules/example", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dependencyDirectory, withIntermediateDirectories: true)
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

  private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}

final class SiteArticleURLResolverTests: XCTestCase {
  func testZolaKeepsPostsSectionFromContentPath() {
    let resolver = SiteArticleURLResolver()
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)

    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/posts/2026/2026-10-15-daily-notes.md",
        profile: profile
      ),
      "/posts/2026/2026-10-15-daily-notes/"
    )
  }

  func testZolaKeepsCustomContentSectionAndBaseURLPath() throws {
    let resolver = SiteArticleURLResolver()
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)
    profile.contentRoot = "content/articles"

    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/articles/guides/getting-started.md",
        profile: profile
      ),
      "/articles/guides/getting-started/"
    )
    XCTAssertEqual(
      try XCTUnwrap(
        resolver.url(
          baseURL: URL(string: "https://example.com/blog/")!,
          markdownPath: "content/posts/2026/2026-10-15-daily-notes.md",
          profile: profile
        )
      ).absoluteString,
      "https://example.com/blog/posts/2026/2026-10-15-daily-notes"
    )
  }

  func testPermalinkStillOverridesZolaGeneratedPath() {
    let resolver = SiteArticleURLResolver()
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)

    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/posts/2026/2026-10-15-daily-notes.md",
        profile: profile,
        permalink: "/notes/daily/"
      ),
      "/notes/daily/"
    )
  }

  func testOtherEngineContentRootSemanticsRemainUnchanged() {
    let resolver = SiteArticleURLResolver()
    var next = SiteProfile.defaultProfile
    next.applyPublishingDefaults(for: .nextJS)

    XCTAssertEqual(
      resolver.relativeWebPath(
        from: "content/posts/releases/version-2.mdx",
        profile: next
      ),
      "/blog/releases/version-2/"
    )
  }
}

final class ZolaLeafBundleRecoveryTests: XCTestCase {
  func testAutomaticImportRejectsZolaLeafBundleIndex() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = zolaProfile()
    let source = "---\ntitle: \"Gallery\"\n---\nBody"

    XCTAssertThrowsError(
      try LocalContentImportService(isContentIndexEnabled: false).parseProjectDocument(
        source,
        repositoryPath: "content/gallery/index.md",
        rootURL: rootURL,
        profile: profile
      )
    )
  }

  func testExplicitRecoveryPreservesFrontMatterAndLeafPathAcrossEdits() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = zolaProfile()
    let source = """
      +++
      title = "Gallery"
      slug = "gallery-entry"
      [extra]
      gallery_layout = "masonry"
      +++

      Original body
      """

    var draft = try LocalContentImportService(isContentIndexEnabled: false)
      .parseProjectDocument(
        source,
        repositoryPath: "content/gallery/index.md",
        rootURL: rootURL,
        profile: profile,
        preserveZolaLeafBundlePath: true
      )
    XCTAssertTrue(draft.preservesZolaLeafBundlePath == true)
    XCTAssertTrue(try XCTUnwrap(draft.importedFrontMatter).rawBlock.contains("gallery_layout"))
    XCTAssertEqual(profile.markdownPath(for: draft), "content/gallery/index.md")

    draft.title = "Edited Gallery"
    draft.slug = "edited-gallery"
    draft.bodyMarkdown = "Edited body"

    XCTAssertEqual(profile.markdownPath(for: draft), "content/gallery/index.md")
    XCTAssertFalse(profile.markdownPath(for: draft).contains("posts/"))
  }

  func testRepositoryBindingNormalizationPreservesExplicitRecoveryMarker() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = "+++\ntitle = \"Gallery\"\n[extra]\ngallery_layout = \"masonry\"\n+++\n\nBody"

    var originalProfile = zolaProfile()
    originalProfile.branch = "main"
    var draft = try LocalContentImportService(isContentIndexEnabled: false)
      .parseProjectDocument(
        source,
        repositoryPath: "content/gallery/index.md",
        rootURL: rootURL,
        profile: originalProfile,
        preserveZolaLeafBundlePath: true
      )

    var changedIdentity = originalProfile
    changedIdentity.branch = "preview"
    draft.normalizeRepositoryBinding(for: changedIdentity)
    XCTAssertNil(draft.preservesZolaLeafBundlePath)

    draft.repositoryPath = "content/gallery-renamed/index.md"
    draft.preservesZolaLeafBundlePath = true
    draft.normalizeRepositoryBinding(for: changedIdentity)
    XCTAssertNil(draft.preservesZolaLeafBundlePath)

    draft.preservesZolaLeafBundlePath = true
    draft.detachFromRepository()
    draft.normalizeRepositoryBinding(for: changedIdentity)
    XCTAssertNil(draft.preservesZolaLeafBundlePath)
  }

  func testPreserveRepositoryStateCopiesExplicitRecoveryMarker() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = zolaProfile()
    let source = "+++\ntitle = \"Gallery\"\n+++\n\nBody"
    let current = try LocalContentImportService(isContentIndexEnabled: false)
      .parseProjectDocument(
        source,
        repositoryPath: "content/gallery/index.md",
        rootURL: rootURL,
        profile: profile,
        preserveZolaLeafBundlePath: true
      )
    var contentUpdate = ArticleDraft(
      siteProfileID: profile.id,
      title: "Edited",
      slug: "edited",
      bodyMarkdown: "Edited body"
    )

    contentUpdate.preserveRepositoryState(from: current)

    XCTAssertTrue(contentUpdate.preservesZolaLeafBundlePath == true)
  }

  func testLeafBundleFlagCodableRoundTripAndLegacyRecordsDefaultToNil() throws {
    let profile = zolaProfile()
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Gallery",
      slug: "gallery",
      repositoryPath: "content/gallery/index.md"
    )
    draft.preservesZolaLeafBundlePath = true

    let encoded = try JSONEncoder().encode(draft)
    let decoded = try JSONDecoder().decode(ArticleDraft.self, from: encoded)
    XCTAssertEqual(decoded.preservesZolaLeafBundlePath, true)

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "preservesZolaLeafBundlePath")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacy = try JSONDecoder().decode(ArticleDraft.self, from: legacyData)
    XCTAssertNil(legacy.preservesZolaLeafBundlePath)
  }

  func testExplicitRecoveryRejectsUnsafePathsAndOtherSiteKinds() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let zola = zolaProfile()
    let source = "---\ntitle: \"Entry\"\n---\nBody"
    let invalidPaths = [
      "content/gallery/_index.md",
      "content/gallery/../index.md",
      "content/index.md",
    ]

    for path in invalidPaths {
      XCTAssertThrowsError(
        try LocalContentImportService(isContentIndexEnabled: false).parseProjectDocument(
          source,
          repositoryPath: path,
          rootURL: rootURL,
          profile: zola,
          preserveZolaLeafBundlePath: true
        ),
        path
      )
    }

    var hugo = SiteProfile.defaultProfile
    hugo.applyPublishingDefaults(for: .hugo)
    XCTAssertThrowsError(
      try LocalContentImportService(isContentIndexEnabled: false).parseProjectDocument(
        source,
        repositoryPath: "content/gallery/index.md",
        rootURL: rootURL,
        profile: hugo,
        preserveZolaLeafBundlePath: true
      )
    )
  }

  func testChangingRepositoryBindingCannotActivatePreservedLeafPath() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = zolaProfile()
    let source = "---\ntitle: \"Gallery\"\n---\nBody"
    let draft = try LocalContentImportService(isContentIndexEnabled: false)
      .parseProjectDocument(
        source,
        repositoryPath: "content/gallery/index.md",
        rootURL: rootURL,
        profile: profile,
        preserveZolaLeafBundlePath: true
      )

    var movedProfile = profile
    movedProfile.repoOwner = "another-owner"
    XCTAssertNotEqual(movedProfile.markdownPath(for: draft), "content/gallery/index.md")
    XCTAssertTrue(movedProfile.markdownPath(for: draft).contains("posts/"))
  }

  private func zolaProfile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)
    return profile
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ZolaLeafBundleRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
