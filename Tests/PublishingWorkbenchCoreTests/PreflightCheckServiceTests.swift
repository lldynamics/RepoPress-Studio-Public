import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

final class PreflightCheckServiceTests: XCTestCase {
  func testUnknownHugoShortcodeBlocksPublishingWhileThemeDefinitionPasses() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("shortcode-preflight-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcodes = root.appendingPathComponent("layouts/_shortcodes", isDirectory: true)
    try FileManager.default.createDirectory(at: shortcodes, withIntermediateDirectories: true)
    try "{{ .Get \"title\" }}".write(
      to: shortcodes.appendingPathComponent("card.html"), atomically: true, encoding: .utf8
    )
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hugo
    profile.localRepositoryRootPath = root.path
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Shortcode article",
      slug: "shortcode-article",
      draft: false,
      bodyMarkdown: "正文 {{< card title=\"Hello\" >}}。\n{{< absent >}}"
    )

    let issues = PreflightCheckService().run(
      draft: draft, allDrafts: [draft], profile: profile,
      includeRepositoryReadiness: false
    )
    let unknown = issues.filter { $0.title == "未知短代码" }
    XCTAssertEqual(unknown.count, 1)
    XCTAssertEqual(unknown.first?.relatedValue, "absent")
    XCTAssertEqual(unknown.first?.severity, .error)
  }

  func testUnavailableCatalogWarnsWithoutClaimingShortcodeIsUnknown() {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hugo
    profile.localRepositoryRootPath = ""
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Shortcode article",
      slug: "shortcode-article",
      bodyMarkdown: "An article with {{< custom >}} and an unavailable local theme directory."
    )
    let issues = PreflightCheckService().run(
      draft: draft, allDrafts: [draft], profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertTrue(issues.contains { $0.title == "短代码目录无法核实" && $0.severity == .warning })
    XCTAssertFalse(issues.contains { $0.title == "未知短代码" })
  }

  func testZolaTeraFunctionIsNotReportedAsUnknownLegacyShortcode() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("zola-shortcode-preflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "".write(to: root.appendingPathComponent("zola.toml"), atomically: true, encoding: .utf8)
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = root.path
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Zola components",
      slug: "zola-components",
      bodyMarkdown: "{{ get_url(path=\"@/post.md\") }} and {{<missing/>}} in this Zola page."
    )

    let issues = PreflightCheckService().run(
      draft: draft, allDrafts: [draft], profile: profile,
      includeRepositoryReadiness: false
    )
    let unknown = issues.filter { $0.title == "未知短代码" }
    XCTAssertEqual(unknown.map(\.relatedValue), ["missing"])
  }

  func testZolaLegacyConfigChecksUnknownLegacyShortcode() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("zola-legacy-preflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = root.path
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Legacy shortcode article",
      slug: "legacy-shortcode",
      bodyMarkdown: "{{ get_url(path=\"@/post.md\") }} and {{ missing() }}"
    )

    let issues = PreflightCheckService().run(
      draft: draft, allDrafts: [draft], profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertEqual(issues.filter { $0.title == "未知短代码" }.map(\.relatedValue), ["missing"])
  }

  func testReportsMissingRequiredMetadata() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "",
      slug: "",
      bodyMarkdown: ""
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile
    )

    XCTAssertTrue(issues.contains { $0.severity == .error && $0.field == "title" })
    XCTAssertTrue(issues.contains { $0.severity == .error && $0.field == "slug" })
  }

  func testInvalidNonEmptySlugIsAWarningAndDoesNotBlockByItself() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Existing Article",
      slug: "Existing Article",
      draft: false,
      bodyMarkdown: "This body is long enough to isolate the non-empty invalid slug warning."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    let slugIssue = issues.first { $0.title == CoreL10n.text("Slug 格式非法") }
    XCTAssertEqual(slugIssue?.severity, .warning)
    XCTAssertFalse(
      issues.contains {
        $0.field == "slug" && $0.severity == .error
      }
    )
  }

  func testReportsDuplicateRenderedPublishPath() {
    let profile = SiteProfile.defaultProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "same-slug",
      bodyMarkdown: "This body is intentionally long enough for the preflight length rule."
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "same-slug",
      bodyMarkdown: "This body is intentionally long enough for the preflight length rule."
    )

    let issues = PreflightCheckService().run(
      draft: first,
      allDrafts: [first, second],
      profile: profile
    )

    XCTAssertTrue(issues.contains { $0.title == CoreL10n.text("发布路径重复") })
  }

  func testDuplicateIndexMatchesPerDraftScanForCaseInsensitiveTitlesAndPaths() {
    let profile = SiteProfile.defaultProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "Case Sensitive Title",
      slug: "shared-path",
      bodyMarkdown: "This body is intentionally long enough for indexed preflight comparison."
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "case sensitive title",
      slug: "shared-path",
      bodyMarkdown: "This second body is intentionally long enough for indexed preflight comparison."
    )
    let third = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unique Title",
      slug: "unique-path",
      bodyMarkdown: "This third body is intentionally long enough for indexed preflight comparison."
    )
    let drafts = [first, second, third]
    let service = PreflightCheckService()
    let duplicateIndex = PreflightDuplicateIndex(drafts: drafts, profile: profile)

    for draft in drafts {
      let scanned = service.run(
        draft: draft,
        allDrafts: drafts,
        profile: profile,
        includeRepositoryReadiness: false
      )
      let indexed = service.run(
        draft: draft,
        allDrafts: drafts,
        profile: profile,
        includeRepositoryReadiness: false,
        duplicateIndex: duplicateIndex
      )

      XCTAssertEqual(issueSignatures(indexed), issueSignatures(scanned))
    }
  }

  func testDuplicateIndexDoesNotTreatRepeatedSameIDDraftAsAnotherDraft() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Repeated Snapshot",
      slug: "repeated-snapshot",
      bodyMarkdown: "This body is intentionally long enough for repeated snapshot duplicate checks."
    )
    let drafts = [draft, draft]
    let service = PreflightCheckService()
    let issues = service.run(
      draft: draft,
      allDrafts: drafts,
      profile: profile,
      includeRepositoryReadiness: false,
      duplicateIndex: PreflightDuplicateIndex(drafts: drafts, profile: profile)
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("标题重复") })
    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("发布路径重复") })
  }

  func testReportsMarkdownPathOutsideContentRoot() {
    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    profile.markdownPathPattern = "notes/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Outside Content Root",
      slug: "outside-content-root",
      bodyMarkdown: "This body is intentionally long enough for the preflight path rule validation."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(
      issues.contains {
        $0.title == "Markdown 路径不在内容目录"
          && $0.field == "markdownPathPattern"
          && $0.severity == .error
      }
    )
  }

  func testReportsImagePathOutsideAssetRoot() {
    var profile = SiteProfile.defaultProfile
    profile.assetRoot = "static"
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "public/images/2026/cover.jpg",
      altText: "Cover image"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Outside Asset Root",
      slug: "outside-asset-root",
      bodyMarkdown: "This body is intentionally long enough for the preflight image path rule validation.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(
      issues.contains {
        $0.title == "图片路径不在图片目录"
          && $0.field == "attachments"
          && $0.severity == .error
      }
    )
  }

  func testReportsUnsafeRepositoryPathRules() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "/content/posts/{slug}.md"
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "/tmp/cover.jpg",
      altText: "Cover image"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unsafe Paths",
      slug: "unsafe-paths",
      bodyMarkdown: "This body is intentionally long enough for unsafe path rule validation.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(issues.contains { $0.title == "Markdown 路径规则不安全" && $0.severity == .error })
    XCTAssertTrue(issues.contains { $0.title == "图片路径不安全" && $0.severity == .error })
  }

  func testVideoAttachmentDoesNotRequireImageMetadata() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "walkthrough.mp4",
      relativePublishPath: "/videos/2026/walkthrough.mp4",
      repositoryPath: "static/videos/2026/walkthrough.mp4",
      altText: "",
      caption: ""
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Video Attachment",
      slug: "video-attachment",
      bodyMarkdown: "This body is intentionally long enough to isolate video attachment preflight behavior.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("图片缺少 alt") })
    XCTAssertFalse(issues.contains { $0.field == "attachments" && $0.severity == .error })
  }

  func testReportsPublicRiskWithoutEchoingSecretValue() {
    let profile = SiteProfile.defaultProfile
    let secret = "sk-12345678901234567890abcd"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Risk",
      slug: "risk",
      bodyMarkdown: "This article is long enough. api_key = \"\(secret)\" should never be published in a public post."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    let issue = issues.first {
      $0.title == CoreL10n.text("疑似密钥泄露") && $0.field == "body"
    }
    XCTAssertEqual(issue?.severity, .error)
    XCTAssertFalse(issue?.message.contains(secret) ?? true)
  }

  func testReportsInternalAddressAndLocalPathAsWarnings() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Local Debug",
      slug: "local-debug",
      bodyMarkdown: """
      This article documents a local preview workflow and includes enough text for the length rule.
      Preview was tested at http://192.168.1.12:4321 from /Users/example/site/content/posts/demo.md.
      """
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(issues.contains {
      $0.title == CoreL10n.text("内网地址疑似泄露") && $0.severity == .warning
    })
    XCTAssertTrue(issues.contains {
      $0.title == CoreL10n.text("本机路径疑似泄露") && $0.severity == .warning
    })
  }

  func testRepositoryBackupPurposeSkipsDeploymentReadinessButKeepsRepositorySafety() {
    var profile = SiteProfile.defaultProfile
    profile.purpose = .repositoryBackup
    profile.localRepositoryRootPath = "/tmp/site-backup"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Repository Backup",
      slug: "repository-backup",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so repository backup readiness filtering is isolated."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      repositoryReport: repositoryReportWithDeploymentAndGitIssues()
    )

    XCTAssertTrue(issues.contains { $0.title == "未发现 .git" && $0.field == "repository" })
    XCTAssertFalse(issues.contains { $0.field == "siteKind" })
    XCTAssertFalse(issues.contains { $0.field == "contentRoot" })
    XCTAssertFalse(issues.contains { $0.field == "assetRoot" })
  }

  func testGeneralDraftPurposeSkipsRepositoryReadiness() {
    var profile = SiteProfile.defaultProfile
    profile.purpose = .generalDraftBackup
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "General Draft",
      slug: "general-draft",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so general draft checks do not require repository readiness."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      repositoryReport: repositoryReportWithDeploymentAndGitIssues()
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("未选择本地仓库") })
    XCTAssertFalse(issues.contains { $0.field == "repository" })
    XCTAssertFalse(issues.contains { $0.field == "siteKind" })
    XCTAssertFalse(issues.contains { $0.field == "contentRoot" })
    XCTAssertFalse(issues.contains { $0.field == "assetRoot" })
  }

  private func repositoryReportWithDeploymentAndGitIssues() -> RepositoryScanReport {
    RepositoryScanReport(
      rootPath: "/tmp/site-backup",
      detectedKind: .hugo,
      expectedKind: .zola,
      hasGitDirectory: false,
      contentRootExists: false,
      assetRootExists: false,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      preflightIssues: [
        .init(severity: .warning, title: "站点类型可能不一致", message: "配置为 Zola，扫描到 Hugo。", field: "siteKind"),
        .init(severity: .warning, title: "未发现 .git", message: "当前目录不是 Git 工作树。", field: "repository"),
        .init(severity: .error, title: "内容目录不存在", message: "content", field: "contentRoot"),
        .init(severity: .warning, title: "图片目录不存在", message: "static", field: "assetRoot"),
      ]
    )
  }

  private func issueSignatures(_ issues: [PreflightIssue]) -> [String] {
    issues.map {
      "\($0.severity.rawValue)|\($0.title)|\($0.message)|\($0.field ?? "")"
    }
  }
}

