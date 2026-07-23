import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class LocalContentImportServiceTests: XCTestCase {
  func testImportsYAMLAndTOMLMarkdownFromContentRoot() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    ---
    title: "YAML Article"
    date: "2026-08-29"
    slug: yaml-article
    description: "Imported from YAML."
    tags: [Mac, 发布]
    categories:
      - Product
      - Notes
    draft: false
    ---

    # YAML Body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/yaml-article.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    +++
    title = "TOML Article"
    date = "2026-08-30"
    slug = "toml-article"
    tags = ["Zola", "Import"]
    draft = true
    +++

    # TOML Body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/toml-article.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)

    XCTAssertEqual(result.importedDrafts.count, 2)
    let yaml = try XCTUnwrap(result.importedDrafts.first { $0.slug == "yaml-article" })
    XCTAssertEqual(yaml.title, "YAML Article")
    XCTAssertEqual(yaml.summary, "Imported from YAML.")
    XCTAssertEqual(yaml.tags, ["Mac", "发布"])
    XCTAssertEqual(yaml.categories, ["Product", "Notes"])
    XCTAssertEqual(yaml.draft, false)
    XCTAssertEqual(yaml.status, .published)
    XCTAssertEqual(yaml.repositoryPath, "content/posts/yaml-article.md")
    XCTAssertEqual(yaml.bodyMarkdown, "# YAML Body")

    let toml = try XCTUnwrap(result.importedDrafts.first { $0.slug == "toml-article" })
    XCTAssertEqual(toml.title, "TOML Article")
    XCTAssertEqual(toml.tags, ["Zola", "Import"])
    XCTAssertEqual(toml.draft, true)
    XCTAssertEqual(toml.status, .draft)
  }

  func testImportsPrivateDirectoryAndFrontMatterVisibility() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("private/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    +++
    title = "Public Article"
    +++

    Public body.
    """.write(
      to: rootURL.appendingPathComponent("content/posts/public.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    +++
    title = "Flagged Private"
    private = true
    +++

    Flagged body.
    """.write(
      to: rootURL.appendingPathComponent("content/posts/flagged.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    +++
    title = "Private Directory Article"
    draft = false
    +++

    Secret body.
    """.write(
      to: rootURL.appendingPathComponent("private/posts/secret.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)

    XCTAssertEqual(result.importedDrafts.count, 3)
    XCTAssertEqual(result.importedDrafts.filter(\.isPrivate).count, 2)
    XCTAssertEqual(result.importedDrafts.first { $0.repositoryPath == "content/posts/public.md" }?.visibility, .public)
    XCTAssertEqual(result.importedDrafts.first { $0.repositoryPath == "content/posts/flagged.md" }?.visibility, .private)
    let privateDraft = try XCTUnwrap(result.importedDrafts.first { $0.repositoryPath == "private/posts/secret.md" })
    XCTAssertEqual(privateDraft.visibility, .private)
    XCTAssertEqual(privateDraft.status, .published)
  }

  func testImportsJekyllDateAndSlugFromRepositoryPath() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("_posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    ---
    title: "Jekyll Imported"
    ---

    Body
    """.write(
      to: rootURL.appendingPathComponent("_posts/2026-08-29-jekyll-imported.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .jekyll)
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)

    XCTAssertEqual(draft.slug, "jekyll-imported")
    XCTAssertEqual(draft.repositoryPath, "_posts/2026-08-29-jekyll-imported.md")
    XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: draft.date), 2026)
  }

  func testImportsCoverAndMarkdownImagesAsAttachments() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images/2026", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0, 1, 2]).write(to: rootURL.appendingPathComponent("static/images/2026/cover.jpg"))
    try Data([3, 4, 5, 6]).write(to: rootURL.appendingPathComponent("static/images/2026/inline.png"))
    try """
    +++
    title = "Image Import"
    slug = "image-import"
    [extra]
    og_preview_img = "/images/2026/cover.jpg"
    +++

    # Image Import

    ![Inline alt](/images/2026/inline.png)
    """.write(
      to: rootURL.appendingPathComponent("content/posts/image-import.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)
    let coverID = try XCTUnwrap(draft.coverAttachmentID)
    let cover = try XCTUnwrap(draft.attachments.first { $0.id == coverID })
    let inline = try XCTUnwrap(draft.attachments.first { $0.relativePublishPath == "/images/2026/inline.png" })

    XCTAssertEqual(draft.attachments.count, 2)
    XCTAssertEqual(cover.relativePublishPath, "/images/2026/cover.jpg")
    XCTAssertEqual(cover.repositoryPath, "static/images/2026/cover.jpg")
    XCTAssertEqual(cover.byteSize, 3)
    XCTAssertNotNil(cover.sourceFilePath)
    XCTAssertEqual(inline.altText, "Inline alt")
    XCTAssertEqual(inline.repositoryPath, "static/images/2026/inline.png")
    XCTAssertEqual(inline.byteSize, 4)
  }

  func testImportsJekyllImageFieldWithoutDuplicatingAssetRoot() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("_posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("assets/images/2026", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([7, 8]).write(to: rootURL.appendingPathComponent("assets/images/2026/cover.jpg"))
    try """
    ---
    title: "Jekyll Image"
    image: "/assets/images/2026/cover.jpg"
    ---

    Body
    """.write(
      to: rootURL.appendingPathComponent("_posts/2026-08-30-jekyll-image.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .jekyll)
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)
    let coverID = try XCTUnwrap(draft.coverAttachmentID)
    let cover = try XCTUnwrap(draft.attachments.first { $0.id == coverID })

    XCTAssertEqual(cover.relativePublishPath, "/assets/images/2026/cover.jpg")
    XCTAssertEqual(cover.repositoryPath, "assets/images/2026/cover.jpg")
    XCTAssertEqual(cover.byteSize, 2)
    XCTAssertNotNil(cover.sourceFilePath)
  }

  func testRejectsMarkdownImageParentTraversalOutsideRepository() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    let outsideURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("outside-image-\(UUID().uuidString).png")
    try Data([9, 8, 7]).write(to: outsideURL)
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    let document = """
    +++
    title = "Traversal"
    +++

    ![private](../../../\(outsideURL.lastPathComponent))
    """
    try document.write(
      to: rootURL.appendingPathComponent("content/posts/traversal.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)

    XCTAssertTrue(draft.attachments.isEmpty)
  }

  func testRejectsImageSymlinkThatEscapesRepository() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    let outsideURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("symlink-target-\(UUID().uuidString).png")
    try Data([1, 3, 3, 7]).write(to: outsideURL)
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("static/images/leak.png"),
      withDestinationURL: outsideURL
    )
    try """
    +++
    title = "Symlink Escape"
    +++

    ![private](/images/leak.png)
    """.write(
      to: rootURL.appendingPathComponent("content/posts/symlink.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    profile.assetRoot = "static"
    let result = LocalContentImportService().importDrafts(rootURL: rootURL, profile: profile)
    let draft = try XCTUnwrap(result.importedDrafts.first)

    XCTAssertTrue(draft.attachments.isEmpty)
  }

  func testRejectsMarkdownSymlinkThatEscapesRepository() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    let outsideURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("markdown-symlink-target-\(UUID().uuidString).md")
    try """
    +++
    title = "Private Outside Article"
    +++

    Sensitive content
    """.write(to: outsideURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    let symlinkURL = postsURL.appendingPathComponent("leak.md")
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    let service = LocalContentImportService()

    let batchResult = service.importDrafts(rootURL: rootURL, profile: profile)
    let pathResult = service.importDrafts(
      rootURL: rootURL,
      repositoryPaths: ["content/posts/leak.md"],
      profile: profile
    )

    XCTAssertTrue(batchResult.importedDrafts.isEmpty)
    XCTAssertEqual(batchResult.skippedPaths, ["content/posts/leak.md"])
    XCTAssertTrue(pathResult.importedDrafts.isEmpty)
    XCTAssertEqual(pathResult.skippedPaths, ["content/posts/leak.md"])
  }

  func testImportsSingleDraftFromRepositoryPath() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    ---
    title: "Single Import"
    slug: single-import
    ---

    Single body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/single-import.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: "Other Import"
    ---

    Other body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/other-import.md"),
      atomically: true,
      encoding: .utf8
    )
    try "Not an article".write(
      to: rootURL.appendingPathComponent("static/not-an-article.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    let service = LocalContentImportService()

    let result = service.importDraft(rootURL: rootURL, repositoryPath: "content/posts/single-import.md", profile: profile)
    XCTAssertEqual(result.importedDrafts.count, 1)
    XCTAssertEqual(result.skippedPaths, [])
    XCTAssertEqual(result.importedDrafts.first?.title, "Single Import")
    XCTAssertEqual(result.importedDrafts.first?.repositoryPath, "content/posts/single-import.md")

    let rejected = service.importDraft(rootURL: rootURL, repositoryPath: "static/not-an-article.md", profile: profile)
    XCTAssertEqual(rejected.importedDrafts.count, 0)
    XCTAssertEqual(rejected.skippedPaths, ["static/not-an-article.md"])
  }

  func testStoreImportMergesByRepositoryPath() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    let articleURL = rootURL.appendingPathComponent("content/posts/imported.md")
    try """
    ---
    title: "Imported One"
    slug: imported
    ---

    First body
    """.write(to: articleURL, atomically: true, encoding: .utf8)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)

    let firstSummary = store.importDraftsFromLocalRepository()
    XCTAssertEqual(firstSummary.insertedCount, 1)
    XCTAssertEqual(firstSummary.updatedCount, 0)
    let importedID = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "content/posts/imported.md" }?.id)

    try """
    ---
    title: "Imported One Updated"
    slug: imported
    ---

    Updated body
    """.write(to: articleURL, atomically: true, encoding: .utf8)

    let secondSummary = store.importDraftsFromLocalRepository()
    XCTAssertEqual(secondSummary.insertedCount, 0)
    XCTAssertEqual(secondSummary.updatedCount, 1)
    let updatedDraft = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "content/posts/imported.md" })
    XCTAssertEqual(updatedDraft.id, importedID)
    XCTAssertEqual(updatedDraft.title, "Imported One Updated")
    XCTAssertEqual(updatedDraft.bodyMarkdown, "Updated body")
  }

  func testMissingDraftDiscoveryAddsExternalPublicArticleWithoutOverwritingExistingDraft() async throws {
    let rootURL = try temporaryDirectory()
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try """
    ---
    title: "Repository Existing"
    slug: existing
    ---

    Repository body.
    """.write(
      to: postsURL.appendingPathComponent("existing.md"),
      atomically: true,
      encoding: .utf8
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)
    let locallyEdited = ArticleDraft(
      siteProfileID: profile.id,
      title: "Keep Local Edit",
      bodyMarkdown: "Locally edited body.",
      repositoryPath: "content/posts/existing.md"
    )
    store.setDrafts([locallyEdited])

    let initialInsertedCount = await store.importMissingDraftsFromLocalRepository()
    store.setDraftListContentScope(.general)

    try """
    ---
    title: "Written Elsewhere"
    slug: written-elsewhere
    ---

    This article was created in another editor.
    """.write(
      to: postsURL.appendingPathComponent("written-elsewhere.md"),
      atomically: true,
      encoding: .utf8
    )

    let insertedCount = await store.importMissingDraftsFromLocalRepository()
    let repeatedInsertedCount = await store.importMissingDraftsFromLocalRepository()

    XCTAssertEqual(initialInsertedCount, 0)
    XCTAssertEqual(insertedCount, 1)
    XCTAssertEqual(repeatedInsertedCount, 0)
    XCTAssertEqual(store.drafts.count, 2)
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "content/posts/existing.md" }?.title, "Keep Local Edit")
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "content/posts/existing.md" }?.bodyMarkdown, "Locally edited body.")
    let externallyCreatedDraft = try XCTUnwrap(
      store.drafts.first { $0.repositoryPath == "content/posts/written-elsewhere.md" }
    )
    XCTAssertEqual(externallyCreatedDraft.title, "Written Elsewhere")
    XCTAssertEqual(store.draftListContentScope, .currentSite)
    XCTAssertEqual(store.selectedDraftID, externallyCreatedDraft.id)
    XCTAssertTrue(store.writingDrafts.contains { $0.id == externallyCreatedDraft.id })
    XCTAssertEqual(store.publishActionMessage, "已发现并加入本地列表 1 篇外部新文章。")
  }

  func testRepositoryScanImportsExternallyCreatedArticleIntoWritingList() async throws {
    let rootURL = try temporaryDirectory()
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try """
    ---
    title: "Found During Scan"
    slug: found-during-scan
    ---

    Created outside the workbench.
    """.write(
      to: postsURL.appendingPathComponent("found-during-scan.md"),
      atomically: true,
      encoding: .utf8
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)
    store.setDraftListContentScope(.general)

    await store.scanRepositoryAsync()

    let importedDraft = try XCTUnwrap(
      store.writingDrafts.first { $0.repositoryPath == "content/posts/found-during-scan.md" }
    )
    XCTAssertEqual(importedDraft.title, "Found During Scan")
    XCTAssertEqual(store.draftListContentScope, .currentSite)
    XCTAssertEqual(store.selectedDraftID, importedDraft.id)
  }

  func testMissingPrivateBackfillAddsOnlyNewPrivateDraftsWithoutOverwriting() async throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("private/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "Public body".write(
      to: rootURL.appendingPathComponent("content/posts/public.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    +++
    title = "Repository Existing"
    +++

    Repository body.
    """.write(
      to: rootURL.appendingPathComponent("private/posts/existing.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    +++
    title = "New Private"
    +++

    New private body.
    """.write(
      to: rootURL.appendingPathComponent("private/posts/new-private.md"),
      atomically: true,
      encoding: .utf8
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)
    let locallyEdited = ArticleDraft(
      siteProfileID: profile.id,
      title: "Keep Local Edit",
      visibility: .private,
      bodyMarkdown: "Locally edited body.",
      repositoryPath: "private/posts/existing.md"
    )
    store.setDrafts([locallyEdited])

    let firstInsertedCount = await store.importMissingPrivateDraftsFromLocalRepository()
    let secondInsertedCount = await store.importMissingPrivateDraftsFromLocalRepository()

    XCTAssertEqual(firstInsertedCount, 1)
    XCTAssertEqual(secondInsertedCount, 0)
    XCTAssertEqual(store.drafts.count, 2)
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "private/posts/existing.md" }?.title, "Keep Local Edit")
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "private/posts/existing.md" }?.bodyMarkdown, "Locally edited body.")
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "private/posts/new-private.md" }?.visibility, .private)
    XCTAssertNil(store.drafts.first { $0.repositoryPath == "content/posts/public.md" })
  }

  func testStoreImportsSingleDraftAndMergesByRepositoryPath() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    let articleURL = rootURL.appendingPathComponent("content/posts/single.md")
    try """
    ---
    title: "Single Store Import"
    slug: single
    ---

    First body
    """.write(to: articleURL, atomically: true, encoding: .utf8)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)

    let firstSummary = store.importDraftFromLocalRepository(repositoryPath: "content/posts/single.md")
    XCTAssertEqual(firstSummary.insertedCount, 1)
    XCTAssertEqual(firstSummary.updatedCount, 0)
    XCTAssertEqual(store.selectedSection, .writing)
    let importedID = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "content/posts/single.md" }?.id)
    XCTAssertEqual(store.selectedDraftID, importedID)

    try """
    ---
    title: "Single Store Import Updated"
    slug: single
    ---

    Updated body
    """.write(to: articleURL, atomically: true, encoding: .utf8)

    let secondSummary = store.importDraftFromLocalRepository(repositoryPath: "content/posts/single.md")
    XCTAssertEqual(secondSummary.insertedCount, 0)
    XCTAssertEqual(secondSummary.updatedCount, 1)
    let updatedDraft = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "content/posts/single.md" })
    XCTAssertEqual(updatedDraft.id, importedID)
    XCTAssertEqual(updatedDraft.title, "Single Store Import Updated")
    XCTAssertEqual(updatedDraft.bodyMarkdown, "Updated body")
  }

  func testStoreImportsOnlyChangedArticleDraftsFromRepositoryReport() async throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    ---
    title: "Changed Article"
    slug: changed-article
    ---

    Changed body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/changed.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: "Renamed Article"
    slug: renamed-article
    ---

    Renamed body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/renamed.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([1, 2, 3]).write(to: rootURL.appendingPathComponent("static/images/cover.png"))

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"
    store.updateActiveProfile(profile)
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: .zola,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 2,
      imageFileCount: 1,
      changedFiles: [
        RepositoryChangedFile(status: " M", path: "content/posts/changed.md", kind: .modified),
        RepositoryChangedFile(status: "R ", path: "content/posts/old.md -> content/posts/renamed.md", kind: .renamed),
        RepositoryChangedFile(status: " D", path: "content/posts/deleted.md", kind: .deleted),
        RepositoryChangedFile(status: " M", path: "static/images/cover.png", kind: .modified),
        RepositoryChangedFile(status: " M", path: "config.toml", kind: .modified),
      ],
      preflightIssues: []
    ))

    let summary = await store.importChangedArticleDraftsFromLocalRepository()

    XCTAssertEqual(summary.insertedCount, 2)
    XCTAssertEqual(summary.updatedCount, 0)
    XCTAssertEqual(summary.skippedCount, 0)
    XCTAssertNotNil(store.drafts.first { $0.repositoryPath == "content/posts/changed.md" })
    XCTAssertNotNil(store.drafts.first { $0.repositoryPath == "content/posts/renamed.md" })
    XCTAssertNil(store.drafts.first { $0.repositoryPath == "content/posts/deleted.md" })
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.publishActionMessage, "已从文章变更导入 2 篇、更新 0 篇。")
  }

  func testAsyncImportPropagatesCancellation() async throws {
    let rootURL = try temporaryDirectory()
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    for index in 0..<128 {
      try """
      ---
      title: "Article \(index)"
      slug: article-\(index)
      ---

      \(String(repeating: "Imported content. ", count: 64))
      """.write(
        to: postsURL.appendingPathComponent("article-\(index).md"),
        atomically: true,
        encoding: .utf8
      )
    }
    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    let task = Task {
      try await LocalContentImportService().importDraftsAsync(profile: profile)
    }

    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected local content import cancellation to propagate")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testChangedArticleBatchInvalidatesDerivedStateOnlyOnce() async throws {
    let rootURL = try temporaryDirectory()
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try """
    ---
    title: "First Updated"
    slug: first
    ---

    First updated body
    """.write(to: postsURL.appendingPathComponent("first.md"), atomically: true, encoding: .utf8)
    try """
    ---
    title: "Second Updated"
    slug: second
    ---

    Second updated body
    """.write(to: postsURL.appendingPathComponent("second.md"), atomically: true, encoding: .utf8)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.setAutomaticallyRefreshPreflightOnEdit(false)
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)
    store.setDrafts([
      ArticleDraft(
        siteProfileID: profile.id,
        title: "First Original",
        slug: "first",
        bodyMarkdown: "First original body",
        repositoryPath: "content/posts/first.md"
      ),
      ArticleDraft(
        siteProfileID: profile.id,
        title: "Second Original",
        slug: "second",
        bodyMarkdown: "Second original body",
        repositoryPath: "content/posts/second.md"
      ),
    ])
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: .zola,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 2,
      imageFileCount: 0,
      changedFiles: [
        RepositoryChangedFile(status: " M", path: "content/posts/first.md", kind: .modified),
        RepositoryChangedFile(status: " M", path: "content/posts/second.md", kind: .modified),
      ],
      preflightIssues: []
    ))
    let versionBeforeImport = store.contentHealthSnapshotVersion

    let summary = await store.importChangedArticleDraftsFromLocalRepository()

    XCTAssertEqual(summary.insertedCount, 0)
    XCTAssertEqual(summary.updatedCount, 2)
    XCTAssertEqual(store.contentHealthSnapshotVersion, versionBeforeImport + 1)
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "content/posts/first.md" }?.title, "First Updated")
    XCTAssertEqual(store.drafts.first { $0.repositoryPath == "content/posts/second.md" }?.title, "Second Updated")
  }

  func testStoreImportRequiresLocalRepositoryRoot() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))

    let summary = store.importDraftsFromLocalRepository()

    XCTAssertEqual(summary.changedCount, 0)
    XCTAssertEqual(store.publishActionMessage, "选择本地仓库后才能导入文章。")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacImportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func temporaryPersistenceURL() throws -> URL {
    try temporaryDirectory().appendingPathComponent("workbench.json")
  }
}
