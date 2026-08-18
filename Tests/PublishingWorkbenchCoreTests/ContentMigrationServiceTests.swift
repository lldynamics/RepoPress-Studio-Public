import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ContentMigrationServiceTests: XCTestCase {
  private let service = ContentMigrationService()
  private var profile: SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    return profile
  }

  func testConvertsWordPressWXRFrontMatterImagesAndRedirects() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/"><channel>
      <wp:wxr_version>1.2</wp:wxr_version>
      <item>
        <title>迁移文章</title><link>https://old.example.com/old-post/</link>
        <wp:post_type>post</wp:post_type><wp:post_name>new-post</wp:post_name><wp:post_date>2026-07-01 10:20:00</wp:post_date><wp:status>publish</wp:status>
        <content:encoded><![CDATA[<p>正文</p><img src="https://cdn.example.com/media/photo.jpg">]]></content:encoded>
        <category domain="post_tag"><![CDATA[Swift]]></category><category><![CDATA[开发]]></category>
      </item>
      <item><title>附件</title><wp:post_type>attachment</wp:post_type></item>
    </channel></rss>
    """

    let plan = try makePlan(contents: xml, extension: "xml")

    XCTAssertEqual(plan.sourceKind, .wordpressWXR)
    XCTAssertEqual(plan.drafts.count, 1)
    let draft = try XCTUnwrap(plan.drafts.first)
    XCTAssertEqual(draft.title, "迁移文章")
    XCTAssertEqual(draft.slug, "new-post")
    XCTAssertEqual(draft.repositoryPath, "content/posts/new-post.md")
    XCTAssertEqual(draft.tags, ["Swift"])
    XCTAssertEqual(draft.categories, ["开发"])
    XCTAssertTrue(draft.bodyMarkdown.contains("![](/assets/imported/cdn.example.com/media/photo.jpg)"))
    XCTAssertEqual(plan.redirects, [ContentMigrationRedirect(sourcePath: "/old-post/", targetPath: "/new-post/")])
  }

  func testConvertsRSSItem() throws {
    let xml = """
    <rss version="2.0"><channel><item>
      <title>RSS 文章</title><link>https://old.example.com/rss-entry</link>
      <pubDate>Wed, 01 Jul 2026 10:20:00 +0000</pubDate><description>摘要</description>
    </item></channel></rss>
    """

    let plan = try makePlan(contents: xml, extension: "rss")

    XCTAssertEqual(plan.sourceKind, .rss)
    XCTAssertEqual(plan.drafts.count, 1)
    XCTAssertEqual(plan.drafts[0].title, "RSS 文章")
    XCTAssertEqual(plan.drafts[0].summary, "摘要")
    XCTAssertEqual(plan.redirects.first?.sourcePath, "/rss-entry/")
  }

  func testConvertsAtomHrefLink() throws {
    let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><entry>
      <title>Atom 文章</title><link href="https://old.example.com/atom-entry" />
      <published>2026-07-01T10:20:00Z</published><content>正文</content>
    </entry></feed>
    """

    let plan = try makePlan(contents: atom, extension: "atom")

    XCTAssertEqual(plan.sourceKind, .rss)
    XCTAssertEqual(plan.redirects.first?.sourcePath, "/atom-entry/")
  }

  func testConvertsMarkdownFolderAndRewritesRelativeImages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let markdown = """
    ---
    title: Markdown 文章
    slug: markdown-post
    tags: [Swift, macOS]
    categories: [开发]
    draft: true
    permalink: /old-markdown/
    ---
    ![封面](images/cover.png)
    """
    try markdown.write(to: directory.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)

    let plan = try service.makePlan(sourceURL: directory, profile: profile)

    XCTAssertEqual(plan.sourceKind, .markdownFolder)
    XCTAssertEqual(plan.drafts.count, 1)
    XCTAssertEqual(plan.drafts[0].tags, ["Swift", "macOS"])
    XCTAssertTrue(plan.drafts[0].draft)
    XCTAssertTrue(plan.drafts[0].bodyMarkdown.contains("![封面](/assets/imported/images/cover.png)"))
    XCTAssertEqual(plan.redirects.first?.targetPath, "/markdown-post/")
  }

  func testRejectsMarkdownSymlinkOutsideSelectedFolder() throws {
    let selectedDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ContentMigrationSelected-\(UUID().uuidString)", isDirectory: true)
    let outsideDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ContentMigrationOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: selectedDirectory)
      try? FileManager.default.removeItem(at: outsideDirectory)
    }

    let outsideFile = outsideDirectory.appendingPathComponent("secret.md")
    try "---\ntitle: Outside\n---\nsecret".write(
      to: outsideFile,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: selectedDirectory.appendingPathComponent("linked.md"),
      withDestinationURL: outsideFile
    )

    XCTAssertThrowsError(try service.makePlan(sourceURL: selectedDirectory, profile: profile)) { error in
      guard case ContentMigrationError.sourceOutsideSelectedDirectory = error else {
        XCTFail("Expected sourceOutsideSelectedDirectory, got \(error)")
        return
      }
    }
  }

  @MainActor
  func testApplyRejectsPlanAfterMarkdownPathConfigurationChanges() async throws {
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-\(UUID().uuidString).md")
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-persistence-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: sourceURL)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    try "---\ntitle: Planned Article\nslug: planned\n---\nBody".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    var configuredProfile = store.activeProfile
    configuredProfile.markdownPathPattern = "content/old/{slug}.md"
    store.updateActiveProfile(configuredProfile)
    let plan = try await store.makeContentMigrationPlan(sourceURL: sourceURL)
    XCTAssertEqual(plan.drafts.first?.repositoryPath, "content/old/planned.md")

    configuredProfile = store.activeProfile
    configuredProfile.markdownPathPattern = "content/new/{slug}.md"
    store.updateActiveProfile(configuredProfile)

    XCTAssertThrowsError(try store.applyContentMigration(plan)) { error in
      guard case ContentMigrationError.profileChanged = error else {
        XCTFail("Expected profileChanged, got \(error)")
        return
      }
    }
    XCTAssertFalse(store.visibleDrafts.contains { $0.title == "Planned Article" })
  }

  @MainActor
  func testPlanClassifiesDraftsAndAppliesOnlySelectedArticles() async throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "ContentMigrationReview")
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let suffix = UUID().uuidString.lowercased()
    let updateSlug = "update-\(suffix)"
    let unchangedSlug = "same-\(suffix)"
    let insertSlug = "insert-\(suffix)"
    try "---\ntitle: Update Article\nslug: \(updateSlug)\ndraft: true\n---\nImported body".write(
      to: sourceDirectory.appendingPathComponent("update.md"),
      atomically: true,
      encoding: .utf8
    )
    try "---\ntitle: Same Article\nslug: \(unchangedSlug)\ndraft: true\n---\nSame body".write(
      to: sourceDirectory.appendingPathComponent("same.md"),
      atomically: true,
      encoding: .utf8
    )
    try "---\ntitle: Insert Article\nslug: \(insertSlug)\ndraft: true\n---\nNew body".write(
      to: sourceDirectory.appendingPathComponent("insert.md"),
      atomically: true,
      encoding: .utf8
    )

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    )
    var configuredProfile = store.activeProfile
    configuredProfile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(configuredProfile)
    let sourcePlan = try service.makePlan(sourceURL: sourceDirectory, profile: store.activeProfile)

    var existingUpdate = try XCTUnwrap(sourcePlan.drafts.first { $0.slug == updateSlug })
    existingUpdate.id = UUID()
    existingUpdate.bodyMarkdown = "Local body before migration"
    store.updateDraft(existingUpdate)
    var existingUnchanged = try XCTUnwrap(sourcePlan.drafts.first { $0.slug == unchangedSlug })
    existingUnchanged.id = UUID()
    store.updateDraft(existingUnchanged)

    let plan = try await store.makeContentMigrationPlan(sourceURL: sourceDirectory)
    let dispositions = Dictionary(uniqueKeysWithValues: plan.reviewItems.map {
      ($0.importedDraft.slug, $0.disposition)
    })
    XCTAssertEqual(dispositions[updateSlug], .update)
    XCTAssertEqual(dispositions[unchangedSlug], .unchanged)
    XCTAssertEqual(dispositions[insertSlug], .insert)
    let insertItem = try XCTUnwrap(plan.reviewItems.first { $0.importedDraft.slug == insertSlug })

    let summary = try store.applyContentMigration(plan, selectedDraftIDs: [insertItem.id])

    XCTAssertEqual(summary.insertedCount, 1)
    XCTAssertEqual(summary.updatedCount, 0)
    XCTAssertEqual(summary.skippedCount, 2)
    XCTAssertEqual(store.drafts.first { $0.slug == updateSlug }?.bodyMarkdown, "Local body before migration")
    XCTAssertEqual(store.drafts.first { $0.slug == insertSlug }?.bodyMarkdown, "New body")
  }

  @MainActor
  func testApplyRejectsSelectedDraftChangedAfterPreview() async throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "ContentMigrationConflict")
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("article.md")
    let slug = "conflict-\(UUID().uuidString.lowercased())"
    try "---\ntitle: Conflict Article\nslug: \(slug)\ndraft: true\n---\nImported body".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    )
    var configuredProfile = store.activeProfile
    configuredProfile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(configuredProfile)
    let sourcePlan = try service.makePlan(sourceURL: sourceURL, profile: store.activeProfile)
    var existingDraft = try XCTUnwrap(sourcePlan.drafts.first)
    existingDraft.id = UUID()
    existingDraft.bodyMarkdown = "Original local body"
    store.updateDraft(existingDraft)

    let plan = try await store.makeContentMigrationPlan(sourceURL: sourceURL)
    let updateItem = try XCTUnwrap(plan.reviewItems.first)
    XCTAssertEqual(updateItem.disposition, .update)

    var locallyEdited = try XCTUnwrap(store.drafts.first { $0.id == existingDraft.id })
    locallyEdited.bodyMarkdown = "Edited locally after preview"
    store.updateDraft(locallyEdited)

    XCTAssertThrowsError(
      try store.applyContentMigration(plan, selectedDraftIDs: [updateItem.id])
    ) { error in
      guard case let ContentMigrationError.draftsChanged(paths) = error else {
        XCTFail("Expected draftsChanged, got \(error)")
        return
      }
      XCTAssertEqual(paths, ["content/posts/\(slug).md"])
    }
    XCTAssertEqual(store.drafts.first { $0.id == existingDraft.id }?.bodyMarkdown, "Edited locally after preview")
  }

  func testConvertsTOMLFrontMatterFromMarkdownFolder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let markdown = """
    +++
    title = "TOML 文章"
    slug = "toml-post"
    draft = true
    permalink = "/old-toml/"
    +++
    TOML 正文
    """
    try markdown.write(to: directory.appendingPathComponent("toml.md"), atomically: true, encoding: .utf8)

    let plan = try service.makePlan(sourceURL: directory, profile: profile)

    XCTAssertEqual(plan.drafts.count, 1)
    XCTAssertEqual(plan.drafts[0].title, "TOML 文章")
    XCTAssertEqual(plan.drafts[0].slug, "toml-post")
    XCTAssertTrue(plan.drafts[0].draft)
    XCTAssertEqual(plan.drafts[0].bodyMarkdown, "TOML 正文")
    XCTAssertEqual(plan.redirects.first?.sourcePath, "/old-toml/")
  }

  func testConvertsGenericJSONAndEnsuresUniqueSlugs() throws {
    let json = """
    {"posts":[
      {"title":"第一篇","slug":"same","url":"https://old.example.com/a","content":"正文"},
      {"title":"第二篇","slug":"same","url":"https://old.example.com/b","content":"正文"}
    ]}
    """

    let plan = try makePlan(contents: json, extension: "json")

    XCTAssertEqual(plan.sourceKind, .genericJSON)
    XCTAssertEqual(Set(plan.drafts.map(\.slug)), Set(["same", "same-2"]))
    XCTAssertEqual(plan.redirects.map(\.sourcePath), ["/a/", "/b/"])
  }

  func testBuildsMigrationPlanAsynchronously() async throws {
    let markdown = """
    ---
    title: Async Migration
    slug: async-migration
    ---
    Async body
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: url) }
    try markdown.write(to: url, atomically: true, encoding: .utf8)

    let plan = try await service.makePlanAsync(sourceURL: url, profile: profile)

    XCTAssertEqual(plan.drafts.first?.title, "Async Migration")
    XCTAssertEqual(plan.drafts.first?.bodyMarkdown, "Async body")
  }

  func testAsyncMigrationPropagatesCancellation() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let items = (0..<1_000).map { index in
      ["title": "Article \(index)", "content": String(repeating: "Body ", count: 64)]
    }
    try JSONSerialization.data(withJSONObject: ["posts": items]).write(to: url)
    let migrationService = service
    let migrationProfile = profile
    let task = Task {
      try await migrationService.makePlanAsync(sourceURL: url, profile: migrationProfile)
    }

    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected migration cancellation to propagate")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testRejectsJSONAndXMLRecordsBeyondConfiguredLimit() throws {
    let limitedService = ContentMigrationService(limits: ContentMigrationLimits(
      maximumSourceFileBytes: 10_000,
      maximumRecordCount: 1,
      maximumMarkdownFileCount: 10,
      maximumMarkdownFileBytes: 1_000,
      maximumMarkdownFolderBytes: 2_000
    ))
    let jsonURL = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).json")
    let xmlURL = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).xml")
    defer {
      try? FileManager.default.removeItem(at: jsonURL)
      try? FileManager.default.removeItem(at: xmlURL)
    }
    try #"{"posts":[{"title":"One"},{"title":"Two"}]}"#
      .write(to: jsonURL, atomically: true, encoding: .utf8)
    try """
    <rss><channel>
      <item><title>One</title></item>
      <item><title>Two</title></item>
    </channel></rss>
    """.write(to: xmlURL, atomically: true, encoding: .utf8)

    for sourceURL in [jsonURL, xmlURL] {
      XCTAssertThrowsError(try limitedService.makePlan(sourceURL: sourceURL, profile: profile)) { error in
        guard case ContentMigrationError.sourceLimitExceeded = error else {
          XCTFail("Expected sourceLimitExceeded, got \(error)")
          return
        }
      }
    }
  }

  func testRejectsOversizedMarkdownFileAndFolderTotal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = "---\ntitle: Article\n---\n" + String(repeating: "x", count: 80)
    try document.write(to: directory.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
    try document.write(to: directory.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)

    let oversizedFileService = ContentMigrationService(limits: ContentMigrationLimits(
      maximumSourceFileBytes: 10_000,
      maximumRecordCount: 10,
      maximumMarkdownFileCount: 10,
      maximumMarkdownFileBytes: 64,
      maximumMarkdownFolderBytes: 10_000
    ))
    XCTAssertThrowsError(try oversizedFileService.makePlan(sourceURL: directory, profile: profile)) { error in
      guard case ContentMigrationError.sourceLimitExceeded = error else {
        XCTFail("Expected per-file sourceLimitExceeded, got \(error)")
        return
      }
    }

    let oversizedFolderService = ContentMigrationService(limits: ContentMigrationLimits(
      maximumSourceFileBytes: 10_000,
      maximumRecordCount: 10,
      maximumMarkdownFileCount: 10,
      maximumMarkdownFileBytes: 1_000,
      maximumMarkdownFolderBytes: document.utf8.count + 10
    ))
    XCTAssertThrowsError(try oversizedFolderService.makePlan(sourceURL: directory, profile: profile)) { error in
      guard case ContentMigrationError.sourceLimitExceeded = error else {
        XCTFail("Expected folder-total sourceLimitExceeded, got \(error)")
        return
      }
    }
  }

  private func makePlan(contents: String, extension fileExtension: String) throws -> ContentMigrationPlan {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).\(fileExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return try service.makePlan(sourceURL: url, profile: profile)
  }
}
