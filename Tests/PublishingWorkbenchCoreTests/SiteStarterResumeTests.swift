import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class SiteStarterResumeTests: XCTestCase {
  func testPersistenceRoundTripRestoresActiveStarterAndPreparesFreshPushReview() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let persistenceURL = fixture.directory.appendingPathComponent("workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    _ = try persistence.save(fixture.snapshot)

    let restored = WorkbenchStore(persistence: persistence)

    XCTAssertEqual(restored.siteStarterResult?.profile.id, fixture.profile.id)
    XCTAssertEqual(restored.siteStarterResult?.initialDraft.id, fixture.draft.id)
    XCTAssertEqual(restored.siteStarterResult?.createdFilePaths, ["content/welcome.md"])
    XCTAssertEqual(restored.siteStarterProgress?.firstPushStage, .pending)

    let confirmation = await restored.prepareStarterSitePushConfirmation()
    XCTAssertEqual(confirmation?.rootPath, fixture.root.path)
    XCTAssertEqual(confirmation?.committedPaths, ["content/welcome.md"])
  }

  func testLegacySnapshotWithoutProgressDecodesToNil() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let data = try JSONEncoder.workbench.encode(fixture.snapshot)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "siteStarterProgress")
    object["formatVersion"] = 14

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertNil(decoded.siteStarterProgress)
  }

  func testResumeGuardsMissingDraftChangedRootAndMissingManifestFile() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let progress = try XCTUnwrap(fixture.snapshot.siteStarterProgress)

    XCTAssertNil(progress.resumedResult(activeProfile: fixture.profile, drafts: []))

    var movedProfile = fixture.profile
    _ = movedProfile.rememberLocalRepositoryRoot(fixture.directory.appendingPathComponent("other"))
    XCTAssertNil(progress.resumedResult(activeProfile: movedProfile, drafts: [fixture.draft]))

    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("content/welcome.md"))
    XCTAssertNil(progress.resumedResult(activeProfile: fixture.profile, drafts: [fixture.draft]))
  }

  func testFailedResumeKeepsCheckpointForARepairOrLaterRetry() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("content/welcome.md"))

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: fixture.directory.appendingPathComponent("workbench.json")
      ),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: fixture.snapshot))
    )

    XCTAssertNil(store.siteStarterResult)
    XCTAssertEqual(store.siteStarterProgress, fixture.snapshot.siteStarterProgress)
  }

  func testResumePresentationRestoresWizardInputsAndSelectsSafeNextStep() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let progress = SiteStarterProgress(
      profileID: fixture.profile.id,
      repositoryRootPath: fixture.root.path,
      templateID: .vitePressDocumentation,
      initialDraftID: fixture.draft.id,
      createdFilePaths: ["content/welcome.md"],
      initializedGit: true,
      originConfigured: false,
      siteDescription: "恢复时不采用另一个窗口的旧值",
      deploymentTarget: .cloudflarePages,
      configureOriginRemote: false
    )

    let presentation = try XCTUnwrap(progress.resumePresentation(for: fixture.profile))

    XCTAssertEqual(presentation.templateID, .vitePressDocumentation)
    XCTAssertEqual(presentation.rootPath, fixture.root.path)
    XCTAssertEqual(presentation.branch, "main")
    XCTAssertEqual(presentation.githubOwner, "owner")
    XCTAssertEqual(presentation.githubRepositoryName, "resume")
    XCTAssertEqual(presentation.deploymentTarget, .cloudflarePages)
    XCTAssertEqual(presentation.siteDescription, "恢复时不采用另一个窗口的旧值")
    XCTAssertEqual(presentation.route, .github)

    var configured = progress
    configured.originConfigured = true
    XCTAssertEqual(configured.resumePresentation(for: fixture.profile)?.route, .firstPush)

    var completed = progress
    completed.firstPushStage = .completed
    XCTAssertEqual(completed.resumePresentation(for: fixture.profile)?.route, .deployment)
  }

  func testCommittedStarterPushSurvivesRejectedRemoteAndRetriesSamePersistedSHA() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SiteStarterResumeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let rootURL = directory.appendingPathComponent("site", isDirectory: true)
    let remoteURL = directory.appendingPathComponent("remote.git", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try git(["init", "--bare", remoteURL.path], root: directory)

    let persistence = WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(persistence: persistence)
    let created = await store.createSiteFromStarter(
      SiteStarterRequest(
        rootPath: rootURL.path,
        siteName: "Store Retry",
        branch: "main",
        githubOwner: "owner",
        githubRepositoryName: "retry",
        deploymentTarget: .githubPages,
        initializeGit: true,
        configureOriginRemote: false
      )
    )
    _ = try XCTUnwrap(created)

    try git(["config", "user.email", "tests@example.com"], root: rootURL)
    try git(["config", "user.name", "Tests"], root: rootURL)
    try git(["remote", "add", "origin", remoteURL.path], root: rootURL)

    let prepared = await store.prepareStarterSitePushConfirmation()
    let confirmation = try XCTUnwrap(prepared)

    let hookURL = remoteURL.appendingPathComponent("hooks/pre-receive")
    try "#!/bin/sh\nexit 1\n".write(to: hookURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

    let firstPush = await store.commitAndPushStarterSite(confirmation: confirmation)
    XCTAssertNil(firstPush)

    let committedProgress = try XCTUnwrap(store.siteStarterProgress)
    XCTAssertEqual(committedProgress.firstPushStage, .committed)
    let commitSHA = try XCTUnwrap(committedProgress.localCommitSHA)
    XCTAssertNil(store.siteStarterPushResult)

    let restored = WorkbenchStore(persistence: persistence)
    XCTAssertEqual(restored.siteStarterProgress?.firstPushStage, .committed)
    XCTAssertEqual(restored.siteStarterProgress?.localCommitSHA, commitSHA)

    let restoredPrepared = await restored.prepareStarterSitePushConfirmation()
    let retryConfirmation = try XCTUnwrap(restoredPrepared)
    XCTAssertEqual(retryConfirmation.existingCommitSHA, commitSHA)

    var modifiedConfirmation = retryConfirmation
    modifiedConfirmation.commitMessage = "A different reviewed message"
    let modifiedRetry = await restored.commitAndPushStarterSite(confirmation: modifiedConfirmation)
    XCTAssertNil(modifiedRetry)
    XCTAssertEqual(restored.siteStarterProgress?.localCommitSHA, commitSHA)

    try FileManager.default.removeItem(at: hookURL)
    let retriedPush = await restored.commitAndPushStarterSite(confirmation: retryConfirmation)
    let pushed = try XCTUnwrap(retriedPush)
    XCTAssertEqual(pushed.commitSHA, commitSHA)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], root: rootURL), commitSHA)
    XCTAssertEqual(try git(["rev-parse", "main"], root: remoteURL), commitSHA)
  }

  private func makeFixture() throws -> (
    directory: URL,
    root: URL,
    profile: SiteProfile,
    draft: ArticleDraft,
    snapshot: WorkbenchSnapshot
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SiteStarterResumeTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("site", isDirectory: true)
    let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true)
    try "# Welcome\n".write(
      to: root.appendingPathComponent("content/welcome.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["init", "--bare", remote.path], root: directory)
    try git(["init", "-b", "main"], root: root)
    try git(["remote", "add", "origin", remote.path], root: root)

    var profile = SiteProfile(
      name: "Resume",
      repoOwner: "owner",
      repoName: "resume",
      branch: "main"
    )
    _ = profile.rememberLocalRepositoryRoot(root)
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Welcome", slug: "welcome")
    let progress = SiteStarterProgress(
      profileID: profile.id,
      repositoryRootPath: root.path,
      templateID: .zolaPersonalBlog,
      initialDraftID: draft.id,
      createdFilePaths: ["content/welcome.md"],
      initializedGit: true,
      originConfigured: true
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      releaseRecords: [],
      siteStarterProgress: progress
    )
    return (directory, root, profile, draft, snapshot)
  }

  @discardableResult
  private func git(_ arguments: [String], root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "SiteStarterResumeTests", code: Int(process.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: outputText + errorText
      ])
    }
    return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
