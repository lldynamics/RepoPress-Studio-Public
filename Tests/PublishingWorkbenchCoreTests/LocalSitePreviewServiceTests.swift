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

  func testVitePressPreviewPlanUsesNpmDev() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .vitePress
    profile.localRepositoryRootPath = "/tmp/vitepress-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/vitepress-site' && 'npm' 'run' 'dev'")
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "npm")
    XCTAssertEqual(plan.arguments, ["run", "dev"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:5173")
  }

  func testNextJSPreviewPlanUsesNpmDev() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .nextJS
    profile.localRepositoryRootPath = "/tmp/next-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/next-site' && 'npm' 'run' 'dev'")
    XCTAssertEqual(plan.arguments, ["run", "dev"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:3000")
  }

  func testQuartzPreviewPlanUsesOfficialServeCommand() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .quartz
    profile.localRepositoryRootPath = "/tmp/quartz-site"

    let plan = try XCTUnwrap(LocalSitePreviewService().plan(profile: profile))

    XCTAssertEqual(plan.command, "cd '/tmp/quartz-site' && 'npx' 'quartz' 'build' '--serve'")
    XCTAssertEqual(plan.arguments, ["quartz", "build", "--serve"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:8080")
  }

  func testFoamWorkspaceDoesNotInventAStaticSitePreviewCommand() {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .foam
    profile.localRepositoryRootPath = "/tmp/foam-workspace"

    XCTAssertNil(LocalSitePreviewService().plan(profile: profile))
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
    let trustRootURL = try temporaryDirectory(named: "local-preview-process-trust")
    defer { try? FileManager.default.removeItem(at: trustRootURL) }
    let service = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(
        fileURL: trustRootURL.appendingPathComponent("trust.json")
      )
    )
    let plan = try makeSleepPreviewPlan()

    let request = try XCTUnwrap(service.authorizationRequest(for: plan))
    XCTAssertFalse(service.status.isRunning)
    try service.authorize(plan: plan, matching: request)

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
    let trustRootURL = try temporaryDirectory(named: "local-preview-async-trust")
    defer { try? FileManager.default.removeItem(at: trustRootURL) }
    let service = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(
        fileURL: trustRootURL.appendingPathComponent("trust.json")
      )
    )
    let plan = try makeSleepPreviewPlan()
    let request = try XCTUnwrap(service.authorizationRequest(for: plan))
    try service.authorize(plan: plan, matching: request)

    let started = try service.start(plan: plan)
    await service.stopAsync()

    XCTAssertFalse(service.status.isRunning)
#if canImport(Darwin)
    XCTAssertEqual(Darwin.kill(try XCTUnwrap(started.processIdentifier), 0), -1)
    XCTAssertEqual(errno, ESRCH)
#endif
  }

  func testPreviewAuthorizationPersistsPerProfileAndSurvivesProfileRoundTrip() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-profile-authorization")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let trustFileURL = rootURL.appendingPathComponent("trust.json")
    let profileA = UUID()
    let profileB = UUID()
    let planA = try makeSleepPreviewPlan(profileID: profileA, rootPath: rootURL.path)
    let planB = try makeSleepPreviewPlan(profileID: profileB, rootPath: rootURL.path)

    let firstService = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(fileURL: trustFileURL)
    )
    let requestA = try XCTUnwrap(firstService.authorizationRequest(for: planA))
    try firstService.authorize(plan: planA, matching: requestA)

    let reloadedService = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(fileURL: trustFileURL)
    )
    XCTAssertNil(try reloadedService.authorizationRequest(for: planA))
    let requestB = try XCTUnwrap(reloadedService.authorizationRequest(for: planB))
    try reloadedService.authorize(plan: planB, matching: requestB)

    let roundTripService = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(fileURL: trustFileURL)
    )
    XCTAssertNil(try roundTripService.authorizationRequest(for: planA))
    XCTAssertNil(try roundTripService.authorizationRequest(for: planB))
    let permissions = try FileManager.default.attributesOfItem(atPath: trustFileURL.path)[
      .posixPermissions
    ] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testAuthorizingReplacementRemovesOnlyTheSameProfileAndRootBinding() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-binding-replacement")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let trustStore = LocalSitePreviewTrustStore(
      fileURL: rootURL.appendingPathComponent("trust.json")
    )
    let service = LocalSitePreviewProcessService(trustStore: trustStore)
    let profileID = UUID()
    let originalPlan = try makeSleepPreviewPlan(
      profileID: profileID,
      rootPath: rootURL.path,
      arguments: ["5"]
    )
    let replacementPlan = try makeSleepPreviewPlan(
      profileID: profileID,
      rootPath: rootURL.path,
      arguments: ["6"]
    )
    let originalRequest = try XCTUnwrap(service.authorizationRequest(for: originalPlan))
    try service.authorize(plan: originalPlan, matching: originalRequest)
    let replacementRequest = try XCTUnwrap(service.authorizationRequest(for: replacementPlan))
    try service.authorize(plan: replacementPlan, matching: replacementRequest)

    XCTAssertFalse(trustStore.isAuthorized(try XCTUnwrap(originalPlan.executionIdentity)))
    XCTAssertTrue(trustStore.isAuthorized(try XCTUnwrap(replacementPlan.executionIdentity)))
  }

  func testManifestChangeRevokesThePreviouslyAuthorizedExecutionIdentity() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-manifest-change")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("package.json")
    try Data("{\"scripts\":{\"dev\":\"astro dev\"}}".utf8).write(to: packageURL)
    let trustStore = LocalSitePreviewTrustStore(
      fileURL: rootURL.appendingPathComponent("trust.json")
    )
    let service = LocalSitePreviewProcessService(trustStore: trustStore)
    let plan = try makeSleepPreviewPlan(
      profileID: UUID(),
      rootPath: rootURL.path,
      siteKind: .astro
    )
    let request = try XCTUnwrap(service.authorizationRequest(for: plan))
    try service.authorize(plan: plan, matching: request)

    try Data("{\"scripts\":{\"dev\":\"astro dev --host\"}}".utf8).write(to: packageURL)

    XCTAssertThrowsError(try service.authorizationRequest(for: plan)) { error in
      guard case LocalSitePreviewError.executionPlanChanged = error else {
        return XCTFail("Expected executionPlanChanged, got \(error)")
      }
    }
    XCTAssertFalse(trustStore.isAuthorized(try XCTUnwrap(plan.executionIdentity)))
  }

  func testCorruptUnknownAndOversizedTrustDocumentsFailClosed() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-corrupt-trust")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let trustFileURL = rootURL.appendingPathComponent("trust.json")
    let identity = try XCTUnwrap(
      makeSleepPreviewPlan(profileID: UUID(), rootPath: rootURL.path).executionIdentity
    )
    let trustStore = LocalSitePreviewTrustStore(fileURL: trustFileURL)

    try Data("{".utf8).write(to: trustFileURL)
    XCTAssertFalse(trustStore.isAuthorized(identity))

    try Data("{\"schemaVersion\":999,\"records\":[]}".utf8).write(to: trustFileURL)
    XCTAssertFalse(trustStore.isAuthorized(identity))

    try Data(repeating: 0x41, count: 512 * 1_024 + 1).write(to: trustFileURL)
    XCTAssertFalse(trustStore.isAuthorized(identity))
  }

  func testTrustStoreRejectsSymbolicLinkFileAndContainer() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-symbolic-trust")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let identity = try XCTUnwrap(
      makeSleepPreviewPlan(profileID: UUID(), rootPath: rootURL.path).executionIdentity
    )
    let targetURL = rootURL.appendingPathComponent("target.json")
    try Data("{\"schemaVersion\":1,\"records\":[]}".utf8).write(to: targetURL)
    let fileLinkURL = rootURL.appendingPathComponent("trust-link.json")
    try FileManager.default.createSymbolicLink(at: fileLinkURL, withDestinationURL: targetURL)
    let fileLinkStore = LocalSitePreviewTrustStore(fileURL: fileLinkURL)
    XCTAssertFalse(fileLinkStore.isAuthorized(identity))
    XCTAssertThrowsError(try fileLinkStore.authorize(identity))

    let actualContainerURL = rootURL.appendingPathComponent("actual", isDirectory: true)
    try FileManager.default.createDirectory(at: actualContainerURL, withIntermediateDirectories: true)
    let containerLinkURL = rootURL.appendingPathComponent("container-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: containerLinkURL,
      withDestinationURL: actualContainerURL
    )
    let containerLinkStore = LocalSitePreviewTrustStore(
      fileURL: containerLinkURL.appendingPathComponent("trust.json")
    )
    XCTAssertFalse(containerLinkStore.isAuthorized(identity))
    XCTAssertThrowsError(try containerLinkStore.authorize(identity))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: actualContainerURL.appendingPathComponent("trust.json").path
      )
    )
  }

  func testTrustStoreWriteFailureNeverCreatesAnInMemoryAuthorization() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-write-failure")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let nonDirectoryURL = rootURL.appendingPathComponent("not-a-directory")
    try Data("blocked".utf8).write(to: nonDirectoryURL)
    let trustStore = LocalSitePreviewTrustStore(
      fileURL: nonDirectoryURL.appendingPathComponent("trust.json")
    )
    let identity = try XCTUnwrap(
      makeSleepPreviewPlan(profileID: UUID(), rootPath: rootURL.path).executionIdentity
    )

    XCTAssertThrowsError(try trustStore.authorize(identity)) { error in
      guard case LocalSitePreviewError.authorizationStoreUnavailable = error else {
        return XCTFail("Expected authorizationStoreUnavailable, got \(error)")
      }
    }
    XCTAssertFalse(trustStore.isAuthorized(identity))
  }

  func testRunningProcessRejectsUnauthorizedAndDifferentAuthorizedPlans() throws {
    let rootURL = try temporaryDirectory(named: "local-preview-running-plan")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(
        fileURL: rootURL.appendingPathComponent("trust.json")
      )
    )
    let activePlan = try makeSleepPreviewPlan(
      profileID: UUID(),
      rootPath: rootURL.path,
      arguments: ["5"]
    )
    let differentPlan = try makeSleepPreviewPlan(
      profileID: UUID(),
      rootPath: rootURL.path,
      arguments: ["6"]
    )
    let unauthorizedPlan = try makeSleepPreviewPlan(
      profileID: UUID(),
      rootPath: rootURL.path,
      arguments: ["7"]
    )
    try service.authorize(
      plan: activePlan,
      matching: XCTUnwrap(service.authorizationRequest(for: activePlan))
    )
    try service.authorize(
      plan: differentPlan,
      matching: XCTUnwrap(service.authorizationRequest(for: differentPlan))
    )
    let started = try service.start(plan: activePlan)
    defer { service.stop() }

    XCTAssertThrowsError(try service.start(plan: unauthorizedPlan)) { error in
      guard case LocalSitePreviewError.authorizationRequired = error else {
        return XCTFail("Expected authorizationRequired, got \(error)")
      }
    }
    XCTAssertThrowsError(try service.start(plan: differentPlan)) { error in
      guard case LocalSitePreviewError.executionPlanChanged = error else {
        return XCTFail("Expected executionPlanChanged, got \(error)")
      }
    }
    XCTAssertEqual(service.status.processIdentifier, started.processIdentifier)
    XCTAssertTrue(service.status.isRunning)
  }

  private func makeSleepPreviewPlan(
    profileID: UUID = UUID(),
    rootPath: String = FileManager.default.temporaryDirectory.path,
    arguments: [String] = ["5"],
    siteKind: SiteKind = .zola,
    executablePath: String = "/bin/sleep"
  ) throws -> LocalSitePreviewPlan {
    let command = "\(URL(fileURLWithPath: executablePath).lastPathComponent) "
      + arguments.joined(separator: " ")
    let identity = try LocalSitePreviewExecutionFingerprint.makeIdentity(
      profileID: profileID,
      rootPath: rootPath,
      siteKind: siteKind,
      executablePath: executablePath,
      arguments: arguments,
      command: command
    )
    return LocalSitePreviewPlan(
      siteKind: siteKind,
      rootPath: identity.canonicalRootPath,
      executablePath: executablePath,
      arguments: arguments,
      command: command,
      previewURL: try XCTUnwrap(URL(string: "http://127.0.0.1")),
      notes: [],
      executionIdentity: identity
    )
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testPreviewProcessEnvironmentUsesTrustedPathsAndDropsSecrets() {
    let environment = LocalSitePreviewProcessService.launchEnvironment(from: [
      "HOME": "/tmp/home",
      "PATH": "/tmp/home/.cargo/bin:/usr/bin:/tmp/untrusted:/tmp/home/.bun/bin",
      "OPENAI_API_KEY": "secret",
      "PRIVATE_TOKEN": "secret",
    ])
    let paths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []

    XCTAssertEqual(paths.first, "/tmp/home/.cargo/bin")
    XCTAssertEqual(paths.dropFirst().first, "/usr/bin")
    XCTAssertTrue(paths.contains("/tmp/home/.local/bin"))
    XCTAssertTrue(paths.contains("/tmp/home/.bun/bin"))
    XCTAssertTrue(paths.contains("/tmp/home/.fnm/current/bin"))
    XCTAssertTrue(paths.contains("/tmp/home/.asdf/shims"))
    XCTAssertTrue(paths.contains("/tmp/home/.local/share/mise/shims"))
    XCTAssertTrue(paths.contains("/usr/local/bin"))
    XCTAssertEqual(paths.filter { $0 == "/usr/bin" }.count, 1)
    XCTAssertFalse(paths.contains("/tmp/untrusted"))
    XCTAssertEqual(environment["HOME"], "/tmp/home")
    XCTAssertNil(environment["OPENAI_API_KEY"])
    XCTAssertNil(environment["PRIVATE_TOKEN"])
  }

  func testTrustedToolDirectoriesDiscoverNVMVersionsNewestFirst() throws {
    let homeURL = try temporaryDirectory(named: "local-preview-nvm-home")
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let versionsURL = homeURL.appendingPathComponent(".nvm/versions/node", isDirectory: true)
    for version in ["v18.20.4", "v22.14.0", "v20.19.1"] {
      try FileManager.default.createDirectory(
        at: versionsURL.appendingPathComponent(version).appendingPathComponent("bin"),
        withIntermediateDirectories: true
      )
    }

    let directories = LocalSitePreviewProcessService.trustedToolDirectories(
      homeDirectoryPath: homeURL.path,
      fileManager: .default
    )
    let nvmDirectories = directories.filter { $0.contains("/.nvm/versions/node/") }

    XCTAssertEqual(
      nvmDirectories.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent },
      [
        "v22.14.0",
        "v20.19.1",
        "v18.20.4",
      ])
  }

  func testTrustedUserExecutableRejectsSymlinkOutsideManagedRoots() throws {
    let homeURL = try temporaryDirectory(named: "local-preview-tool-home")
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let cargoBinURL = homeURL.appendingPathComponent(".cargo/bin", isDirectory: true)
    let downloadsURL = homeURL.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: cargoBinURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)

    let trustedToolURL = cargoBinURL.appendingPathComponent("zola")
    try Data("#!/bin/sh\n".utf8).write(to: trustedToolURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: trustedToolURL.path
    )
    XCTAssertTrue(
      LocalSitePreviewProcessService.isTrustedExecutable(
        atPath: trustedToolURL.path,
        homeDirectoryPath: homeURL.path,
        inheritedPATH: nil
      ))

    let untrustedTargetURL = downloadsURL.appendingPathComponent("tool")
    try Data("#!/bin/sh\n".utf8).write(to: untrustedTargetURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: untrustedTargetURL.path
    )
    let escapingLinkURL = cargoBinURL.appendingPathComponent("unsafe-tool")
    try FileManager.default.createSymbolicLink(
      at: escapingLinkURL,
      withDestinationURL: untrustedTargetURL
    )

    XCTAssertFalse(
      LocalSitePreviewProcessService.isTrustedExecutable(
        atPath: escapingLinkURL.path,
        homeDirectoryPath: homeURL.path,
        inheritedPATH: nil
      ))
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

  func testPreviewPlanRejectsOversizedPackageJSON() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-preview-oversized-package-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try Data(repeating: 0x41, count: 1_048_577)
      .write(to: rootURL.appendingPathComponent("package.json"))

    var profile = SiteProfile.defaultProfile
    profile.siteKind = .astro
    profile.localRepositoryRootPath = rootURL.path
    let service = LocalSitePreviewService(
      executableResolver: { name in "/trusted/\(name)" },
      portAllocator: LocalSitePreviewPortAllocator(
        isPortAvailable: { $0 == 4_323 },
        dynamicPort: { 4_323 }
      )
    )

    let plan = try XCTUnwrap(service.plan(profile: profile))

    XCTAssertTrue(plan.diagnostics.dependencies.contains { $0.id == "package-json" })
    XCTAssertFalse(plan.diagnostics.dependencies.contains { $0.id == "script" && $0.status == .available })
  }

  func testPreviewPlanRejectsPackageJSONSymbolicLink() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-preview-package-link-\(UUID().uuidString)", isDirectory: true)
    let outsideURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-preview-package-target-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    let targetURL = outsideURL.appendingPathComponent("package.json")
    try Data("{\"scripts\":{\"dev\":\"astro dev\"}}".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("package.json"),
      withDestinationURL: targetURL
    )

    var profile = SiteProfile.defaultProfile
    profile.siteKind = .astro
    profile.localRepositoryRootPath = rootURL.path
    let service = LocalSitePreviewService(
      executableResolver: { name in "/trusted/\(name)" },
      portAllocator: LocalSitePreviewPortAllocator(
        isPortAvailable: { $0 == 4_324 },
        dynamicPort: { 4_324 }
      )
    )

    let plan = try XCTUnwrap(service.plan(profile: profile))

    XCTAssertTrue(plan.diagnostics.dependencies.contains { $0.id == "package-json" })
    XCTAssertFalse(plan.diagnostics.dependencies.contains { $0.id == "script" && $0.status == .available })
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
