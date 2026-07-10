import XCTest
@testable import PublishingWorkbenchCore

final class SiteStarterServiceTests: XCTestCase {
  func testBuiltInTemplatesCoverSupportedSiteKindsAndPreviewMetadata() {
    XCTAssertEqual(SiteStarterTemplate.builtIn.count, 6)
    XCTAssertTrue(Set(SiteStarterTemplate.builtIn.map(\.siteKind)).isSuperset(of: Set(SiteKind.allCases)))
    XCTAssertEqual(Set(SiteStarterTemplate.builtIn.map(\.id)).count, SiteStarterTemplate.builtIn.count)

    for template in SiteStarterTemplate.builtIn {
      XCTAssertFalse(template.preview.headline.isEmpty)
      XCTAssertFalse(template.preview.sampleItems.isEmpty)
    }
  }

  func testCreatesZolaStarterWithGitHubPagesWorkflowAndRemote() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let result = try SiteStarterService().createSite(
      request: SiteStarterRequest(
        templateID: .zolaPersonalBlog,
        rootPath: rootURL.path,
        siteName: "工程笔记",
        siteDescription: "记录工程和写作。",
        author: "Jinfang",
        baseURL: "",
        branch: "main",
        githubOwner: "lldynamics",
        githubRepositoryName: "engineering-notes",
        deploymentTarget: .githubPages,
        initializeGit: true,
        configureOriginRemote: true,
        now: fixedDate
      )
    )

    XCTAssertEqual(result.profile.siteKind, .zola)
    XCTAssertEqual(result.profile.name, "工程笔记")
    XCTAssertEqual(result.profile.repoOwner, "lldynamics")
    XCTAssertEqual(result.profile.repoName, "engineering-notes")
    XCTAssertEqual(result.profile.branch, "main")
    XCTAssertEqual(result.initialDraft.repositoryPath, "content/posts/2026/welcome.md")
    XCTAssertTrue(result.createdFilePaths.contains("config.toml"))
    XCTAssertTrue(result.createdFilePaths.contains(".github/workflows/pages.yml"))
    XCTAssertEqual(result.deploymentGuidePath, "DEPLOYMENT.md")
    XCTAssertEqual(result.configuredRemoteURL, "git@github.com:lldynamics/engineering-notes.git")
    XCTAssertEqual(try git(["branch", "--show-current"], rootURL: rootURL), "main")
    XCTAssertEqual(try git(["remote", "get-url", "origin"], rootURL: rootURL), "git@github.com:lldynamics/engineering-notes.git")

    let config = try read("config.toml", rootURL: rootURL)
    XCTAssertTrue(config.contains("title = \"工程笔记\""))
    XCTAssertTrue(config.contains("base_url = \"https://lldynamics.github.io/engineering-notes\""))

    let workflow = try read(".github/workflows/pages.yml", rootURL: rootURL)
    XCTAssertTrue(workflow.contains("zola build"))
    XCTAssertTrue(workflow.contains("actions/deploy-pages@v4"))

