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

  func testDirectCommitIgnoresSuccessfulStatusWarningOnStandardError() throws {
    let rootURL = try makeGitRepositoryFixture()
    let wrapperURL = try makeGitWrapperEmittingStatusWarning()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: wrapperURL.deletingLastPathComponent())
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Standard Error Warning",
      slug: "stderr-warning",
      draft: false,
      bodyMarkdown: "A successful Git warning must not be parsed as porcelain status output."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let service = LocalGitPublishService(
      gitCommandRunner: GitCommandRunner(executableURL: wrapperURL)
    )

    let result = try service.publish(
      package: package,
      profile: profile,
      mode: .directCommit
    )

    XCTAssertEqual(result.committedPaths, ["content/posts/stderr-warning.md"])
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: rootURL), "")
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

  func testDirectCommitStagesPathMigrationAsAddAndDelete() throws {
    let rootURL = try makeGitRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let oldURL = rootURL.appendingPathComponent("content/posts/old-name.md")
    try "old article\n".write(to: oldURL, atomically: true, encoding: .utf8)
    try git(["add", "content/posts/old-name.md"], rootURL: rootURL)
    try git(["commit", "-m", "Seed old article"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "New Name",
      slug: "new-name",
      draft: false,
      bodyMarkdown: "Updated article body after renaming the repository path.",
      repositoryPath: "content/posts/old-name.md"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try LocalGitPublishService().publish(
      package: package,
      profile: profile,
      mode: .directCommit
    )

    XCTAssertEqual(result.committedPaths, ["content/posts/new-name.md", "content/posts/old-name.md"])
    let nameStatus = try git(["show", "--no-renames", "--name-status", "--format="], rootURL: rootURL)
    XCTAssertTrue(nameStatus.contains("A\tcontent/posts/new-name.md"))
    XCTAssertTrue(nameStatus.contains("D\tcontent/posts/old-name.md"))
  }

  func testRejectsExistingStagedChangesWithoutWritingPackage() throws {
    let rootURL = try makeGitRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try "keep staged\n".write(
      to: rootURL.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "notes.txt"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Protected Index",
      slug: "protected-index",
      bodyMarkdown: "Publishing must not consume unrelated staged content."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    XCTAssertThrowsError(
      try LocalGitPublishService().publish(package: package, profile: profile, mode: .directCommit)
    ) { error in
      XCTAssertEqual(error as? LocalGitPublishError, .repositoryHasStagedChanges(["notes.txt"]))
    }

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("content/posts/protected-index.md").path
      )
    )
    XCTAssertEqual(try git(["diff", "--cached", "--name-only"], rootURL: rootURL), "notes.txt")
  }

  func testFailedReviewCommitRestoresFilesIndexAndOriginalBranch() throws {
    let rootURL = try makeGitRepositoryFixture()
    let wrapperURL = try makeGitWrapperFailingCommit()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: wrapperURL.deletingLastPathComponent())
    }
    let articleURL = rootURL.appendingPathComponent("content/posts/rollback.md")
    try "original article\n".write(to: articleURL, atomically: true, encoding: .utf8)
    try git(["add", "content/posts/rollback.md"], rootURL: rootURL)
    try git(["commit", "-m", "Seed rollback article"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Rollback",
      slug: "rollback",
      bodyMarkdown: "updated article that must be rolled back after the hook rejects the commit"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    XCTAssertThrowsError(
      try LocalGitPublishService(
        gitCommandRunner: GitCommandRunner(executableURL: wrapperURL)
      ).publish(package: package, profile: profile, mode: .reviewBranch)
    )

    XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL), "main")
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: rootURL), "")
    XCTAssertEqual(try String(contentsOf: articleURL, encoding: .utf8), "original article\n")
    XCTAssertThrowsError(try git(["rev-parse", "--verify", package.reviewBranchName], rootURL: rootURL))
  }

  func testFailedCommitPreservesExternalEditInsteadOfRollingItBack() throws {
    let rootURL = try makeGitRepositoryFixture()
    let wrapperURL = try makeGitWrapperFailingCommitAndEditingConcurrentArticle()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: wrapperURL.deletingLastPathComponent())
    }
    let articleURL = rootURL.appendingPathComponent("content/posts/concurrent.md")
    try "original article\n".write(to: articleURL, atomically: true, encoding: .utf8)
    try git(["add", "content/posts/concurrent.md"], rootURL: rootURL)
    try git(["commit", "-m", "Seed concurrent article"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Concurrent Edit",
      slug: "concurrent",
      bodyMarkdown: "publisher content"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    XCTAssertThrowsError(
      try LocalGitPublishService(
        gitCommandRunner: GitCommandRunner(executableURL: wrapperURL)
      ).publish(package: package, profile: profile, mode: .directCommit)
    ) { error in
      guard case let .rollbackFailed(_, rollback) = error as? LocalGitPublishError else {
        XCTFail("Expected rollbackFailed, got \(error)")
        return
      }
      XCTAssertTrue(rollback.contains("检测到发布后的外部修改"))
      XCTAssertTrue(rollback.contains("content/posts/concurrent.md"))
    }

    XCTAssertEqual(try String(contentsOf: articleURL, encoding: .utf8), "external editor content\n")
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

  func testDirectCommitSupportsLinkedGitWorktree() throws {
    let rootURL = try makeGitRepositoryFixture()
    let linkedURL = rootURL
      .deletingLastPathComponent()
      .appendingPathComponent("PersonalSitePublisherMacLinked-\(UUID().uuidString)", isDirectory: true)
    defer {
      _ = try? git(["worktree", "remove", "--force", linkedURL.path], rootURL: rootURL)
      try? FileManager.default.removeItem(at: linkedURL)
      try? FileManager.default.removeItem(at: rootURL)
    }
    try git(["worktree", "add", "-b", "linked-publish", linkedURL.path], rootURL: rootURL)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: linkedURL.appendingPathComponent(".git").path,
      isDirectory: &isDirectory
    ))
    XCTAssertFalse(isDirectory.boolValue)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(linkedURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Linked Worktree",
      slug: "linked-worktree",
      draft: false,
      bodyMarkdown: "Publishing must support Git worktrees whose .git entry is a file."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try LocalGitPublishService().publish(
      package: package,
      profile: profile,
      mode: .directCommit
    )

    XCTAssertEqual(result.branchName, "linked-publish")
    XCTAssertTrue(try git(["show", "--name-only", "--format="], rootURL: linkedURL).contains(
      "content/posts/linked-worktree.md"
    ))
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

  private func makeGitWrapperEmittingStatusWarning() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacGitWrapper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let scriptURL = directoryURL.appendingPathComponent("git")
    let script = """
    #!/bin/sh
    if [ "$3" = "status" ]; then
      printf 'warning: simulated fsmonitor failure\n' >&2
    fi
    exec /usr/bin/git "$@"
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }

  private func makeGitWrapperFailingCommit() throws -> URL {
    try makeGitWrapper(scriptBody: """
    if [ "$3" = "commit" ]; then
      printf 'simulated commit failure\n' >&2
      exit 1
    fi
    """)
  }

  private func makeGitWrapperFailingCommitAndEditingConcurrentArticle() throws -> URL {
    try makeGitWrapper(scriptBody: """
    if [ "$3" = "commit" ]; then
      printf 'external editor content\\n' > "$2/content/posts/concurrent.md"
      printf 'simulated commit failure\n' >&2
      exit 1
    fi
    """)
  }

  private func makeGitWrapper(scriptBody: String) throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacGitWrapper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let scriptURL = directoryURL.appendingPathComponent("git")
    let script = """
    #!/bin/sh
    \(scriptBody)
    exec /usr/bin/git "$@"
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
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
