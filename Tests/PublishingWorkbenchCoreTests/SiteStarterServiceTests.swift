import XCTest
@testable import PublishingWorkbenchCore

final class SiteStarterServiceTests: XCTestCase {
  func testBuiltInTemplatesCoverSupportedSiteKindsAndPreviewMetadata() {
    XCTAssertEqual(SiteStarterTemplate.builtIn.count, 1)
    XCTAssertEqual(SiteStarterTemplate.builtIn.first?.id, .zolaPersonalBlog)
    XCTAssertEqual(SiteStarterTemplate.builtIn.first?.siteKind, .zola)
    XCTAssertEqual(Set(SiteStarterTemplate.builtIn.map(\.id)).count, SiteStarterTemplate.builtIn.count)

    for template in SiteStarterTemplate.builtIn {
      XCTAssertFalse(template.preview.headline.isEmpty)
      XCTAssertFalse(template.preview.sampleItems.isEmpty)
    }
  }

  func testLegacyTemplateIDsDecodeToTheMaintainedZolaStarter() throws {
    for legacyID in ["zolaPortfolio", "astroPersonalBlog", "hugoPersonalBlog", "hexoPersonalBlog", "jekyllPersonalBlog"] {
      let decoded = try JSONDecoder().decode(
        SiteStarterTemplateID.self,
        from: Data("\"\(legacyID)\"".utf8)
      )
      XCTAssertEqual(decoded, .zolaPersonalBlog, legacyID)
    }

    let encoded = try JSONEncoder().encode(SiteStarterTemplateID.zolaPersonalBlog)
    XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"zolaPersonalBlog\"")
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

    let readme = try read("README.md", rootURL: rootURL)
    XCTAssertTrue(readme.contains("git clone <主题仓库地址> <本地站点目录>"))