final class ThemeShortcodeCatalogServiceTests: XCTestCase {
  private let service = ThemeShortcodeCatalogService()

  func testHugoRootOverrideWinsOverSelectedThemeAndProvidesParameterHints() throws {
    let fixture = try makeFixture(siteKind: .hugo)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write("theme = \"paper\"\n", at: fixture.root.appendingPathComponent("hugo.toml"))
    try write(
      "{{ .Get \"title\" }} {{ .Params.class }} {{ .Inner }}",
      at: fixture.root.appendingPathComponent("themes/paper/layouts/_shortcodes/callout.html")
    )
    try write(
      "{{ .Get \"tone\" }}",
      at: fixture.root.appendingPathComponent("layouts/_shortcodes/callout.html")
    )
    try write(
      "{{ .Get \"src\" }}",
      at: fixture.root.appendingPathComponent("layouts/_shortcodes/media/audio.en.rss.xml")
    )

    let catalog = service.catalog(profile: fixture.profile)

    XCTAssertEqual(catalog.selectedThemeName, "paper")
    XCTAssertEqual(catalog.definitions.map(\.name), ["callout", "media/audio"])
    let callout = try XCTUnwrap(catalog.definitions.first { $0.name == "callout" })
    XCTAssertEqual(callout.parameters.map(\.name), ["tone"])
    XCTAssertEqual(callout.source, .repositoryOverride)
    XCTAssertEqual(callout.repositoryPath, "layouts/_shortcodes/callout.html")
    XCTAssertEqual(callout.insertionTemplate, "{{< callout tone=\"value\" >}}")
    XCTAssertEqual(
      catalog.definitions.first { $0.name == "media/audio" }?.repositoryPath,
      "layouts/_shortcodes/media/audio.en.rss.xml"
    )
  }

