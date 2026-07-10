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

  func testStoreImportsOnlyChangedArticleDraftsFromRepositoryReport() throws {
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

    let summary = store.importChangedArticleDraftsFromLocalRepository()

    XCTAssertEqual(summary.insertedCount, 2)
    XCTAssertEqual(summary.updatedCount, 0)
    XCTAssertEqual(summary.skippedCount, 0)
    XCTAssertNotNil(store.drafts.first { $0.repositoryPath == "content/posts/changed.md" })
    XCTAssertNotNil(store.drafts.first { $0.repositoryPath == "content/posts/renamed.md" })
    XCTAssertNil(store.drafts.first { $0.repositoryPath == "content/posts/deleted.md" })
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.publishActionMessage, "已从文章变更导入 2 篇、更新 0 篇。")
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
