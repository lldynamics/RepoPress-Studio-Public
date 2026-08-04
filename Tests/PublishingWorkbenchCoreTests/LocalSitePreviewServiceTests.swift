import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import PublishingWorkbenchCore

final class LocalSitePreviewServiceTests: XCTestCase {
  func testZolaPreviewPlanUsesDraftServeCommand() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = "/tmp/site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/site' && 'zola' 'serve' '--drafts'")
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "zola")
    XCTAssertEqual(plan.arguments, ["serve", "--drafts"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:1111")
  }

  func testAstroPreviewPlanUsesNpmDev() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .astro
    profile.localRepositoryRootPath = "/tmp/astro-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/astro-site' && 'npm' 'run' 'dev'")
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "npm")
    XCTAssertEqual(plan.arguments, ["run", "dev"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:4321")
  }

  func testHugoPreviewPlanUsesDraftServerCommand() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hugo
    profile.localRepositoryRootPath = "/tmp/hugo-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/hugo-site' && 'hugo' 'server' '-D'")
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "hugo")
    XCTAssertEqual(plan.arguments, ["server", "-D"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:1313")
    XCTAssertTrue(plan.notes.contains("包含草稿预览参数 -D。"))
  }

  func testHexoPreviewPlanUsesServerScript() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hexo
    profile.localRepositoryRootPath = "/tmp/hexo-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/hexo-site' && 'npm' 'run' 'server'")
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "npm")
    XCTAssertEqual(plan.arguments, ["run", "server"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:4000")
    XCTAssertTrue(plan.notes.contains("如果没有 server script，可改用 hexo server。"))
  }

  func testJekyllPreviewPlanUsesBundleExecServeWithDrafts() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .jekyll
    profile.localRepositoryRootPath = "/tmp/jekyll-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/jekyll-site' && 'bundle' 'exec' 'jekyll' 'serve' '--drafts'")
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "bundle")
    XCTAssertEqual(plan.arguments, ["exec", "jekyll", "serve", "--drafts"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:4000")
    XCTAssertTrue(plan.notes.contains("需要 Ruby bundle 环境可用。"))
  }

  func testPreviewPlanCopiesRepositoryPathWithSpacesSafely() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = "/tmp/My Site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/My Site' && 'zola' 'serve' '--drafts'")
  }

  func testCurrentArticlePreviewUsesSharedSitePathRules() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .astro
    profile.localRepositoryRootPath = "/tmp/astro-site"
    profile.markdownPathPattern = "src/content/blog/{slug}.md"
    let draft = ArticleDraft(siteProfileID: profile.id, title: "预览文章", slug: "preview-post")

    let previewURL = try XCTUnwrap(LocalSitePreviewService().previewURL(for: draft, profile: profile))

    XCTAssertEqual(previewURL.absoluteString, "http://127.0.0.1:4321/preview-post")
  }

  func testPreviewProcessServiceStartsAndStopsControlledProcess() throws {
    let service = LocalSitePreviewProcessService()
    let plan = try makeSleepPreviewPlan()

    let started = try service.start(plan: plan)
    XCTAssertTrue(started.isRunning)
    XCTAssertNotNil(started.processIdentifier)
    XCTAssertEqual(started.previewURL, plan.previewURL)

    service.stop()
    XCTAssertFalse(service.status.isRunning)
#if canImport(Darwin)
    XCTAssertEqual(Darwin.kill(try XCTUnwrap(started.processIdentifier), 0), -1)
    XCTAssertEqual(errno, ESRCH)
#endif
  }

  func testPreviewProcessServiceStopsAsynchronously() async throws {
    let service = LocalSitePreviewProcessService()
    let plan = try makeSleepPreviewPlan()

    let started = try service.start(plan: plan)
    await service.stopAsync()

    XCTAssertFalse(service.status.isRunning)
#if canImport(Darwin)
    XCTAssertEqual(Darwin.kill(try XCTUnwrap(started.processIdentifier), 0), -1)
    XCTAssertEqual(errno, ESRCH)
#endif
  }

  private func makeSleepPreviewPlan() throws -> LocalSitePreviewPlan {
    return LocalSitePreviewPlan(
      siteKind: .zola,
      rootPath: FileManager.default.temporaryDirectory.path,
      executablePath: "/bin/sleep",
      arguments: ["5"],
      command: "sleep 5",
      previewURL: try XCTUnwrap(URL(string: "http://127.0.0.1")),
      notes: []
    )
  }

  func testPreviewProcessEnvironmentUsesTrustedPathsAndDropsSecrets() {
    let environment = LocalSitePreviewProcessService.launchEnvironment(from: [
      "HOME": "/tmp/home",
      "PATH": "/tmp/untrusted:/usr/bin",
      "OPENAI_API_KEY": "secret",
      "PRIVATE_TOKEN": "secret",
    ])
    let paths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []

    XCTAssertEqual(paths.first, "/opt/homebrew/bin")
    XCTAssertTrue(paths.contains("/usr/local/bin"))
    XCTAssertEqual(paths.filter { $0 == "/usr/bin" }.count, 1)
    XCTAssertEqual(environment["HOME"], "/tmp/home")
    XCTAssertNil(environment["OPENAI_API_KEY"])
    XCTAssertNil(environment["PRIVATE_TOKEN"])
  }

  func testPreviewPlanUsesResolvedAbsoluteExecutable() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = "/tmp/site"
    let service = LocalSitePreviewService { name in "/trusted/tools/\(name)" }

    let plan = try XCTUnwrap(service.plan(profile: profile))

    XCTAssertEqual(plan.executablePath, "/trusted/tools/zola")
    XCTAssertEqual(plan.arguments, ["serve", "--drafts"])
  }

  func testPortAllocatorUsesDynamicPortWhenPreferredPortIsUnavailable() {
    let allocator = LocalSitePreviewPortAllocator(
      isPortAvailable: { $0 == 23_456 },
      dynamicPort: { 23_456 }
    )

    let allocation = allocator.allocate(preferredPort: 1_111)

    XCTAssertEqual(allocation?.port, 23_456)
    XCTAssertEqual(allocation?.usesDynamicPort, true)
  }

  func testDynamicPreviewPlanAddsFrameworkPortArguments() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = "/tmp/site"
    let allocator = LocalSitePreviewPortAllocator(
      isPortAvailable: { $0 == 23_456 },
      dynamicPort: { 23_456 }
    )
    let service = LocalSitePreviewService(
      executableResolver: { name in "/trusted/\(name)" },
      portAllocator: allocator
    )

    let plan = try XCTUnwrap(service.plan(profile: profile))

    XCTAssertTrue(plan.usesDynamicPort)
    XCTAssertEqual(
      plan.arguments,
      ["serve", "--drafts", "--interface", "127.0.0.1", "--port", "23456"]
    )
    XCTAssertEqual(plan.previewURL.port, 23_456)
    XCTAssertTrue(plan.command.contains("'--port' '23456'"))
  }

  func testPreviewPlanUsesRepositoryDetectedKindAndStartupScript() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageJSON = "{\"scripts\":{\"dev\":\"astro dev\"}}"
    try Data(packageJSON.utf8).write(to: rootURL.appendingPathComponent("package.json"))

    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = rootURL.path
    let report = RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: .astro,
      expectedKind: .zola,
      hasGitDirectory: false,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 1,
      imageFileCount: 0,
      changedFiles: [],
      preflightIssues: []
    )
    let allocator = LocalSitePreviewPortAllocator(
      isPortAvailable: { $0 == 4_321 },
      dynamicPort: { 4_321 }
    )
    let service = LocalSitePreviewService(
      executableResolver: { name in "/trusted/\(name)" },
      portAllocator: allocator
    )

    let plan = try XCTUnwrap(service.plan(profile: profile, repositoryReport: report))

    XCTAssertEqual(plan.siteKind, .astro)
    XCTAssertEqual(plan.arguments, ["run", "dev"])
    XCTAssertEqual(plan.previewURL.port, 4_321)
    XCTAssertEqual(plan.diagnostics.detectedSiteKind, .astro)
    XCTAssertEqual(plan.diagnostics.scriptName, "dev")
    XCTAssertTrue(plan.diagnostics.isReadyToStart)
  }

  func testPreviewPlanReportsMissingNodeScriptAndExecutable() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .astro
    profile.localRepositoryRootPath = rootURL.path
    let allocator = LocalSitePreviewPortAllocator(
      isPortAvailable: { $0 == 4_322 },
      dynamicPort: { 4_322 }
    )
    let service = LocalSitePreviewService(
      executableResolver: { _ in nil },
      portAllocator: allocator
    )

    let plan = try XCTUnwrap(service.plan(profile: profile))

    XCTAssertFalse(plan.diagnostics.isReadyToStart)
    XCTAssertTrue(plan.diagnostics.dependencies.contains { $0.status == .missing })
    XCTAssertTrue(plan.diagnostics.dependencies.contains { $0.id == "package-json" })
    XCTAssertTrue(plan.diagnostics.blockingMessages.contains { $0.contains("package.json") })
  }

  func testPreviewFileWatcherIgnoresGeneratedAndDependencyDirectories() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-preview-watcher-\(UUID().uuidString)", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("content", isDirectory: true)
    let nodeModulesURL = rootURL.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModulesURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let changeExpectation = expectation(description: "source change is observed")
    let state = LockedWatcherTestState()
    let watcher = LocalSitePreviewFileWatcher(rootPath: rootURL.path) {
      let shouldFulfill = state.recordChange()
      if shouldFulfill {
        changeExpectation.fulfill()
      }
    }
    watcher.start()
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertLessThanOrEqual(watcher.watchedDirectoryCount, 2)

    try Data("# post".utf8).write(to: sourceURL.appendingPathComponent("post.md"))
    await fulfillment(of: [changeExpectation], timeout: 2)
    let sourceChangeCount = state.changeCount

    try Data("dependency".utf8).write(to: nodeModulesURL.appendingPathComponent("package.js"))
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(state.changeCount, sourceChangeCount)
    watcher.stop()
  }
}

private final class LockedWatcherTestState: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var didFulfill = false

  var changeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func recordChange() -> Bool {
    lock.lock()
    count += 1
    let shouldFulfill = !didFulfill
    didFulfill = true
    lock.unlock()
    return shouldFulfill
  }
}
