import XCTest
@testable import PublishingWorkbenchCore

final class LocalSitePreviewServiceTests: XCTestCase {
  func testZolaPreviewPlanUsesDraftServeCommand() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = "/tmp/site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/site' && 'zola' 'serve' '--drafts'")
    XCTAssertEqual(plan.executablePath, "/usr/bin/env")
    XCTAssertEqual(plan.arguments, ["zola", "serve", "--drafts"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:1111")
  }

  func testAstroPreviewPlanUsesNpmDev() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .astro
    profile.localRepositoryRootPath = "/tmp/astro-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/astro-site' && 'npm' 'run' 'dev'")
    XCTAssertEqual(plan.executablePath, "/usr/bin/env")
    XCTAssertEqual(plan.arguments, ["npm", "run", "dev"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:4321")
  }

  func testHugoPreviewPlanUsesDraftServerCommand() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hugo
    profile.localRepositoryRootPath = "/tmp/hugo-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/hugo-site' && 'hugo' 'server' '-D'")
    XCTAssertEqual(plan.executablePath, "/usr/bin/env")
    XCTAssertEqual(plan.arguments, ["hugo", "server", "-D"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:1313")
    XCTAssertTrue(plan.notes.contains("包含草稿预览参数 -D。"))
  }

  func testHexoPreviewPlanUsesServerScript() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hexo
    profile.localRepositoryRootPath = "/tmp/hexo-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/hexo-site' && 'npm' 'run' 'server'")
    XCTAssertEqual(plan.executablePath, "/usr/bin/env")
    XCTAssertEqual(plan.arguments, ["npm", "run", "server"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:4000")
    XCTAssertTrue(plan.notes.contains("如果没有 server script，可改用 hexo server。"))
  }

  func testJekyllPreviewPlanUsesBundleExecServeWithDrafts() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .jekyll
    profile.localRepositoryRootPath = "/tmp/jekyll-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/jekyll-site' && 'bundle' 'exec' 'jekyll' 'serve' '--drafts'")
    XCTAssertEqual(plan.executablePath, "/usr/bin/env")
    XCTAssertEqual(plan.arguments, ["bundle", "exec", "jekyll", "serve", "--drafts"])
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
  }

  func testPreviewProcessEnvironmentAddsCommonMacToolPaths() {
    let environment = LocalSitePreviewProcessService.launchEnvironment(from: ["PATH": "/usr/bin"])
    let paths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []

    XCTAssertEqual(paths.first, "/usr/bin")
    XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
    XCTAssertTrue(paths.contains("/usr/local/bin"))
    XCTAssertEqual(paths.filter { $0 == "/usr/bin" }.count, 1)
  }
}
