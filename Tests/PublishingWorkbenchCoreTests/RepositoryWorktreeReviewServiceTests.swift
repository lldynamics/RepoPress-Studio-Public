import Foundation
import PublishingGitCore
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryWorktreeReviewServiceTests: XCTestCase {
  func testCapturesFullTrackedAndUntrackedDiffWithoutChangingIndex() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let longText = (1...80).map { "new line \($0)" }.joined(separator: "\n") + "\n"
    try Data(longText.utf8).write(to: root.appendingPathComponent("tracked.md"))
    try Data("new article\n".utf8).write(to: root.appendingPathComponent("new file.md"))
    let entries = [
      RepositoryWorktreePublishEntry(
        kind: .modified, status: " M", path: "tracked.md",
        blobOID: try run(["hash-object", "tracked.md"], root: root)),
      RepositoryWorktreePublishEntry(
        kind: .added, status: "??", path: "new file.md",
        blobOID: try run(["hash-object", "new file.md"], root: root)),
    ]
    let before = try run(["status", "--porcelain=v1"], root: root)
    let reviews = RepositoryWorktreeReviewService(git: GitCommandRunner()).capture(
      entries: entries, root: root, baseRevision: "HEAD"
    )
    XCTAssertEqual(reviews.count, 2)
    XCTAssertTrue(reviews.allSatisfy { $0.notice == nil })
    XCTAssertTrue(reviews[0].patch.contains("-base"))
    XCTAssertTrue(reviews[0].patch.contains("+new line 80"))
    XCTAssertTrue(reviews[1].patch.contains("+new article"))
    XCTAssertEqual(try run(["status", "--porcelain=v1"], root: root), before)
    XCTAssertTrue(try run(["diff", "--cached", "--name-only"], root: root).isEmpty)
    try Data("later unrelated edit\n".utf8).write(to: root.appendingPathComponent("tracked.md"))
    XCTAssertFalse(reviews[0].patch.contains("later unrelated edit"))
  }

  func testRetryReviewUsesFrozenCommitRangeInsteadOfWorkingFile() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try run(["rev-parse", "HEAD"], root: root)
    try Data("committed version\n".utf8).write(to: root.appendingPathComponent("tracked.md"))
    try run(["add", "--", "tracked.md"], root: root)
    try run(["commit", "-m", "next"], root: root)
    let target = try run(["rev-parse", "HEAD"], root: root)
    try Data("unreviewed working version\n".utf8).write(
      to: root.appendingPathComponent("tracked.md"))
    let reviews = RepositoryWorktreeReviewService(git: GitCommandRunner()).capture(
      entries: [.init(kind: .modified, status: "M", path: "tracked.md")],
      root: root, baseRevision: base, targetRevision: target
    )
    XCTAssertTrue(reviews[0].patch.contains("+committed version"))
    XCTAssertFalse(reviews[0].patch.contains("unreviewed working version"))
  }

  func testUnreadableReviewReportsFailureInsteadOfAnEmptySuccessfulDiff() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let reviews = RepositoryWorktreeReviewService(git: GitCommandRunner()).capture(
      entries: [.init(kind: .added, status: "??", path: "missing.md")],
      root: root, baseRevision: "HEAD"
    )
    XCTAssertNotNil(reviews[0].notice)
  }

  func testCapturedPatchMustMatchSnapshotBlobEvenWhenFileIsRestoredAfterCapture() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("tracked.md")
    try Data("reviewed snapshot\n".utf8).write(to: url)
    let entry = RepositoryWorktreePublishEntry(
      kind: .modified, status: " M", path: "tracked.md",
      blobOID: try run(["hash-object", "tracked.md"], root: root))
    try Data("temporary external edit\n".utf8).write(to: url)
    let reviews = RepositoryWorktreeReviewService(git: GitCommandRunner()).capture(
      entries: [entry], root: root, baseRevision: "HEAD")
    try Data("reviewed snapshot\n".utf8).write(to: url)
    XCTAssertEqual(try run(["hash-object", "tracked.md"], root: root), entry.blobOID)
    XCTAssertFalse(RepositoryWorktreeFileReview.isComplete(entries: [entry], reviews: reviews))
    XCTAssertTrue(reviews[0].patch.isEmpty)
    XCTAssertFalse(
      RepositoryWorktreeReviewService.frozenDataMatches(
        Data("temporary external edit\n".utf8), entry: entry, root: root, git: GitCommandRunner()))
  }

  func testTruncatedDiffIsNotACompleteReview() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = String(repeating: "large change line\n", count: 300_000)
    try Data(content.utf8).write(to: root.appendingPathComponent("tracked.md"))
    let entry = RepositoryWorktreePublishEntry(
      kind: .modified, status: " M", path: "tracked.md",
      blobOID: try run(["hash-object", "tracked.md"], root: root))
    let reviews = RepositoryWorktreeReviewService(git: GitCommandRunner()).capture(
      entries: [entry], root: root, baseRevision: "HEAD")
    XCTAssertNotNil(reviews[0].notice)
    XCTAssertFalse(RepositoryWorktreeFileReview.isComplete(entries: [entry], reviews: reviews))
    XCTAssertFalse(RepositoryWorktreeFileReview.isComplete(entries: [entry], reviews: []))
    XCTAssertTrue(RepositoryWorktreeFileReview.isComplete(entries: [], reviews: []))
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-diff-review-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try run(["init", "-b", "main"], root: root)
    try run(["config", "user.name", "Review Tests"], root: root)
    try run(["config", "user.email", "review@example.invalid"], root: root)
    try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.md"))
    try run(["add", "--", "tracked.md"], root: root)
    try run(["commit", "-m", "base"], root: root)
    return root
  }

  @discardableResult
  private func run(_ arguments: [String], root: URL) throws -> String {
    let result = GitCommandRunner().run(arguments, rootURL: root)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw NSError(
        domain: "ReviewTests", code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
