import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class ZolaFrontMatterPreservationTests: XCTestCase {
  func testInlineTOMLTaxonomiesImportAndPatchOnlyEditedArray() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/inline-taxonomies.md"
    let rawBlock = """
      +++
      title = "Inline taxonomies"
      date = "2026-10-13"
      slug = "inline-taxonomies"
      taxonomies = { tags = ["essay, long", "fedora"], categories = ["Linux"], series = ["keep"] } # keep taxonomy note
      [extra]
      tags = ["decoy"]
      custom = "keep"
      +++
      """
    let document = rawBlock + "\n\nOriginal body\n"
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try document.write(to: destinationURL, atomically: true, encoding: .utf8)
    var draft = try importDraft(
      document: document,
      repositoryPath: repositoryPath,
      rootURL: rootURL,
      profile: profile
    )

    XCTAssertEqual(draft.tags, ["essay, long", "fedora"])
    XCTAssertEqual(draft.categories, ["Linux"])
    XCTAssertEqual(draft.importedFrontMatter?.rawBlock, rawBlock)

    draft.bodyMarkdown = "Edited body only"
    let renderer = FrontMatterRenderer()
    XCTAssertEqual(renderer.render(draft: draft, profile: profile), rawBlock)
    XCTAssertEqual(
      renderer.renderDocument(draft: draft, profile: profile),
      rawBlock + "\n\nEdited body only\n"
    )
    _ = try SiteDraftFileStore().write(draft: draft, profile: profile)
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      rawBlock + "\n\nEdited body only\n"
    )

    draft.tags = ["fedora"]
    let expected = rawBlock.replacingOccurrences(
      of: "tags = [\"essay, long\", \"fedora\"]",
      with: "tags = [\"fedora\"]"
    )
    XCTAssertEqual(renderer.render(draft: draft, profile: profile), expected)
    XCTAssertTrue(expected.contains("series = [\"keep\"]"))
    XCTAssertTrue(expected.contains("# keep taxonomy note"))
    XCTAssertTrue(expected.contains("[extra]\ntags = [\"decoy\"]"))
  }

  func testTableTOMLTaxonomiesUseNamespaceAndLeaveExtraTagsUntouched() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = makeZolaProfile(rootURL: rootURL)
    let rawBlock = """
      +++
      title = "Table taxonomies"
      date = "2026-10-13"
      slug = "table-taxonomies"
      [extra]
      tags = ["decoy"]
      custom = "keep"
      [taxonomies]
      tags = ["essay", "fedora"] # taxonomy tags
      categories = ["Linux"]
      series = ["keep"]
      +++
      """
    var draft = try importDraft(
      document: rawBlock + "\n\nBody\n",
      repositoryPath: "content/posts/2026/table-taxonomies.md",
      rootURL: rootURL,
      profile: profile
    )

    XCTAssertEqual(draft.tags, ["essay", "fedora"])
    XCTAssertEqual(draft.categories, ["Linux"])
    XCTAssertEqual(draft.importedFrontMatter?.rawBlock, rawBlock)

    draft.tags = ["essay"]
    let rendered = FrontMatterRenderer().render(draft: draft, profile: profile)
    let expected = rawBlock.replacingOccurrences(
      of: "tags = [\"essay\", \"fedora\"] # taxonomy tags",
      with: "tags = [\"essay\"] # taxonomy tags"
    )
    XCTAssertEqual(rendered, expected)
    XCTAssertTrue(rendered.contains("[extra]\ntags = [\"decoy\"]\ncustom = \"keep\""))
    XCTAssertTrue(rendered.contains("series = [\"keep\"]"))
  }

  func testNestedYAMLTaxonomiesImportWithoutFlatteningOrRegeneratingSource() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = makeZolaProfile(rootURL: rootURL, frontMatterStyle: .yaml)
    let rawBlock = """
      ---
      title: Nested YAML
      date: "2026-10-13"
      slug: nested-yaml
      taxonomies:
        tags:
          - "essay, long"
          - Fedora
        categories: [Linux]
        series: [keep]
      extra:
        tags: [decoy]
      custom: retained # keep custom comment
      ---
      """
    var draft = try importDraft(
      document: rawBlock + "\n\nOriginal body\n",
      repositoryPath: "content/posts/2026/nested-yaml.md",
      rootURL: rootURL,
      profile: profile
    )

    XCTAssertEqual(draft.tags, ["essay, long", "Fedora"])
    XCTAssertEqual(draft.categories, ["Linux"])
    XCTAssertEqual(draft.importedFrontMatter?.rawBlock, rawBlock)

    draft.bodyMarkdown = "Edited body only"
    XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), rawBlock)
    XCTAssertEqual(
      FrontMatterRenderer().renderDocument(draft: draft, profile: profile),
      rawBlock + "\n\nEdited body only\n"
    )
  }

  func testCRLFFrontMatterRawBlockRemainsExactAfterBodyEdit() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/crlf-source.md"
    let rawBlock = [
      "+++",
      "title = \"CRLF source\"",
      "date = \"2026-10-13\"",
      "slug = \"crlf-source\"",
      "taxonomies = { tags = [\"one\"], series = [\"keep\"] }",
      "+++",
    ].joined(separator: "\r\n")
    let document = rawBlock + "\r\n\r\nOriginal body\r\n"
    var draft = try importDraft(
      document: document,
      repositoryPath: repositoryPath,
      rootURL: rootURL,
      profile: profile
    )

    XCTAssertEqual(draft.importedFrontMatter?.rawBlock, rawBlock)

    draft.bodyMarkdown = "Edited body only"
    XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), rawBlock)
  }

  func testSourceEditWithoutSlugPreservesImportedSlugAndRepositoryPath() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/no-slug-source.md"
    let rawBlock = """
      +++
      title = "No slug source"
      date = "2026-10-13"
      taxonomies = { tags = ["one"], series = ["keep"] }
      custom = "before" # comment before
      +++
      """
    let document = rawBlock + "\n\nOriginal body\n"
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try document.write(to: destinationURL, atomically: true, encoding: .utf8)
    let draft = try importDraft(
      document: document,
      repositoryPath: repositoryPath,
      rootURL: rootURL,
      profile: profile
    )
    let editedFrontMatter = rawBlock.replacingOccurrences(
      of: "custom = \"before\" # comment before",
      with: "custom = \"before\" # comment changed"
    )

    let editResult = MarkdownFrontMatterEditingService().applying(
      editedFrontMatter,
      to: draft,
      profile: profile
    )
    XCTAssertTrue(editResult.isValid)
    XCTAssertEqual(editResult.draft.slug, "no-slug-source")
    XCTAssertEqual(editResult.draft.repositoryPath, repositoryPath)
    XCTAssertEqual(editResult.draft.importedFrontMatter?.rawBlock, editedFrontMatter)

    var editedDraft = editResult.draft
    editedDraft.bodyMarkdown = "Edited body"
    let writeResult = try SiteDraftFileStore().write(draft: editedDraft, profile: profile)
    XCTAssertEqual(writeResult.repositoryPath, repositoryPath)
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      editedFrontMatter + "\n\nEdited body\n"
    )
  }

  func testDuplicateAndMalformedTOMLFrontMatterProduceErrorGate() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = makeZolaProfile(rootURL: rootURL)
    let fixtures = [
      (
        "duplicate-key",
        """
        +++
        title = "Duplicate key"
        date = "2026-10-13"
        slug = "duplicate-key"
        [taxonomies]
        tags = ["one"]
        tags = ["two"]
        +++
        """
      ),
      (
        "duplicate-table",
        """
        +++
        title = "Duplicate table"
        date = "2026-10-13"
        slug = "duplicate-table"
        [taxonomies]
        tags = ["one"]
        [taxonomies]
        categories = ["two"]
        +++
        """
      ),
    ]

    for (slug, rawBlock) in fixtures {
      let draft = try importDraft(
        document: rawBlock + "\n\nBody\n",
        repositoryPath: "content/posts/2026/\(slug).md",
        rootURL: rootURL,
        profile: profile
      )
      let issue = try XCTUnwrap(
        FrontMatterRenderer().preservationIssue(draft: draft, profile: profile),
        "\(slug) should be blocked instead of regenerated"
      )
      XCTAssertEqual(issue.severity, .error)
      XCTAssertEqual(issue.ruleID, "content.front-matter.preservation")
      XCTAssertEqual(draft.importedFrontMatter?.rawBlock, rawBlock)
    }
  }

  func testNewNormalizedBindingAllowsFirstWriteAndSubsequentSave() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/new-bound-draft.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "New bound draft",
      slug: "new-bound-draft",
      tags: ["new"],
      categories: ["Writing"],
      bodyMarkdown: "First body"
    )
    draft.repositoryPath = repositoryPath
    draft.normalizeRepositoryBinding(for: profile)

    let binding = try XCTUnwrap(draft.repositoryBinding)
    XCTAssertNil(draft.importedFrontMatter)
    XCTAssertNil(binding.projectFileContentDigest)
    XCTAssertNil(binding.projectFileRenderedContentDigest)
    let renderer = FrontMatterRenderer()
    XCTAssertNil(renderer.preservationIssue(draft: draft, profile: profile))

    let store = SiteDraftFileStore()
    let firstWrite = try store.write(draft: draft, profile: profile)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    XCTAssertEqual(firstWrite.repositoryPath, repositoryPath)
    XCTAssertEqual(firstWrite.writtenPaths, [repositoryPath])
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      renderer.renderDocument(draft: draft, profile: profile)
    )

    draft.recordProjectFile(
      profile: profile, repositoryPath: repositoryPath,
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    draft.bodyMarkdown = "Second body"
    XCTAssertNil(renderer.preservationIssue(draft: draft, profile: profile))
    _ = try SiteDraftFileStore().write(draft: draft, profile: profile)
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      renderer.renderDocument(draft: draft, profile: profile)
    )
  }

  func testNewBindingNeverOverwritesAnExistingUnimportedFile() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/occupied.md"
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let originalDocument = "+++\ncustom = \"keep\"\n+++\n\nExternal body\n"
    try originalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)
    var draft = ArticleDraft(
      siteProfileID: profile.id, title: "New binding", slug: "occupied",
      bodyMarkdown: "New body", repositoryPath: repositoryPath
    )
    draft.normalizeRepositoryBinding(for: profile)
    XCTAssertNil(FrontMatterRenderer().preservationIssue(draft: draft, profile: profile))

    XCTAssertThrowsError(try SiteDraftFileStore().write(draft: draft, profile: profile)) { error in
      XCTAssertEqual(
        error as? SiteDraftFileStoreError, .projectFileChangedExternally(repositoryPath)
      )
    }
    XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), originalDocument)
  }

  func testLegacyImportEvidenceWithoutLocalDigestsStillRequiresRecovery() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/legacy-import.md"
    let legacySources: [(String?, String?)] = [
      ("old-revision", nil), (nil, "old-import-fingerprint"),
    ]
    for (revision, fingerprint) in legacySources {
      let draft = ArticleDraft(
        siteProfileID: profile.id, title: "Legacy import", slug: "legacy-import",
        bodyMarkdown: "Edited body", repositoryPath: repositoryPath,
        repositorySHA: revision, repositoryImportFingerprint: fingerprint
      )
      XCTAssertNil(draft.repositoryBinding?.projectFileContentDigest)
      XCTAssertNil(draft.repositoryBinding?.projectFileRenderedContentDigest)
      XCTAssertEqual(
        FrontMatterRenderer().preservationIssue(draft: draft, profile: profile)?.severity, .error
      )
      XCTAssertThrowsError(try SiteDraftFileStore().write(draft: draft, profile: profile)) {
        error in
        XCTAssertEqual(error as? SiteDraftFileStoreError, .frontMatterRecoveryRequired)
      }
    }
  }

  func testLegacyNoncanonicalBoundDraftWithoutSourceRefusesLocalWrite() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/legacy-source.md"
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    let originalDocument = """
      +++
      title = "Legacy source"
      date = "2026-10-13"
      slug = "legacy-source"
      taxonomies = { tags = ["keep"], series = ["unknown"] }
      custom = "must survive"
      +++

      Original body
      """
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try originalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Legacy source",
      date: try parseDate("2026-10-13"),
      slug: "legacy-source",
      tags: ["keep"],
      bodyMarkdown: "Original body",
      repositoryPath: repositoryPath
    )
    let canonicalDigest = draft.renderedRepositoryContentDigest(profile: profile)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: repositoryPath,
      renderedContentDigest: canonicalDigest,
      projectFileContentDigest: ArticleDraft.repositoryDocumentDigest(originalDocument)
    )
    draft.bodyMarkdown = "Edited body"

    XCTAssertNil(draft.importedFrontMatter)
    XCTAssertEqual(
      FrontMatterRenderer().preservationIssue(draft: draft, profile: profile)?.severity,
      .error
    )
    XCTAssertThrowsError(try SiteDraftFileStore().write(draft: draft, profile: profile)) { error in
      XCTAssertEqual(error as? SiteDraftFileStoreError, .frontMatterRecoveryRequired)
    }
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      originalDocument
    )
  }

  func testLegacyBoundDraftWithoutExactDigestRefusesLocalWrite() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    let profile = makeZolaProfile(rootURL: rootURL)
    let repositoryPath = "content/posts/2026/legacy-missing-exact.md"
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    let originalDocument = """
      +++
      title = "Legacy missing exact digest"
      date = "2026-10-13"
      slug = "legacy-missing-exact"
      taxonomies = { tags = ["keep"], series = ["unknown"] }
      custom = "must survive"
      +++

      Original body
      """
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try originalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Legacy missing exact digest",
      date: try parseDate("2026-10-13"),
      slug: "legacy-missing-exact",
      tags: ["keep"],
      bodyMarkdown: "Original body",
      repositoryPath: repositoryPath,
      repositoryBinding: DraftRepositoryBinding(
        identity: DraftRepositoryIdentity(profile: profile), repositoryPath: repositoryPath,
        projectFileRenderedContentDigest: "legacy-rendered-digest"
      )
    )
    draft.bodyMarkdown = "Edited body"

    XCTAssertNil(draft.importedFrontMatter)
    XCTAssertNil(draft.repositoryBinding?.projectFileContentDigest)
    XCTAssertNotNil(draft.repositoryBinding?.projectFileRenderedContentDigest)
    let editor = MarkdownFrontMatterEditingService()
    let edited = editor.applying(
      editor.render(draft: draft, profile: profile), to: draft, profile: profile)
    XCTAssertTrue(edited.isValid)
    XCTAssertNil(edited.draft.importedFrontMatter)
    XCTAssertEqual(
      FrontMatterRenderer().preservationIssue(draft: edited.draft, profile: profile)?.severity,
      .error)
    XCTAssertEqual(
      FrontMatterRenderer().preservationIssue(draft: draft, profile: profile)?.severity,
      .error
    )
    XCTAssertThrowsError(try SiteDraftFileStore().write(draft: draft, profile: profile)) { error in
      XCTAssertEqual(error as? SiteDraftFileStoreError, .frontMatterRecoveryRequired)
    }
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      originalDocument
    )
  }

  func testDateEditKeepsSourceStyleInLocalTimeZone() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let previousTimeZone = NSTimeZone.default
    let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    NSTimeZone.default = shanghai
    defer { NSTimeZone.default = previousTimeZone }
    let profile = makeZolaProfile(rootURL: rootURL)
    let editedDate = try parseDate("2026-10-14", timeZone: shanghai)
    let fixtures = [
      ("date = \"2026-10-13\"", "date = \"2026-10-14\""),
      ("date = 2026-10-13", "date = 2026-10-14"),
      ("date = 2026-10-13T08:30:00+08:00", "date = 2026-10-14T00:00:00+08:00"),
    ]
    for (index, (sourceLine, expectedLine)) in fixtures.enumerated() {
      let rawBlock = "+++\ntitle = \"Dated\"\n\(sourceLine)\n+++"
      var draft = try importDraft(
        document: rawBlock + "\n\nBody\n",
        repositoryPath: "content/posts/2026/dated-\(index).md",
        rootURL: rootURL,
        profile: profile
      )
      XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), rawBlock)
      draft.date = editedDate
      XCTAssertEqual(
        FrontMatterRenderer().render(draft: draft, profile: profile),
        rawBlock.replacingOccurrences(of: sourceLine, with: expectedLine)
      )
      XCTAssertNil(FrontMatterRenderer().preservationIssue(draft: draft, profile: profile))
    }
  }

  func testCoverIsAddedToZolaExtraTableWhenSourceHasNoCover() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let header = "+++\ntitle = \"Cover\"\ndate = \"2026-10-13\""
    let fixtures: [(FrontMatterStyle, String, String)] = [
      (
        .toml, header + "\n[taxonomies]\ntags = [\"one\"]\n+++",
        header + "\n[taxonomies]\ntags = [\"one\"]\n[extra]"
          + "\nog_preview_img = \"/images/cover.png\"\n+++"
      ),
      (
        .toml, header + "\n[extra]\ncustom = \"keep\"\n+++",
        header + "\n[extra]\nog_preview_img = \"/images/cover.png\"\ncustom = \"keep\"\n+++"
      ),
      (
        .yaml, "---\ntitle: Cover\ndate: \"2026-10-13\"\n---",
        "---\ntitle: Cover\ndate: \"2026-10-13\"\nextra:\n  og_preview_img: \"/images/cover.png\"\n---"
      ),
    ]
    for (index, (style, rawBlock, expected)) in fixtures.enumerated() {
      let profile = makeZolaProfile(rootURL: rootURL, frontMatterStyle: style)
      var draft = try importDraft(
        document: rawBlock + "\n\nBody\n",
        repositoryPath: "content/posts/2026/cover-\(index).md",
        rootURL: rootURL,
        profile: profile
      )
      setCover(on: &draft)
      XCTAssertNil(FrontMatterRenderer().preservationIssue(draft: draft, profile: profile))
      XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), expected)
    }

    // Nested YAML `extra` cannot be scanned, so the blocker names the cover field.
    let profile = makeZolaProfile(rootURL: rootURL, frontMatterStyle: .yaml)
    let rawBlock = "---\ntitle: Cover\nextra:\n  custom: keep\n---"
    var draft = try importDraft(
      document: rawBlock + "\n\nBody\n",
      repositoryPath: "content/posts/2026/cover-yaml-extra.md",
      rootURL: rootURL,
      profile: profile
    )
    setCover(on: &draft)
    let issue = try XCTUnwrap(
      FrontMatterRenderer().preservationIssue(draft: draft, profile: profile))
    XCTAssertEqual(issue.field, "cover")
    XCTAssertEqual(issue.ruleID, "content.front-matter.preservation")
    XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), rawBlock)
  }

  func testVisibilityDraftAndCoverAreAddedOnlyWhereCanonicalRendererWritesThem() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var profile = makeZolaProfile(rootURL: rootURL)
    let rawBlock = "+++\ntitle = \"Visibility\"\ndate = \"2026-10-13\"\n+++"
    var draft = try importDraft(
      document: rawBlock + "\n\nBody\n",
      repositoryPath: "content/posts/2026/visibility.md",
      rootURL: rootURL,
      profile: profile
    )

    draft.visibility = .private
    setCover(on: &draft)
    XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), rawBlock)
    XCTAssertNil(FrontMatterRenderer().preservationIssue(draft: draft, profile: profile))

    profile.includeDraftFlagInFrontMatter = false
    profile.includeCoverInFrontMatter = false
    draft.visibility = .public
    draft.draft = !draft.draft
    XCTAssertEqual(FrontMatterRenderer().render(draft: draft, profile: profile), rawBlock)

    let existing = rawBlock.replacingOccurrences(
      of: "+++\ntitle", with: "+++\nvisibility = \"public\"\ntitle")
    var withField = try importDraft(
      document: existing + "\n\nBody\n",
      repositoryPath: "content/posts/2026/visibility-field.md",
      rootURL: rootURL,
      profile: profile
    )
    withField.visibility = .private
    XCTAssertEqual(
      FrontMatterRenderer().render(draft: withField, profile: profile),
      existing.replacingOccurrences(of: "\"public\"", with: "\"private\"")
    )
  }

  private func setCover(on draft: inout ArticleDraft) {
    let cover = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png"
    )
    draft.attachments.append(cover)
    draft.coverAttachmentID = cover.id
  }

  private func importDraft(
    document: String,
    repositoryPath: String,
    rootURL: URL,
    profile: SiteProfile,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> ArticleDraft {
    let result = LocalContentImportService(isContentIndexEnabled: false).importDraft(
      document: document,
      rootURL: rootURL,
      repositoryPath: repositoryPath,
      profile: profile
    )
    XCTAssertTrue(result.skippedPaths.isEmpty, file: file, line: line)
    XCTAssertTrue(result.issues.isEmpty, file: file, line: line)
    return try XCTUnwrap(result.importedDrafts.first, file: file, line: line)
  }

  private func makeZolaProfile(
    rootURL: URL,
    frontMatterStyle: FrontMatterStyle = .toml
  ) -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = frontMatterStyle
    profile.localRepositoryRootPath = rootURL.path
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{year}/{slug}.md"
    return profile
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "zola-front-matter-preservation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeGitMarker(at rootURL: URL) throws {
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  private func parseDate(
    _ value: String, timeZone: TimeZone? = TimeZone(secondsFromGMT: 0)
  ) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return try XCTUnwrap(formatter.date(from: value))
  }
}