    let article = try read("content/posts/2026/welcome.md", rootURL: rootURL)
    XCTAssertTrue(article.contains("欢迎来到 工程笔记"))
    XCTAssertTrue(article.contains("由 Site Starter 生成的第一篇内容。"))
  }

  func testCreatesJekyllStarterWithoutGitWhenDisabled() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let result = try SiteStarterService().createSite(
      request: SiteStarterRequest(
        templateID: .jekyllPersonalBlog,
        rootPath: rootURL.path,
        siteName: "个人网站",
        siteDescription: "我的公开主页。",
        author: "Jinfang",
        branch: "main",
        deploymentTarget: .githubPages,
        initializeGit: false,
        configureOriginRemote: false,
        now: fixedDate
      )
    )

    XCTAssertEqual(result.profile.siteKind, .jekyll)
    XCTAssertEqual(result.profile.frontMatterStyle, .yaml)
    XCTAssertEqual(result.initialDraft.repositoryPath, "_posts/2026-07-06-welcome.md")
    XCTAssertFalse(result.initializedGit)
    XCTAssertNil(result.configuredRemoteURL)
    XCTAssertTrue(result.createdFilePaths.contains("_config.yml"))
    XCTAssertTrue(result.createdFilePaths.contains("Gemfile"))
    XCTAssertTrue(result.createdFilePaths.contains(".github/workflows/pages.yml"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(".git").path))

    let workflow = try read(".github/workflows/pages.yml", rootURL: rootURL)
    XCTAssertTrue(workflow.contains("actions/jekyll-build-pages@v1"))

    let post = try read("_posts/2026-07-06-welcome.md", rootURL: rootURL)
    XCTAssertTrue(post.contains("title: \"欢迎来到 个人网站\""))
    XCTAssertTrue(post.contains("欢迎来到 个人网站"))
  }

  func testCreatesAstroStarterWithNetlifyConfiguration() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let result = try SiteStarterService().createSite(
      request: SiteStarterRequest(
        templateID: .astroPersonalBlog,
        rootPath: rootURL.path,
        siteName: "Astro Notes",
        baseURL: "https://example.net",
        deploymentTarget: .netlify,
        deploymentProjectID: "site-id",
        initializeGit: false,
        configureOriginRemote: false,
        now: fixedDate
      )
    )

    XCTAssertEqual(result.profile.siteKind, .astro)
    XCTAssertEqual(result.profile.deploymentProvider, .netlify)
    XCTAssertEqual(result.profile.deploymentSiteURL, "https://example.net")
    XCTAssertEqual(result.profile.deploymentProjectID, "site-id")
    XCTAssertTrue(result.createdFilePaths.contains("package.json"))
    XCTAssertTrue(result.createdFilePaths.contains("astro.config.mjs"))
    XCTAssertTrue(result.createdFilePaths.contains("netlify.toml"))
    XCTAssertTrue(try read("netlify.toml", rootURL: rootURL).contains("publish = \"dist\""))
  }

  func testCreatesHugoStarterWithVercelConfiguration() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let result = try SiteStarterService().createSite(
      request: SiteStarterRequest(
        templateID: .hugoPersonalBlog,
        rootPath: rootURL.path,
        siteName: "Hugo Notes",
        deploymentTarget: .vercel,
        deploymentProjectID: "prj_123",
        deploymentAccountID: "team_123",
        initializeGit: false,
        configureOriginRemote: false,
        now: fixedDate
      )
    )

    XCTAssertEqual(result.profile.siteKind, .hugo)
    XCTAssertEqual(result.profile.deploymentProvider, .vercel)
    XCTAssertEqual(result.profile.deploymentProjectID, "prj_123")
    XCTAssertEqual(result.profile.deploymentAccountID, "team_123")
    XCTAssertTrue(result.createdFilePaths.contains("hugo.toml"))
    XCTAssertTrue(result.createdFilePaths.contains("vercel.json"))
    XCTAssertTrue(try read("vercel.json", rootURL: rootURL).contains("\"outputDirectory\": \"public\""))
  }

  func testCreatesHexoStarterWithCloudflarePagesConfiguration() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let result = try SiteStarterService().createSite(
      request: SiteStarterRequest(
        templateID: .hexoPersonalBlog,
        rootPath: rootURL.path,
        siteName: "Hexo Notes",
        deploymentTarget: .cloudflarePages,
        deploymentProjectID: "hexo-notes",
        deploymentAccountID: "account-123",
        initializeGit: false,
        configureOriginRemote: false,
        now: fixedDate
      )
    )

    XCTAssertEqual(result.profile.siteKind, .hexo)
    XCTAssertEqual(result.profile.deploymentProvider, .cloudflarePages)
    XCTAssertEqual(result.profile.deploymentProjectID, "hexo-notes")
    XCTAssertEqual(result.profile.deploymentAccountID, "account-123")
    XCTAssertTrue(result.createdFilePaths.contains("package.json"))
    XCTAssertTrue(result.createdFilePaths.contains("wrangler.toml"))
    XCTAssertTrue(try read("wrangler.toml", rootURL: rootURL).contains("pages_build_output_dir = \"public\""))
  }

  @MainActor
  func testStoreImportsExistingRepositoryProfileAndDrafts() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts/2026", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    +++
    title = "Imported Starter"
    date = "2026-07-06"
    +++

    Imported body.
    """.write(
      to: rootURL.appendingPathComponent("content/posts/2026/imported.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "git@github.com:lldynamics/imported-site.git"], rootURL: rootURL)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let result = try XCTUnwrap(
      store.importExistingSiteFromStarter(
        SiteStarterImportRequest(
          rootPath: rootURL.path,
          siteName: "Imported Site",
          siteKind: .zola,
          deploymentTarget: .githubPages
        )
      )
    )

    XCTAssertEqual(result.profile.name, "Imported Site")
    XCTAssertEqual(result.profile.repoOwner, "lldynamics")
    XCTAssertEqual(result.profile.repoName, "imported-site")
    XCTAssertEqual(result.profile.branch, "main")
    XCTAssertEqual(result.importedDraftCount, 1)
    XCTAssertEqual(result.skippedPathCount, 0)
    XCTAssertEqual(store.activeProfileID, result.profile.id)
    XCTAssertEqual(store.visibleDrafts.map(\.title), ["Imported Starter"])
    XCTAssertEqual(store.siteStarterImportResult?.importedDraftCount, 1)
  }

  func testRejectsNonEmptyTargetDirectory() throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try "existing\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try SiteStarterService().createSite(
        request: SiteStarterRequest(rootPath: rootURL.path, siteName: "Existing")
      )
    ) { error in
      guard case .rootDirectoryNotEmpty = error as? SiteStarterError else {
        XCTFail("Expected rootDirectoryNotEmpty")
        return
      }
    }
  }

  func testCommitsAndPushesStarterSiteToConfiguredOrigin() throws {
    let rootURL = try temporaryDirectoryURL()
    let remoteURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: remoteURL)
    }

    try git(["init", "--bare"], rootURL: remoteURL)
    let service = SiteStarterService()
    let starter = try service.createSite(
      request: SiteStarterRequest(
        templateID: .zolaPortfolio,
        rootPath: rootURL.path,
        siteName: "作品集",
        branch: "main",
        deploymentTarget: .githubPages,
        initializeGit: true,
        configureOriginRemote: false,
        now: fixedDate
      )
    )
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try git(["remote", "add", "origin", remoteURL.path], rootURL: rootURL)

    let result = try service.commitAndPushStarterSite(profile: starter.profile)

    XCTAssertEqual(result.branch, "main")
    XCTAssertEqual(result.remoteURL, remoteURL.path)
    XCTAssertTrue(result.committedPaths.contains("config.toml"))
    XCTAssertTrue(result.committedPaths.contains(".github/workflows/pages.yml"))
    XCTAssertFalse(result.commitSHA.isEmpty)
    XCTAssertEqual(try git(["rev-parse", "main"], rootURL: remoteURL), result.commitSHA)
    XCTAssertTrue(try git(["ls-tree", "--name-only", "main"], rootURL: remoteURL).contains("config.toml"))
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: rootURL), "")
  }

  private var fixedDate: Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = 2026
    components.month = 7
    components.day = 6
    components.hour = 12
    return components.date!
  }

  private func temporaryDirectoryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SiteStarterServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SiteStarterServiceTests-Persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("Workbench.json")
  }

  private func read(_ path: String, rootURL: URL) throws -> String {
    try String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "SiteStarterServiceTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
