import XCTest
@testable import PublishingWorkbenchCore

final class LocalGitPublishServiceTests: XCTestCase {
  func testDirectCommitWritesAndCommitsPackageFiles() throws {
    let rootURL = try makeGitRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Direct Commit",
      slug: "direct-commit",
      draft: false,
      bodyMarkdown: "Direct commit body."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try LocalGitPublishService().publish(package: package, profile: profile, mode: .directCommit)

    XCTAssertEqual(result.mode, .directCommit)
    XCTAssertEqual(result.branchName, "main")
    XCTAssertEqual(result.committedPaths, ["content/posts/direct-commit.md"])
    XCTAssertFalse(result.commitSHA.isEmpty)
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: rootURL), "")
    XCTAssertTrue(try git(["show", "--name-only", "--format="], rootURL: rootURL).contains("content/posts/direct-commit.md"))
  }

  func testReviewBranchCommitCreatesBranchWithoutPushing() throws {
    let rootURL = try makeGitRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Review Commit",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "review-commit",
      draft: false,
      bodyMarkdown: "Review branch commit body."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try LocalGitPublishService().publish(package: package, profile: profile, mode: .reviewBranch)

    XCTAssertEqual(result.mode, .reviewBranch)
    XCTAssertEqual(result.branchName, "publish/review-commit-20260829")
    XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL), "publish/review-commit-20260829")
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: rootURL), "")
  }

  func testFailsOutsideGitRepository() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacNoGit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)

    let draft = ArticleDraft(siteProfileID: profile.id, title: "No Git", slug: "no-git", bodyMarkdown: "Body")
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    XCTAssertThrowsError(
      try LocalGitPublishService().publish(package: package, profile: profile, mode: .directCommit)
    ) { error in
      guard case let .notGitRepository(path) = error as? LocalGitPublishError else {
        XCTFail("Expected notGitRepository")
        return
      }
      XCTAssertEqual(normalizedTemporaryPath(path), normalizedTemporaryPath(rootURL.path))
    }
  }

  private func makeGitRepositoryFixture() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacGitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "seed\n".write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    return rootURL
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
        domain: "LocalGitPublishServiceTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizedTemporaryPath(_ path: String) -> String {
    path.replacingOccurrences(of: "/private/var/", with: "/var/")
  }
}
