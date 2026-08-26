import XCTest
@testable import PublishingWorkbenchCore

final class PublishPackageBuilderTests: XCTestCase {
  func testBuildsTOMLFrontMatterAndPackageFiles() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .toml
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.defaultAuthor = "Jinfang"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Mac 发布链路",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "mac-publish-flow",
      tags: ["Mac", "发布"],
      categories: ["Product"],
      draft: false,
      summary: "桌面版发布包测试。",
      bodyMarkdown: "# Body"
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let markdown = try XCTUnwrap(package.markdownFile?.content)

    XCTAssertEqual(package.markdownPath, "content/posts/mac-publish-flow.md")
    XCTAssertTrue(markdown.contains("+++\ntitle = \"Mac 发布链路\""))
    XCTAssertTrue(markdown.contains("authors = [\"Jinfang\"]"))
    XCTAssertTrue(markdown.contains("tags = [\"Mac\", \"发布\"]"))
    XCTAssertTrue(markdown.hasSuffix("# Body\n"))
  }

  func testMarkdownFileCarriesExpectedRemoteSHAWhenDraftMatchesRepositoryPath() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Imported Draft",
      slug: "imported-draft",
      bodyMarkdown: "Long enough body content for expected remote SHA package coverage."
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/imported-draft.md",
      remoteRevision: "remote-base-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    XCTAssertEqual(package.markdownFile?.expectedRemoteSHA, "remote-base-sha")
  }

  func testMarkdownFileSkipsExpectedRemoteSHAWhenPathChanged() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Moved Draft",
      slug: "moved-draft",
      bodyMarkdown: "Long enough body content for moved remote SHA package coverage."
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/old-path.md",
      remoteRevision: "old-remote-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    XCTAssertNil(package.markdownFile?.expectedRemoteSHA)
    XCTAssertEqual(package.files.count, 2)
    XCTAssertEqual(package.files[0].operation, .upsert)
    XCTAssertEqual(package.files[0].repositoryPath, "content/posts/moved-draft.md")
    XCTAssertEqual(package.files[1].operation, .delete)
    XCTAssertEqual(package.files[1].repositoryPath, "content/posts/old-path.md")
    XCTAssertEqual(package.files[1].expectedRemoteSHA, "old-remote-sha")
  }

  func testMarkdownFileRejectsLegacyOrMismatchedRepositoryRevision() {
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let legacyDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Legacy",
      slug: "legacy",
      bodyMarkdown: "Legacy SHA has not been verified for this repository identity.",
      repositoryPath: "content/posts/legacy.md",
      repositorySHA: "legacy-sha"
    )

    XCTAssertNil(
      PublishPackageBuilder().build(draft: legacyDraft, profile: profile)
        .markdownFile?.expectedRemoteSHA
    )

    var verifiedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Verified Elsewhere",
      slug: "verified-elsewhere",
      bodyMarkdown: "A verified revision is still scoped to one repository identity."
    )
    verifiedDraft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/verified-elsewhere.md",
      remoteRevision: "verified-sha",
      renderedContentDigest: verifiedDraft.renderedRepositoryContentDigest(profile: profile)
    )
    var otherProfile = profile
    otherProfile.repoName = "other-site"

    XCTAssertNil(
      PublishPackageBuilder().build(draft: verifiedDraft, profile: otherProfile)
        .markdownFile?.expectedRemoteSHA
    )
  }

  func testImageFileCarriesExpectedRemoteSHAForSafeRepublish() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png",
      sourceFilePath: "/tmp/cover.png",
      repositorySHA: "remote-image-sha"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Republish With Image",
      slug: "republish-with-image",
      bodyMarkdown: "Long enough body content for attachment remote version coverage.",
      attachments: [attachment]
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let imageFile = try XCTUnwrap(package.files.first { $0.kind == .image })

    XCTAssertEqual(imageFile.repositoryPath, "static/images/cover.png")
    XCTAssertEqual(imageFile.expectedRemoteSHA, "remote-image-sha")
  }

  func testVideoFileUsesBinaryPublishKindAndCarriesExpectedRemoteSHA() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let attachment = DraftAttachment(
      originalFilename: "walkthrough.mp4",
      relativePublishPath: "/videos/2026/walkthrough.mp4",
      repositoryPath: "static/videos/2026/walkthrough.mp4",
      sourceFilePath: "/tmp/walkthrough.mp4",
      repositorySHA: "remote-video-sha"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Publish With Video",
      slug: "publish-with-video",
      bodyMarkdown: "Long enough body content for video publish package coverage.",
      attachments: [attachment]
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let videoFile = try XCTUnwrap(package.files.first { $0.kind == .video })

    XCTAssertEqual(videoFile.repositoryPath, "static/videos/2026/walkthrough.mp4")
    XCTAssertEqual(videoFile.sourceFilePath, "/tmp/walkthrough.mp4")
    XCTAssertEqual(videoFile.expectedRemoteSHA, "remote-video-sha")
  }

  func testDraftAttachmentDecodesLegacyPayloadWithoutRepositorySHA() throws {
    let data = #"{"id":"00000000-0000-0000-0000-000000000001","originalFilename":"legacy.png","relativePublishPath":"/images/legacy.png","repositoryPath":"static/images/legacy.png","altText":"","caption":"","byteSize":4}"#
      .data(using: .utf8)!

    let attachment = try JSONDecoder().decode(DraftAttachment.self, from: data)

    XCTAssertNil(attachment.repositorySHA)
  }

  func testPublishPackageFileDecodesLegacyPayloadAsUpsert() throws {
    let data = #"{"kind":"markdown","repositoryPath":"content/posts/legacy.md","content":"legacy","byteSize":0}"#
      .data(using: .utf8)!

    let file = try JSONDecoder().decode(PublishPackageFile.self, from: data)

    XCTAssertEqual(file.operation, .upsert)
  }

  func testBuildsYAMLFrontMatter() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .yaml
    profile.markdownPathPattern = "content/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "YAML Draft",
      slug: "yaml-draft",
      draft: true,
      bodyMarkdown: "Long enough body content for a publish package renderer test."
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let markdown = try XCTUnwrap(package.markdownFile?.content)

    XCTAssertTrue(markdown.hasPrefix("---\ntitle: \"YAML Draft\""))
    XCTAssertTrue(markdown.contains("draft: true"))
    XCTAssertTrue(markdown.contains("---\n\nLong enough body content"))
  }

  func testZolaCoverUsesExtraOgPreviewImage() throws {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)
    let attachmentID = UUID(uuidString: "3C4F0758-51FB-4F67-8B26-1B8097C90838")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "static/images/2026/cover.jpg",
      altText: "Cover"
    )

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Zola Cover",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "zola-cover",
      draft: false,
      coverAttachmentID: attachmentID,
      bodyMarkdown: "Long enough body content for a Zola cover renderer test.",
      attachments: [attachment]
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let markdown = try XCTUnwrap(package.markdownFile?.content)

    XCTAssertTrue(markdown.contains("[extra]\nog_preview_img = \"/images/2026/cover.jpg\""))
    XCTAssertFalse(markdown.contains("\ncover = "))
    XCTAssertFalse(markdown.contains("\nimage = "))
  }

  func testJekyllCoverUsesImageField() throws {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .jekyll)
    let attachmentID = UUID(uuidString: "497C0BB3-A9D4-4C15-826F-6AC2D91E1258")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "cover.jpg",
      relativePublishPath: "/assets/images/2026/cover.jpg",
      repositoryPath: "assets/images/2026/cover.jpg",
      altText: "Cover"
    )

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Jekyll Cover",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "jekyll-cover",
      draft: false,
      coverAttachmentID: attachmentID,
      bodyMarkdown: "Long enough body content for a Jekyll cover renderer test.",
      attachments: [attachment]
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let markdown = try XCTUnwrap(package.markdownFile?.content)

    XCTAssertTrue(markdown.contains("\nimage: \"/assets/images/2026/cover.jpg\""))
    XCTAssertFalse(markdown.contains("\ncover: "))
    XCTAssertFalse(markdown.contains("og_preview_img"))
  }

  func testPrivateDraftDoesNotExposeCoverPathInFrontMatter() throws {
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .zola)
    let attachmentID = UUID(uuidString: "6B38C37B-3E94-48B4-A07B-6D17A2828FC1")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "private-cover.jpg",
      relativePublishPath: "/images/2026/private-cover.jpg",
      repositoryPath: "static/images/2026/private-cover.jpg",
      altText: "Private cover"
    )

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Private Draft",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "private-draft",
      draft: true,
      visibility: .private,
      coverAttachmentID: attachmentID,
      bodyMarkdown: "Long enough body content for a private cover renderer test.",
      attachments: [attachment]
    )

    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let markdown = try XCTUnwrap(package.markdownFile?.content)

    XCTAssertEqual(package.markdownPath, "private/posts/2026/private-draft.md")
    XCTAssertFalse(package.files.contains { $0.repositoryPath.hasPrefix("content/posts/") })
    XCTAssertFalse(markdown.contains("og_preview_img"))
    XCTAssertFalse(markdown.contains("private-cover.jpg"))
    XCTAssertFalse(markdown.contains("\ncover = "))
  }
}