  func testHugoReadsOnlyTheConfiguredTheme() throws {
    let fixture = try makeFixture(siteKind: .hugo)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write("theme: paper\n", at: fixture.root.appendingPathComponent("hugo.yaml"))
    try write(
      "{{ .Get \"title\" }} {{ index .Params \"accent\" }}",
      at: fixture.root.appendingPathComponent("themes/paper/layouts/_shortcodes/note.html")
    )
    try write(
      "{{ .Get \"ignored\" }}",
      at: fixture.root.appendingPathComponent("themes/other/layouts/_shortcodes/ignored.html")
    )

    let catalog = service.catalog(profile: fixture.profile)

    XCTAssertEqual(catalog.selectedThemeName, "paper")
    XCTAssertEqual(catalog.definitions.map(\.name), ["note"])
    XCTAssertEqual(catalog.definitions[0].parameters.map(\.name), ["accent", "title"])
    XCTAssertEqual(catalog.definitions[0].source, .configuredTheme(name: "paper"))
    XCTAssertEqual(
      catalog.definitions[0].insertionTemplate, "{{< note accent=\"value\" title=\"value\" >}}")
  }

  func testHugoLocalizedOutputVariantUsesBaseShortcodeName() throws {
    let fixture = try makeFixture(siteKind: .hugo)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write(
      "{{ .Get \"title\" }}",
      at: fixture.root.appendingPathComponent("layouts/_shortcodes/media/card.en.rss.xml")
    )

    let catalog = service.catalog(profile: fixture.profile)
    XCTAssertEqual(catalog.definitions.map(\.name), ["media/card"])
    XCTAssertEqual(catalog.definitions[0].insertionTemplate, "{{< media/card title=\"value\" >}}")
  }

