import Foundation
import XCTest

import PublishingGitCore

@testable import PublishingWorkbenchCore

final class RepositoryOperationLifecycleTests: XCTestCase {
  func testRepositoryReadFailuresRemainBlockedAndIdentifyTheirCause() throws {
    let service = LocalRepositoryService()
    let missing = service.operationLifecycle(profile: SiteProfile(name: "Missing"))
    XCTAssertEqual(missing.kind, .ambiguous)
    XCTAssertEqual(missing.readFailure, .repositoryUnavailable)
    XCTAssertTrue(missing.isOperationInProgress)

    let plainDirectory = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: plainDirectory) }
    let notGit = service.operationLifecycle(
      profile: SiteProfile(name: "Plain", localRepositoryRootPath: plainDirectory.path)
    )
    XCTAssertEqual(notGit.kind, .ambiguous)
    XCTAssertEqual(notGit.readFailure, .notGitWorktree)

    try initializeRepository(plainDirectory)
    let nestedDirectory = plainDirectory.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    let notRoot = service.operationLifecycle(
      profile: SiteProfile(name: "Nested", localRepositoryRootPath: nestedDirectory.path)
    )
    XCTAssertEqual(notRoot.kind, .ambiguous)
    XCTAssertEqual(notRoot.readFailure, .notRepositoryRoot)

    let unreadableGit = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: unreadableGit) }
    try write("gitdir: missing-git-directory\n", to: unreadableGit.appendingPathComponent(".git"))
    let gitFailure = service.operationLifecycle(
      profile: SiteProfile(name: "Invalid Git", localRepositoryRootPath: unreadableGit.path)
    )
    XCTAssertEqual(gitFailure.kind, .ambiguous)
    XCTAssertEqual(gitFailure.readFailure, .gitReadFailed)
  }

  func testMultipleGitOperationMarkersAreNotReportedAsRepositoryReadFailure() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try initializeRepository(rootURL)
    try write("base\n", to: rootURL.appendingPathComponent("article.md"))
    try runGit(["add", "article.md"], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)
    let head = try runGit(["rev-parse", "HEAD"], rootURL: rootURL).output
    try write(head, to: rootURL.appendingPathComponent(".git/MERGE_HEAD"))
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git/rebase-merge", isDirectory: true),
      withIntermediateDirectories: true
    )

    let lifecycle = LocalRepositoryService().operationLifecycle(
      profile: SiteProfile(name: "Markers", localRepositoryRootPath: rootURL.path)
    )
    XCTAssertEqual(lifecycle.kind, .ambiguous)
    XCTAssertNil(lifecycle.readFailure)
  }

  func testMergeConflictCanBeStagedThenCommittedWithoutLosingMergeLifecycle() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = try prepareMergeConflict(at: rootURL)
    let service = LocalRepositoryService()

    let conflicted = service.operationLifecycle(profile: profile)
    XCTAssertEqual(conflicted.kind, .merge)
    XCTAssertEqual(conflicted.unresolvedConflictCount, 1)
    XCTAssertFalse(conflicted.isCompletionReady)

    let path = "content/posts/article.md"
    try write("title\nresolved\n", to: rootURL.appendingPathComponent(path))
    try runGit(["add", "--", path], rootURL: rootURL)

    let staged = service.operationLifecycle(profile: profile)
    XCTAssertEqual(staged.kind, .merge, "Staging conflict files must not hide MERGE_HEAD.")
    XCTAssertEqual(staged.unresolvedConflictCount, 0)
    XCTAssertTrue(staged.isCompletionReady)

    let completed = try service.commitMerge(profile: profile, message: "Resolve article conflict")
    XCTAssertEqual(completed.kind, .none)
    XCTAssertNotEqual(try runGit(["rev-parse", "--verify", "MERGE_HEAD"], rootURL: rootURL, allowFailure: true).status, 0)
    XCTAssertEqual(try read(rootURL.appendingPathComponent(path)), "title\nresolved\n")
  }

  func testAbortMergeRestoresPreMergeHeadAndRejectsRebaseAbort() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = try prepareMergeConflict(at: rootURL)
    let service = LocalRepositoryService()
    let localHead = try runGit(["rev-parse", "HEAD"], rootURL: rootURL).output.trimmingCharacters(in: .whitespacesAndNewlines)

    XCTAssertThrowsError(try service.abortRebase(profile: profile)) { error in
      XCTAssertEqual(
        error as? RepositoryOperationLifecycleError,
        .unexpectedOperation(expected: .rebase, actual: .merge)
      )
    }

    let aborted = try service.abortMerge(profile: profile)
    XCTAssertEqual(aborted.kind, .none)
    XCTAssertEqual(
      try runGit(["rev-parse", "HEAD"], rootURL: rootURL).output.trimmingCharacters(in: .whitespacesAndNewlines),
      localHead
    )
    XCTAssertEqual(
      try read(rootURL.appendingPathComponent("content/posts/article.md")),
      "title\nlocal\n"
    )
  }

  func testRebaseContinueAndAbortUseOnlyMatchingLifecycle() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = try prepareRebaseConflict(at: rootURL)
    let service = LocalRepositoryService()
    let path = "content/posts/article.md"

    let conflicted = service.operationLifecycle(profile: profile)
    XCTAssertEqual(conflicted.kind, .rebase)
    XCTAssertEqual(conflicted.unresolvedConflictCount, 1)
    XCTAssertThrowsError(try service.commitMerge(profile: profile, message: "not a merge")) { error in
      XCTAssertEqual(
        error as? RepositoryOperationLifecycleError,
        .unexpectedOperation(expected: .merge, actual: .rebase)
      )
    }

    try write("title\nrebased\n", to: rootURL.appendingPathComponent(path))
    try runGit(["add", "--", path], rootURL: rootURL)
    let continued = try service.continueRebase(profile: profile)
    XCTAssertEqual(continued.kind, .none)
    XCTAssertEqual(try read(rootURL.appendingPathComponent(path)), "title\nrebased\n")

    let abortRootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: abortRootURL) }
    let abortProfile = try prepareRebaseConflict(at: abortRootURL, branchName: "abort-feature")
    XCTAssertEqual(service.operationLifecycle(profile: abortProfile).kind, .rebase)
    let aborted = try service.abortRebase(profile: abortProfile)
    XCTAssertEqual(aborted.kind, .none)
  }

  func testStashApplyConflictRemainsVisibleAsUnmergedIndexWithoutUnsafeContinueOrAbort() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = try prepareStashApplyConflict(at: rootURL)
    let service = LocalRepositoryService()

    let lifecycle = service.operationLifecycle(profile: profile)
    XCTAssertEqual(lifecycle.kind, .unmergedIndex)
    XCTAssertEqual(lifecycle.unresolvedConflictCount, 1)
    XCTAssertTrue(lifecycle.isOperationInProgress)
    XCTAssertFalse(lifecycle.isCompletionReady)
    XCTAssertThrowsError(try service.abortMerge(profile: profile)) { error in
      XCTAssertEqual(
        error as? RepositoryOperationLifecycleError,
        .unexpectedOperation(expected: .merge, actual: .unmergedIndex)
      )
    }
  }

  private func prepareMergeConflict(at rootURL: URL) throws -> SiteProfile {
    try initializeRepository(rootURL)
    let path = "content/posts/article.md"
    try write("title\nbase\n", to: rootURL.appendingPathComponent(path))
    try runGit(["add", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)
    try runGit(["switch", "-q", "-c", "feature"], rootURL: rootURL)
    try write("title\nremote\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "remote"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try write("title\nlocal\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "local"], rootURL: rootURL)
    XCTAssertNotEqual(try runGit(["merge", "feature"], rootURL: rootURL, allowFailure: true).status, 0)
    return SiteProfile(
      name: "Lifecycle Test",
      localRepositoryRootPath: rootURL.path,
      branch: "main"
    )
  }

  private func prepareRebaseConflict(at rootURL: URL, branchName: String = "feature") throws -> SiteProfile {
    if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(".git").path) {
      try runGit(["rebase", "--abort"], rootURL: rootURL)
      try runGit(["switch", "-q", "main"], rootURL: rootURL)
    } else {
      try initializeRepository(rootURL)
      let path = "content/posts/article.md"
      try write("title\nbase\n", to: rootURL.appendingPathComponent(path))
      try runGit(["add", "--", path], rootURL: rootURL)
      try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)
    }

    let path = "content/posts/article.md"
    try runGit(["switch", "-q", "-c", branchName], rootURL: rootURL)
    try write("title\nfeature\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "feature"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try write("title\nmain\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "main"], rootURL: rootURL)
    try runGit(["switch", "-q", branchName], rootURL: rootURL)
    XCTAssertNotEqual(try runGit(["rebase", "main"], rootURL: rootURL, allowFailure: true).status, 0)
    return SiteProfile(
      name: "Lifecycle Test",
      localRepositoryRootPath: rootURL.path,
      branch: branchName
    )
  }

  private func prepareStashApplyConflict(at rootURL: URL) throws -> SiteProfile {
    try initializeRepository(rootURL)
    let path = "content/posts/article.md"
    try write("title\nbase\n", to: rootURL.appendingPathComponent(path))
    try runGit(["add", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)
    try write("title\nstashed\n", to: rootURL.appendingPathComponent(path))
    try runGit(["stash", "push", "-q", "-m", "lifecycle stash"], rootURL: rootURL)
    try write("title\nmain\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "main"], rootURL: rootURL)
    XCTAssertNotEqual(try runGit(["stash", "apply", "--index"], rootURL: rootURL, allowFailure: true).status, 0)
    return SiteProfile(name: "Lifecycle Test", localRepositoryRootPath: rootURL.path)
  }

  private func initializeRepository(_ rootURL: URL) throws {
    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)
    try runGit(["config", "user.name", "Lifecycle Test"], rootURL: rootURL)
    try runGit(["config", "user.email", "lifecycle@example.invalid"], rootURL: rootURL)
  }

  private func makeTemporaryRepository() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryOperationLifecycleTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func read(_ url: URL) throws -> String {
    try String(decoding: Data(contentsOf: url), as: UTF8.self)
  }

  @discardableResult
  private func runGit(
    _ arguments: [String],
    rootURL: URL,
    allowFailure: Bool = false
  ) throws -> (status: Int32, output: String) {
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
    guard allowFailure || process.terminationStatus == 0 else {
      let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Git command failed"
      throw NSError(
        domain: "RepositoryOperationLifecycleTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: error]
      )
    }
    return (process.terminationStatus, output)
  }
}
