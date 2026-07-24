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
    let plan = LocalSitePreviewPlan(
      siteKind: .zola,
      rootPath: FileManager.default.temporaryDirectory.path,
      executablePath: "/bin/sleep",
      arguments: ["5"],
      command: "sleep 5",
      previewURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1111")),
      notes: []
    )

    let started = try service.start(plan: plan)
    XCTAssertTrue(started.isRunning)
    XCTAssertNotNil(started.processIdentifier)
    XCTAssertEqual(started.previewURL?.absoluteString, "http://127.0.0.1:1111")

    service.stop()
    XCTAssertFalse(service.status.isRunning)
#if canImport(Darwin)
    XCTAssertEqual(Darwin.kill(try XCTUnwrap(started.processIdentifier), 0), -1)
    XCTAssertEqual(errno, ESRCH)
#endif
  }

  func testPreviewProcessServiceStopsAsynchronously() async throws {
    let service = LocalSitePreviewProcessService()
    let plan = LocalSitePreviewPlan(
      siteKind: .zola,
      rootPath: FileManager.default.temporaryDirectory.path,
      executablePath: "/bin/sleep",
      arguments: ["5"],
      command: "sleep 5",
      previewURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1111")),
      notes: []
    )

    let started = try service.start(plan: plan)
    await service.stopAsync()

    XCTAssertFalse(service.status.isRunning)
#if canImport(Darwin)
    XCTAssertEqual(Darwin.kill(try XCTUnwrap(started.processIdentifier), 0), -1)
    XCTAssertEqual(errno, ESRCH)
#endif
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
}