    let article = try read("content/posts/2026/welcome.md", rootURL: rootURL)
    XCTAssertTrue(article.contains("欢迎来到 工程笔记"))
    XCTAssertTrue(article.contains("由 Site Starter 生成的第一篇内容。"))
  }

  func testConfiguresGitHubOriginAfterStarterGeneration() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = SiteStarterService()
    let result = try service.createSite(
      request: SiteStarterRequest(
        templateID: .zolaPersonalBlog,
        rootPath: rootURL.path,
        siteName: "Deferred Remote",
        branch: "main",
        initializeGit: true,
        configureOriginRemote: false,
        now: fixedDate
      )
    )
    var configuredProfile = result.profile
    configuredProfile.repoOwner = "lldynamics"
    configuredProfile.repoName = "deferred-remote"

    let remoteURL = try await service.configureGitHubOriginRemoteAsync(profile: configuredProfile)

    XCTAssertEqual(remoteURL, "git@github.com:lldynamics/deferred-remote.git")
    XCTAssertEqual(
      try git(["remote", "get-url", "origin"], rootURL: rootURL),
      "git@github.com:lldynamics/deferred-remote.git"
    )
  }

  func testImportSanitizesCredentialedOriginRemote() throws {
    let rootURL = try temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(
      [
        "remote",
        "add",
        "origin",
        "https://alice:remote-secret@github.com/lldynamics/imported-site.git?token=url-token",
      ],
      rootURL: rootURL
    )

    let result = try SiteStarterService().importExistingSite(
      request: SiteStarterImportRequest(
        rootPath: rootURL.path,
        siteName: "Imported Site",
        siteKind: .zola
      )
    )

    XCTAssertEqual(
      result.detectedRemoteURL,
      "https://github.com/lldynamics/imported-site.git"
    )
    XCTAssertEqual(result.profile.repoOwner, "lldynamics")
    XCTAssertEqual(result.profile.repoName, "imported-site")
    XCTAssertFalse(result.detectedRemoteURL?.contains("alice") == true)
    XCTAssertFalse(result.detectedRemoteURL?.contains("remote-secret") == true)
    XCTAssertFalse(result.detectedRemoteURL?.contains("url-token") == true)
  }

  func testImportKeepsEveryExistingSiteKindIndependentFromStarterTemplates() throws {
    for siteKind in SiteKind.allCases {
      let rootURL = try temporaryDirectoryURL()
      defer { try? FileManager.default.removeItem(at: rootURL) }

      let result = try SiteStarterService().importExistingSite(
        request: SiteStarterImportRequest(
          rootPath: rootURL.path,
          siteName: "Imported \(siteKind.displayName)",
          siteKind: siteKind
        )
      )

      XCTAssertEqual(result.profile.siteKind, siteKind)
      XCTAssertEqual(result.profile.localRepositoryRootPath, rootURL.path)
    }
  }

  @MainActor
  func testStoreImportsExistingRepositoryProfileAndDrafts() async throws {
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
    let importedResult = await store.importExistingSiteFromStarter(
      SiteStarterImportRequest(
        rootPath: rootURL.path,
        siteName: "Imported Site",
        siteKind: .zola,
        deploymentTarget: .githubPages
      )
    )
    let result = try XCTUnwrap(importedResult)

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

  @MainActor
  func testBackgroundCreateKeepsMainActorResponsiveAndOlderResultCannotReplaceNewerState() async throws {
    let blocker = SiteStarterBlockingGate()
    let mainActorProbe = SiteStarterBlockingGate()
    let service = SiteStarterService(createSiteOperation: { request in
      if request.siteName == "Older Site" {
        blocker.startAndBlock()
      }
      return stubSiteStarterResult(for: request)
    })
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      siteStarterService: service
    )
    let olderRequest = SiteStarterRequest(
      rootPath: "/tmp/older-site",
      siteName: "Older Site",
      initializeGit: false,
      configureOriginRemote: false
    )
    let newerRequest = SiteStarterRequest(
      rootPath: "/tmp/newer-site",
      siteName: "Newer Site",
      initializeGit: false,
      configureOriginRemote: false
    )

    let olderTask = Task { @MainActor in
      await store.createSiteFromStarter(olderRequest)
    }
    let probeScheduler = Task.detached {
      guard blocker.waitUntilStarted(timeout: 2) else { return }
      await MainActor.run {
        mainActorProbe.signal()
      }
    }
    let watchdog = Task.detached {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      blocker.signal()
    }

    let mainActorResponded = await Task.detached {
      mainActorProbe.waitUntilStarted(timeout: 0.5)
    }.value
    XCTAssertTrue(mainActorResponded, "Starter file work must not block the main actor")
    XCTAssertTrue(store.isSiteStarterOperationRunning)

    let newerResult = await store.createSiteFromStarter(newerRequest)
    XCTAssertEqual(newerResult?.profile.name, "Newer Site")
    XCTAssertEqual(store.activeProfile.name, "Newer Site")

    blocker.signal()
    watchdog.cancel()
    await probeScheduler.value
    let olderResult = await olderTask.value

    XCTAssertNil(olderResult)
    XCTAssertEqual(store.activeProfile.name, "Newer Site")
    XCTAssertEqual(store.siteStarterResult?.profile.name, "Newer Site")
    XCTAssertFalse(store.profiles.contains { $0.name == "Older Site" })
    XCTAssertFalse(store.isSiteStarterOperationRunning)
  }

  @MainActor
  func testBackgroundCreatePreservesWorkspaceChangesMadeAfterOperationStarts() async throws {
    let blocker = SiteStarterBlockingGate()
    let service = SiteStarterService(createSiteOperation: { request in
      blocker.startAndBlock()
      return stubSiteStarterResult(for: request)
    })
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      siteStarterService: service
    )
    let initialProfileCount = store.profiles.count
    let operation = Task { @MainActor in
      await store.createSiteFromStarter(
        SiteStarterRequest(
          rootPath: "/tmp/baseline-site",
          siteName: "Baseline Site",
          initializeGit: false,
          configureOriginRemote: false
        )
      )
    }

    let didStart = await Task.detached {
      blocker.waitUntilStarted(timeout: 2)
    }.value
    XCTAssertTrue(didStart)
    var editedProfile = store.activeProfile
    editedProfile.name = "User Edited Profile"
    store.updateActiveProfile(editedProfile)

    blocker.signal()
    let result = await operation.value

    XCTAssertNil(result)
    XCTAssertEqual(store.activeProfile.name, "User Edited Profile")
    XCTAssertEqual(store.profiles.count, initialProfileCount)
    XCTAssertNil(store.siteStarterResult)
    XCTAssertFalse(store.isSiteStarterOperationRunning)
    XCTAssertEqual(
      store.publishActionMessage,
      "Starter 文件已生成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
    )
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
        templateID: .zolaPersonalBlog,
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
    try "LOCAL_SECRET=do-not-commit\n".write(
      to: rootURL.appendingPathComponent(".env"),
      atomically: true,
      encoding: .utf8
    )

    let result = try service.commitAndPushStarterSite(
      profile: starter.profile,
      createdFilePaths: starter.createdFilePaths
    )

    XCTAssertEqual(result.branch, "main")
    XCTAssertEqual(result.remoteURL, remoteURL.path)
    XCTAssertTrue(result.committedPaths.contains("config.toml"))
    XCTAssertTrue(result.committedPaths.contains(".github/workflows/pages.yml"))
    XCTAssertFalse(result.commitSHA.isEmpty)
    XCTAssertEqual(try git(["rev-parse", "main"], rootURL: remoteURL), result.commitSHA)
    XCTAssertTrue(try git(["ls-tree", "--name-only", "main"], rootURL: remoteURL).contains("config.toml"))
    XCTAssertFalse(try git(["ls-tree", "--name-only", "main"], rootURL: remoteURL).contains(".env"))
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: rootURL), "?? .env")
  }

  func testCommitAndPushRejectsUnrelatedPreStagedChanges() throws {
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
        rootPath: rootURL.path,
        siteName: "Safe Starter",
        initializeGit: true,
        configureOriginRemote: false,
        now: fixedDate
      )
    )
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try git(["remote", "add", "origin", remoteURL.path], rootURL: rootURL)
    try "TOKEN=secret\n".write(
      to: rootURL.appendingPathComponent(".env"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "--", ".env"], rootURL: rootURL)

    XCTAssertThrowsError(
      try service.commitAndPushStarterSite(
        profile: starter.profile,
        createdFilePaths: starter.createdFilePaths
      )
    ) { error in
      XCTAssertEqual(error as? SiteStarterError, .unrelatedStagedChanges([".env"]))
    }
    XCTAssertEqual(try git(["diff", "--cached", "--name-only"], rootURL: rootURL), ".env")
    XCTAssertThrowsError(try git(["rev-parse", "main"], rootURL: remoteURL))
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

private func stubSiteStarterResult(for request: SiteStarterRequest) -> SiteStarterResult {
  let profile = SiteProfile(
    name: request.siteName,
    localRepositoryRootPath: request.rootPath,
    branch: request.branch
  )
  let draft = ArticleDraft(
    siteProfileID: profile.id,
    title: "\(request.siteName) Draft",
    slug: request.siteName.lowercased().replacingOccurrences(of: " ", with: "-")
  )
  return SiteStarterResult(
    profile: profile,
    initialDraft: draft,
    createdFilePaths: ["config.toml"],
    initializedGit: request.initializeGit,
    configuredRemoteURL: nil,
    deploymentGuidePath: nil,
    nextCommands: []
  )
}

private final class SiteStarterBlockingGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var released = false

  func startAndBlock() {
    condition.lock()
    started = true
    condition.broadcast()
    let deadline = Date().addingTimeInterval(5)
    while !released, condition.wait(until: deadline) {}
    condition.unlock()
  }

  func signal() {
    condition.lock()
    started = true
    released = true
    condition.broadcast()
    condition.unlock()
  }

  func waitUntilStarted(timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while !started {
      guard condition.wait(until: deadline) else { return started }
    }
    return true
  }
}