  func testZolaDiscoversLegacyShortcodeWithLegacyConfig() throws {
    let fixture = try makeFixture(siteKind: .zola)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write("theme = \"paper\"\n", at: fixture.root.appendingPathComponent("config.toml"))
    try write(
      "<aside>{{ title }}</aside>",
      at: fixture.root.appendingPathComponent("templates/shortcodes/notice.html")
    )
    try write(
      "{% component ui.button(label: string, variant = \"primary\") %}<button>{{ label }}</button>{% endcomponent %}",
      at: fixture.root.appendingPathComponent("themes/paper/templates/base.html")
    )

    let catalog = service.catalog(profile: fixture.profile)

    XCTAssertEqual(catalog.selectedThemeName, "paper")
    XCTAssertTrue(catalog.usesLegacyZolaShortcodes)
    XCTAssertEqual(catalog.definitions.map(\.name), ["notice"])
    let notice = try XCTUnwrap(catalog.definitions.first { $0.name == "notice" })
    XCTAssertEqual(notice.insertionTemplate, "{{ notice(title=\"value\") }}")
  }

  func testZolaCurrentConfigDiscoversComponentsWithoutLegacyShortcodes() throws {
    let fixture = try makeFixture(siteKind: .zola)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write("theme = \"paper\"\n", at: fixture.root.appendingPathComponent("zola.toml"))
    try write(
      "<aside>{{ title }}</aside>",
      at: fixture.root.appendingPathComponent("templates/shortcodes/notice.html")
    )
    try write(
      "{% component ui.button(label: string, variant = \"primary\") %}<button>{{ label }}</button>{% endcomponent %}",
      at: fixture.root.appendingPathComponent("themes/paper/templates/base.html")
    )

    let catalog = service.catalog(profile: fixture.profile)

    XCTAssertFalse(catalog.usesLegacyZolaShortcodes)
    XCTAssertEqual(catalog.definitions.map(\.name), ["ui.button"])
    let button = try XCTUnwrap(catalog.definitions.first { $0.name == "ui.button" })
    XCTAssertEqual(
      button.parameters,
      [
        ThemeShortcodeParameter(name: "label"),
        ThemeShortcodeParameter(name: "variant", defaultValue: "\"primary\""),
      ])
    XCTAssertEqual(button.source, .teraComponent)
    XCTAssertEqual(
      button.insertionTemplate, "{{<ui.button label=\"value\" variant=\"primary\" />}}")
  }

