import Foundation
import PublishingGitCore
import PublishingWorkbenchCore
import XCTest

final class RepositoryGitTransportCheckServiceTests: XCTestCase {
  func testReadsLocalBareRemoteAndNeverClaimsWritePermission() async throws {
    let fixture = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }

    let beforeStatus = try git(["status", "--porcelain"], rootURL: fixture.repositoryURL)
    let check = await RepositoryGitTransportCheckService().check(profile: fixture.profile)
    let afterStatus = try git(["status", "--porcelain"], rootURL: fixture.repositoryURL)

    XCTAssertEqual(check.remoteName, "origin")
    XCTAssertEqual(check.sanitizedRemoteURL, fixture.remoteURL.path)
    XCTAssertEqual(check.transport, .local)
    XCTAssertEqual(check.targetBranch, "main")
    XCTAssertTrue(check.canReadRemote)
    XCTAssertEqual(check.targetBranchExists, true)
    XCTAssertFalse(check.writePermissionVerified)
    XCTAssertTrue(check.summary.contains("写入权限尚未验证"))
    XCTAssertEqual(afterStatus, beforeStatus)
  }

  func testReportsReadableRemoteWhenTargetBranchDoesNotExist() async throws {
    let fixture = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    var profile = fixture.profile
    profile.branch = "release/not-created"

    let check = await RepositoryGitTransportCheckService().check(profile: profile)

    XCTAssertTrue(check.canReadRemote)
    XCTAssertEqual(check.targetBranchExists, false)
    XCTAssertFalse(check.writePermissionVerified)
    XCTAssertTrue(check.summary.contains("未找到目标分支"))
  }

  func testReportsMissingRemoteWithoutClaimingReadOrWriteAccess() async throws {
    let fixture = try makeRepositoryFixture(includeRemote: false)
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }

    let check = await RepositoryGitTransportCheckService().check(profile: fixture.profile)

    XCTAssertFalse(check.canReadRemote)
    XCTAssertNil(check.targetBranchExists)
    XCTAssertFalse(check.writePermissionVerified)
    XCTAssertNil(check.sanitizedRemoteURL)
    XCTAssertTrue(check.summary.contains("未找到 Git 远端"))
    XCTAssertTrue(check.detail.contains("没有执行推送"))
  }

  func testRedactsCredentialBearingHTTPSRemoteAndClassifiesTransport() async throws {
    let fixture = try makeRepositoryFixture(includeRemote: false)
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try git(
      [
        "remote", "add", "origin",
        "https://octopus:secret-password@127.0.0.1:9/owner/repository.git",
      ],
      rootURL: fixture.repositoryURL
    )
    let runner = GitCommandRunner(timeout: 2)

    let check = await RepositoryGitTransportCheckService(gitCommandRunner: runner)
      .check(profile: fixture.profile)

    XCTAssertEqual(check.transport, .https)
    XCTAssertEqual(check.sanitizedRemoteURL, "https://127.0.0.1:9/owner/repository.git")
    XCTAssertFalse(check.canReadRemote)
    XCTAssertFalse(check.writePermissionVerified)
    XCTAssertFalse(check.sanitizedRemoteURL?.contains("octopus") ?? true)
    XCTAssertFalse(check.sanitizedRemoteURL?.contains("secret-password") ?? true)
    XCTAssertFalse(check.detail.contains("octopus"))
    XCTAssertFalse(check.detail.contains("secret-password"))
  }

  func testClassifiesPlainHTTPRemoteAsUnknown() async throws {
    let fixture = try makeRepositoryFixture(includeRemote: false)
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try git(
      ["remote", "add", "origin", "http://127.0.0.1:9/owner/repository.git"],
      rootURL: fixture.repositoryURL
    )
    let runner = GitCommandRunner(timeout: 2)

    let check = await RepositoryGitTransportCheckService(gitCommandRunner: runner)
      .check(profile: fixture.profile)

    XCTAssertEqual(check.transport, .unknown)
    XCTAssertEqual(check.sanitizedRemoteURL, "http://127.0.0.1:9/owner/repository.git")
    XCTAssertFalse(check.canReadRemote)
    XCTAssertFalse(check.writePermissionVerified)
  }

  func testModelNeverPersistsAnAffirmativeWritePermission() {
    let check = RepositoryGitTransportCheck(
      remoteName: "origin",
      sanitizedRemoteURL: "git@github.com:owner/repository.git",
      transport: .ssh,
      targetBranch: "main",
      canReadRemote: true,
      targetBranchExists: true,
      writePermissionVerified: true,
      summary: "test",
      detail: "test"
    )

    XCTAssertFalse(check.writePermissionVerified)
  }

  func testDecodingAffirmativeWritePermissionStillReportsItAsUnverified() throws {
    let check = RepositoryGitTransportCheck(
      remoteName: "origin",
      sanitizedRemoteURL: "https://example.invalid/owner/repository.git",
      transport: .https,
      targetBranch: "main",
      canReadRemote: true,
      targetBranchExists: true,
      summary: "test",
      detail: "test",
      checkedAt: Date(timeIntervalSince1970: 1_234)
    )
    let encoded = try JSONEncoder().encode(check)
    var payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    payload["writePermissionVerified"] = true
    let tamperedData = try JSONSerialization.data(withJSONObject: payload)

    let decoded = try JSONDecoder().decode(
      RepositoryGitTransportCheck.self,
      from: tamperedData
    )

    XCTAssertFalse(decoded.writePermissionVerified)
  }

  private func makeRepositoryFixture(
    includeRemote: Bool = true
  ) throws -> (baseURL: URL, repositoryURL: URL, remoteURL: URL, profile: SiteProfile) {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RepositoryGitTransportCheckServiceTests-\(UUID().uuidString)", isDirectory: true)
    let repositoryURL = baseURL.appendingPathComponent("worktree", isDirectory: true)
    let remoteURL = baseURL.appendingPathComponent("origin.git", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    try git(["init", "--initial-branch=main", repositoryURL.path], rootURL: baseURL)
    try git(["config", "user.email", "tests@example.invalid"], rootURL: repositoryURL)
    try git(["config", "user.name", "RepoPress Tests"], rootURL: repositoryURL)
    let readmeURL = repositoryURL.appendingPathComponent("README.md")
    try Data("# Fixture\n".utf8).write(to: readmeURL)
    try git(["add", "README.md"], rootURL: repositoryURL)
    try git(["commit", "-m", "Initial fixture"], rootURL: repositoryURL)

    if includeRemote {
      try git(["init", "--bare", "--initial-branch=main", remoteURL.path], rootURL: baseURL)
      try git(["remote", "add", "origin", remoteURL.path], rootURL: repositoryURL)
      try git(["push", "origin", "main"], rootURL: repositoryURL)
    }

    var profile = SiteProfile(name: "Git transport fixture")
    profile.localRepositoryRootPath = repositoryURL.path
    profile.branch = "main"
    return (baseURL, repositoryURL, remoteURL, profile)
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
    let output =
      String(
        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let error =
      String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryGitTransportCheckServiceTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