  func testZolaRootComponentOverridesThemeAndUsesBlockSyntaxForBody() throws {
    let fixture = try makeFixture(siteKind: .zola)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write("theme = \"paper\"\n", at: fixture.root.appendingPathComponent("zola.toml"))
    try write(
      "{% component ui.button(label: string) %}{{ label }}{% endcomponent %}",
      at: fixture.root.appendingPathComponent("themes/paper/templates/base.html")
    )
    try write(
      "{% component ui.button(title: string) %}{{ title }}{% endcomponent %}\n{% component ui.forms.widget(title: string) %}<section>{{ body }}</section>{% endcomponent %}",
      at: fixture.root.appendingPathComponent("templates/page.html")
    )

    let catalog = service.catalog(profile: fixture.profile)

    let button = try XCTUnwrap(catalog.definitions.first { $0.name == "ui.button" })
    XCTAssertEqual(button.parameters, [ThemeShortcodeParameter(name: "title")])
    XCTAssertEqual(button.repositoryPath, "templates/page.html")
    let widget = try XCTUnwrap(catalog.definitions.first { $0.name == "ui.forms.widget" })
    XCTAssertTrue(widget.supportsInnerContent)
    XCTAssertEqual(
      widget.insertionTemplate,
      "{% <ui.forms.widget title=\"value\"> %}\n\n{% </ui.forms.widget> %}"
    )
  }

  func testRejectsSymbolicLinkShortcodeDirectory() throws {
    let fixture = try makeFixture(siteKind: .zola)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outside = try temporaryDirectory(named: "shortcode-outside")
    defer { try? FileManager.default.removeItem(at: outside) }
    try write("{{ secret }}", at: outside.appendingPathComponent("secret.html"))
    let link = fixture.root.appendingPathComponent("templates/shortcodes")
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let catalog = service.catalog(profile: fixture.profile)

    XCTAssertTrue(catalog.definitions.isEmpty)
    XCTAssertTrue(catalog.diagnostics.contains { $0.code == .unsafePath })
  }

  func testReportsMissingConfiguredThemeAndUnavailableRepository() throws {
    let fixture = try makeFixture(siteKind: .hugo)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write("theme = \"missing\"\n", at: fixture.root.appendingPathComponent("hugo.toml"))

    let missingTheme = service.catalog(profile: fixture.profile)
    XCTAssertTrue(missingTheme.diagnostics.contains { $0.code == .selectedThemeUnavailable })

    let unavailable = service.catalog(
      profile: SiteProfile(
        name: "Unavailable", siteKind: .zola,
        localRepositoryRootPath: "/tmp/no-such-theme-catalog-\(UUID().uuidString)")
    )
    XCTAssertTrue(unavailable.diagnostics.contains { $0.code == .repositoryUnavailable })
  }

  private func makeFixture(siteKind: SiteKind) throws -> (root: URL, profile: SiteProfile) {
    let root = try temporaryDirectory(named: "theme-shortcodes")
    return (
      root,
      SiteProfile(name: "Theme fixture", siteKind: siteKind, localRepositoryRootPath: root.path)
    )
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ contents: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}

final class ThemeShortcodeCatalogCacheTests: XCTestCase {
  func testZolaWithoutConfigInvalidatesComponentsOutsideLegacyDirectory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var profile = fixture.profile
    profile.siteKind = .zola
    let template = fixture.root.appendingPathComponent("templates/components.html")
    try write("{% component ui.card(title: string) %}{% endcomponent %}", at: template)
    XCTAssertEqual(
      ThemeShortcodeCatalogService().catalog(profile: profile).definitions.map(\.name), ["ui.card"])

    try write("{% component ui.panel(title: string) %}{% endcomponent %}", at: template)
    XCTAssertEqual(
      ThemeShortcodeCatalogService().catalog(profile: profile).definitions.map(\.name), ["ui.panel"]
    )
  }

  override func setUp() {
    super.setUp()
    ThemeShortcodeCatalogService.resetCacheForTesting()
  }

  override func tearDown() {
    ThemeShortcodeCatalogService.resetCacheForTesting()
    super.tearDown()
  }

  func testNewServiceInstanceReusesStableCatalogWithoutAnotherScan() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write(
      "{{ .Get \"title\" }}",
      at: fixture.root.appendingPathComponent("layouts/_shortcodes/card.html"))

    XCTAssertEqual(catalog(for: fixture).definitions.map(\.name), ["card"])
    let afterFirstScan = ThemeShortcodeCatalogService.cacheStatistics
    XCTAssertEqual(catalog(for: fixture).definitions.map(\.name), ["card"])
    let afterSecondScan = ThemeShortcodeCatalogService.cacheStatistics

    XCTAssertEqual(afterFirstScan.insertCount, 1)
    XCTAssertEqual(afterSecondScan.insertCount, 1)
    XCTAssertEqual(afterSecondScan.hitCount, 1)
  }

  func testInPlaceTemplateEditInvalidatesCachedCatalog() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let template = fixture.root.appendingPathComponent("layouts/_shortcodes/card.html")
    try write("{{ .Get \"old\" }}", at: template)

    XCTAssertEqual(catalog(for: fixture).definitions[0].parameters.map(\.name), ["old"])
    let handle = try FileHandle(forWritingTo: template)
    defer { try? handle.close() }
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data("{{ .Get \"new\" }}".utf8))
    try handle.synchronize()

    XCTAssertEqual(catalog(for: fixture).definitions[0].parameters.map(\.name), ["new"])
    XCTAssertEqual(ThemeShortcodeCatalogService.cacheStatistics.insertCount, 2)
  }

  func testAddDeleteAndConfiguredThemeChangeInvalidateInputs() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let rootShortcodes = fixture.root.appendingPathComponent("layouts/_shortcodes")
    try write("{{ .Get \"value\" }}", at: rootShortcodes.appendingPathComponent("first.html"))

    XCTAssertEqual(catalog(for: fixture).definitions.map(\.name), ["first"])
    try write("{{ .Get \"value\" }}", at: rootShortcodes.appendingPathComponent("second.html"))
    XCTAssertEqual(catalog(for: fixture).definitions.map(\.name), ["first", "second"])
    try FileManager.default.removeItem(at: rootShortcodes.appendingPathComponent("second.html"))
    XCTAssertEqual(catalog(for: fixture).definitions.map(\.name), ["first"])

    try write("theme = \"one\"\n", at: fixture.root.appendingPathComponent("hugo.toml"))
    try write(
      "{{ .Get \"one\" }}",
      at: fixture.root.appendingPathComponent("themes/one/layouts/_shortcodes/theme.html"))
    try write(
      "{{ .Get \"two\" }}",
      at: fixture.root.appendingPathComponent("themes/two/layouts/_shortcodes/theme.html"))
    XCTAssertEqual(catalog(for: fixture).selectedThemeName, "one")
    try write("theme = \"two\"\n", at: fixture.root.appendingPathComponent("hugo.toml"))
    XCTAssertEqual(catalog(for: fixture).selectedThemeName, "two")
  }

  func testRepositoryPathsRemainIsolated() throws {
    let first = try makeFixture()
    let second = try makeFixture()
    defer {
      try? FileManager.default.removeItem(at: first.root)
      try? FileManager.default.removeItem(at: second.root)
    }
    try write(
      "{{ .Get \"first\" }}",
      at: first.root.appendingPathComponent("layouts/_shortcodes/card.html"))
    try write(
      "{{ .Get \"second\" }}",
      at: second.root.appendingPathComponent("layouts/_shortcodes/card.html"))

    XCTAssertEqual(catalog(for: first).definitions[0].parameters.map(\.name), ["first"])
    XCTAssertEqual(catalog(for: second).definitions[0].parameters.map(\.name), ["second"])
    XCTAssertEqual(ThemeShortcodeCatalogService.cacheStatistics.entryCount, 2)
  }

  func testIntermediateDirectorySymbolicLinkDoesNotFingerprintOutsideTemplates() throws {
    let fixture = try makeFixture()
    let outside = try temporaryDirectory(named: "theme-shortcode-cache-outside")
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      try? FileManager.default.removeItem(at: outside)
    }
    try write("{{ .Get \"outside\" }}", at: outside.appendingPathComponent("_shortcodes/card.html"))
    let layouts = fixture.root.appendingPathComponent("layouts")
    try FileManager.default.createSymbolicLink(at: layouts, withDestinationURL: outside)

    let keyBefore = try XCTUnwrap(
      ThemeShortcodeCatalogCacheKey.make(rootURL: fixture.root, siteKind: .hugo))
    try write("{{ .Get \"changed\" }}", at: outside.appendingPathComponent("_shortcodes/card.html"))
    let keyAfterOutsideEdit = try XCTUnwrap(
      ThemeShortcodeCatalogCacheKey.make(rootURL: fixture.root, siteKind: .hugo))
    XCTAssertEqual(keyBefore, keyAfterOutsideEdit)

    try FileManager.default.removeItem(at: layouts)
    try write("{{ .Get \"inside\" }}", at: layouts.appendingPathComponent("_shortcodes/card.html"))
    let keyAfterRestoringDirectory = try XCTUnwrap(
      ThemeShortcodeCatalogCacheKey.make(rootURL: fixture.root, siteKind: .hugo))
    XCTAssertNotEqual(keyBefore, keyAfterRestoringDirectory)
  }

  func testCapacityEvictsLeastRecentlyUsedCatalog() throws {
    let cache = ThemeShortcodeCatalogCache(maximumEntryCount: 2)
    let first = try temporaryDirectory(named: "theme-shortcode-cache-lru")
    let second = try temporaryDirectory(named: "theme-shortcode-cache-lru")
    let third = try temporaryDirectory(named: "theme-shortcode-cache-lru")
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
      try? FileManager.default.removeItem(at: third)
    }
    let firstKey = try XCTUnwrap(
      ThemeShortcodeCatalogCacheKey.make(rootURL: first, siteKind: .hugo))
    let secondKey = try XCTUnwrap(
      ThemeShortcodeCatalogCacheKey.make(rootURL: second, siteKind: .hugo))
    let thirdKey = try XCTUnwrap(
      ThemeShortcodeCatalogCacheKey.make(rootURL: third, siteKind: .hugo))

    cache.insert(ThemeShortcodeCatalog(), for: firstKey)
    cache.insert(ThemeShortcodeCatalog(), for: secondKey)
    XCTAssertNotNil(cache.lookup(firstKey))
    cache.insert(ThemeShortcodeCatalog(), for: thirdKey)

    XCTAssertNotNil(cache.lookup(firstKey))
    XCTAssertNil(cache.lookup(secondKey))
    XCTAssertNotNil(cache.lookup(thirdKey))
    XCTAssertEqual(cache.statistics.entryCount, 2)
  }

  private func makeFixture() throws -> (root: URL, profile: SiteProfile) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("theme-shortcode-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (
      root,
      SiteProfile(name: "Theme cache fixture", siteKind: .hugo, localRepositoryRootPath: root.path)
    )
  }

  private func catalog(for fixture: (root: URL, profile: SiteProfile)) -> ThemeShortcodeCatalog {
    ThemeShortcodeCatalogService().catalog(profile: fixture.profile)
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ contents: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}
