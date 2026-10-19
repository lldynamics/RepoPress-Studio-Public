import Foundation
import PublishingCoreSupport
import PublishingGitCore
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryPublishSafetyAnalyzerTests: XCTestCase {
  func testWarnsForStructuralDeleteWithoutBlocking() {
    let report = analyze([
      entry(.deleted, "content/posts/2026/_index.md")
    ])

    XCTAssertEqual(report.warnings.map(\.code), [.structuralDelete])
    XCTAssertTrue(report.canPublish)
  }

  func testWarnsForCrossSectionMoveWithoutBlocking() {
    let report = analyze([
      entry(
        .renamed,
        "content/posts/2026/gallery/index.md",
        sourcePath: "content/gallery/trip/index.md"
      )
    ])

    XCTAssertEqual(report.warnings.map(\.code), [.crossSectionMove])
    XCTAssertTrue(report.canPublish)
  }

  func testWarnsForMassDeleteWithoutBlocking() {
    let report = analyze(
      (0..<10).map {
        entry(.deleted, "content/projects/project-\($0).md")
      })

    XCTAssertEqual(report.warnings.map(\.code), [.massDelete])
    XCTAssertTrue(report.canPublish)
  }

  func testWarnsForMassContentRewriteWithoutBlocking() {
    let report = analyze(
      (0..<25).map {
        entry(.modified, "content/posts/post-\($0).md")
      })

    XCTAssertEqual(report.warnings.map(\.code), [.massContentRewrite])
    XCTAssertTrue(report.canPublish)
  }

  func testWarnsWhenContentAndGuardChangeTogether() {
    let report = analyze([
      entry(.modified, "content/posts/article.md"),
      entry(.modified, "scripts/check.sh"),
    ])

    XCTAssertEqual(report.warnings.map(\.code), [.publishGuardChanged])
  }

  func testAllowsOrdinaryArticleAndImageChanges() {
    let report = analyze([
      entry(.modified, "content/posts/article.md"),
      entry(.added, "static/images/photo.png"),
    ])

    XCTAssertTrue(report.diagnostics.isEmpty)
    XCTAssertTrue(report.canPublish)
  }

  private func analyze(
    _ entries: [RepositoryWorktreePublishEntry]
  ) -> RepositoryPublishSafetyReport {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.contentRoot = "content"
    let snapshot = RepositoryWorktreePublishSnapshot(
      repositoryRoot: "/tmp/site",
      gitCommonDirectory: "/tmp/site/.git",
      branch: "main",
      headSHA: "head",
      originURL: "https://example.com/owner/site.git",
      remoteBranchSHA: "head",
      statusFingerprint: "status",
      entries: entries
    )
    return RepositoryPublishSafetyAnalyzer().analyze(snapshot: snapshot, profile: profile)
  }

  private func entry(
    _ kind: RepositoryWorktreePublishEntryKind,
    _ path: String,
    sourcePath: String? = nil
  ) -> RepositoryWorktreePublishEntry {
    RepositoryWorktreePublishEntry(
      kind: kind,
      status: String(kind.rawValue.prefix(1)).uppercased(),
      path: path,
      sourcePath: sourcePath,
      byteSize: kind == .deleted ? 0 : 10,
      mode: kind == .deleted ? nil : "100644",
      blobOID: kind == .deleted ? nil : "blob"
    )
  }
}

final class RepositoryScopedPreflightTests: XCTestCase {
  func testPreflightUsesSnapshotOverlayAndExcludesUnrelatedDirtyFiles() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let target = fixture.root.appendingPathComponent("content/posts/target.md")
    try Data("updated target\n".utf8).write(to: target)
    let invalidSibling = fixture.root.appendingPathComponent("content/posts/unrelated.md")
    try Data("invalid sibling\n".utf8).write(to: invalidSibling)
    try Data("invalid config\n".utf8).write(
      to: fixture.root.appendingPathComponent("unrelated.toml"))
    let targetData = try Data(contentsOf: target)
    let targetBlob = try git(["hash-object", target.path], at: fixture.root).trimmedForPublishing
    let snapshot = fixture.snapshot(entries: [
      .init(
        kind: .modified, status: " M", path: "content/posts/target.md",
        byteSize: Int64(targetData.count), mode: "100644", blobOID: targetBlob)
    ])
    let seen = LockedStringSet()
    let runner = RepositoryPublishPreflightCommandRunner { command in
      seen.insert(command.workingDirectoryPath)
      let root = URL(fileURLWithPath: command.workingDirectoryPath)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("config.toml").path))
      XCTAssertEqual(
        try? String(
          contentsOf: root.appendingPathComponent("content/posts/target.md"), encoding: .utf8),
        "updated target\n")
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("content/posts/unrelated.md").path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.toml").path))
      return .init(termination: .exited, exitStatus: 0)
    }
    let service = RepositoryPublishPreflightService(
      commandRunner: runner, trustedZolaExecutable: { "/usr/local/bin/zola" })

    let result = try RepositoryScopedPreflight.run(
      profile: fixture.profile, snapshot: snapshot, git: GitCommandRunner(), service: service)

    XCTAssertEqual(result.outcome, .passed)
    XCTAssertEqual(seen.values.count, 1)
  }

  func testFailingRunnerBlocksPublicationAndLeavesWorktreeAndIndexUnchanged() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = fixture.root.appendingPathComponent("content/posts/target.md")
    try Data("updated target\n".utf8).write(to: target)
    try Data("staged sibling\n".utf8).write(to: fixture.root.appendingPathComponent("staged.md"))
    _ = try git(["add", "--", "staged.md"], at: fixture.root)
    let beforeIndex = try git(["diff", "--cached", "--binary"], at: fixture.root)
    let beforeStatus = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.root)
    let targetData = try Data(contentsOf: target)
    let blob = try git(["hash-object", target.path], at: fixture.root).trimmedForPublishing
    let snapshot = fixture.snapshot(entries: [
      .init(
        kind: .modified, status: " M", path: "content/posts/target.md",
        byteSize: Int64(targetData.count), mode: "100644", blobOID: blob)
    ])
    let service = RepositoryPublishPreflightService(
      commandRunner: RepositoryPublishPreflightCommandRunner { _ in
        .init(termination: .exited, exitStatus: 1, standardError: "rejected")
      }, trustedZolaExecutable: { "/usr/local/bin/zola" })

    let result = try RepositoryScopedPreflight.run(
      profile: fixture.profile, snapshot: snapshot, git: GitCommandRunner(), service: service)

    XCTAssertTrue(result.blocksPublication)
    XCTAssertEqual(result.outcome, .failed(.checkFailed))
    XCTAssertEqual(try git(["diff", "--cached", "--binary"], at: fixture.root), beforeIndex)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.root), beforeStatus
    )
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.root).trimmedForPublishing, fixture.head)
  }

  func testSnapshotDeletionRemovesTargetFromOverlay() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = fixture.snapshot(entries: [
      .init(kind: .deleted, status: " D", path: "content/posts/target.md")
    ])
    let runner = RepositoryPublishPreflightCommandRunner { command in
      let root = URL(fileURLWithPath: command.workingDirectoryPath)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("content/posts/target.md").path))
      return .init(termination: .exited, exitStatus: 0)
    }
    let service = RepositoryPublishPreflightService(
      commandRunner: runner, trustedZolaExecutable: { "/usr/local/bin/zola" })

    let result = try RepositoryScopedPreflight.run(
      profile: fixture.profile, snapshot: snapshot, git: GitCommandRunner(), service: service)

    XCTAssertEqual(result.outcome, .passed)
  }

  func testBaselineSymlinkIsRejectedBeforeSiteRunner() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("content/posts/escape.md"),
      withDestinationURL: URL(fileURLWithPath: "/tmp/outside.md"))
    _ = try git(["add", "--", "content/posts/escape.md"], at: fixture.root)
    _ = try git(["commit", "-m", "symlink"], at: fixture.root)
    let currentHead = try git(["rev-parse", "HEAD"], at: fixture.root).trimmedForPublishing
    let snapshot = fixture.snapshot(entries: [], head: currentHead)
    let called = LockedBool()
    let service = RepositoryPublishPreflightService(
      commandRunner: RepositoryPublishPreflightCommandRunner { _ in
        called.setTrue()
        return .init(termination: .exited, exitStatus: 0)
      }, trustedZolaExecutable: { "/usr/local/bin/zola" })

    XCTAssertThrowsError(
      try RepositoryScopedPreflight.run(
        profile: fixture.profile, snapshot: snapshot, git: GitCommandRunner(), service: service)
    ) {
      XCTAssertEqual(
        $0 as? RepositoryWorktreePublishError,
        .invalidRepository("单篇构建快照不能包含符号链接或未展开的子模块。"))
    }
    XCTAssertFalse(called.value)
  }

  private struct Fixture {
    let root: URL
    let profile: SiteProfile
    let head: String

    func snapshot(entries: [RepositoryWorktreePublishEntry], head: String? = nil)
      -> RepositoryWorktreePublishSnapshot
    {
      .init(
        repositoryRoot: root.path, gitCommonDirectory: root.appendingPathComponent(".git").path,
        branch: "main", headSHA: head ?? self.head, originURL: "https://example.invalid/site.git",
        remoteBranchSHA: head ?? self.head, statusFingerprint: "", entries: entries)
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-scoped-preflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let posts = root.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
    try Data("base_url = \"https://example.invalid\"\n".utf8).write(
      to: root.appendingPathComponent("config.toml"))
    try Data("original target\n".utf8).write(to: posts.appendingPathComponent("target.md"))
    let git = GitCommandRunner()
    XCTAssertEqual(git.run(["init", "-b", "main"], rootURL: root).terminationStatus, 0)
    XCTAssertEqual(
      git.run(["config", "user.email", "tests@example.invalid"], rootURL: root).terminationStatus, 0
    )
    XCTAssertEqual(git.run(["config", "user.name", "Tests"], rootURL: root).terminationStatus, 0)
    XCTAssertEqual(git.run(["add", "."], rootURL: root).terminationStatus, 0)
    XCTAssertEqual(git.run(["commit", "-m", "fixture"], rootURL: root).terminationStatus, 0)
    let head = git.run(["rev-parse", "HEAD"], rootURL: root).standardOutput.trimmedForPublishing
    return Fixture(
      root: root, profile: SiteProfile(name: "Zola", localRepositoryRootPath: root.path), head: head
    )
  }

  private func git(_ arguments: [String], at root: URL) throws -> String {
    let result = GitCommandRunner().run(arguments, rootURL: root)
    guard result.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryScopedPreflightTests", code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.standardOutput
  }
}

private final class LockedStringSet: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = Set<String>()
  var values: Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func insert(_ value: String) {
    lock.lock()
    stored.insert(value)
    lock.unlock()
  }
}

private final class LockedBool: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func setTrue() {
    lock.lock()
    stored = true
    lock.unlock()
  }
}

final class RepositoryDraftSourceReviewTests: XCTestCase {
  func testDraftSourceIsWarnedAsPublicRepositoryContent() throws {
    let fixture = try makeFixture(frontMatter: "draft: true")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let diagnostics = try RepositoryDraftSourceReview.diagnostics(
      snapshot: fixture.snapshot(path: "content/posts/draft.md"))

    XCTAssertEqual(diagnostics.map(\.code), [.draftSourcePublication])
    XCTAssertEqual(diagnostics.first?.severity, .warning)
    XCTAssertEqual(diagnostics.first?.paths, ["content/posts/draft.md"])
  }

  func testPublishedSourceHasNoDraftSourceWarning() throws {
    let fixture = try makeFixture(frontMatter: "draft: false")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertTrue(
      try RepositoryDraftSourceReview.diagnostics(
        snapshot: fixture.snapshot(path: "content/posts/draft.md")
      ).isEmpty)
  }

  private struct Fixture {
    let root: URL
    let head: String

    func snapshot(path: String) -> RepositoryWorktreePublishSnapshot {
      .init(
        repositoryRoot: root.path, gitCommonDirectory: root.appendingPathComponent(".git").path,
        branch: "main", headSHA: head, originURL: "https://example.invalid/site.git",
        remoteBranchSHA: head, statusFingerprint: "",
        entries: [.init(kind: .modified, status: " M", path: path)])
    }
  }

  private func makeFixture(frontMatter: String) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-draft-source-review-\(UUID().uuidString)", isDirectory: true)
    let article = root.appendingPathComponent("content/posts/draft.md")
    try FileManager.default.createDirectory(
      at: article.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "---\ntitle: Article\n\(frontMatter)\n---\n\nBody\n".write(
      to: article, atomically: true, encoding: .utf8)
    let git = GitCommandRunner()
    XCTAssertEqual(git.run(["init", "-b", "main"], rootURL: root).terminationStatus, 0)
    XCTAssertEqual(git.run(["add", "."], rootURL: root).terminationStatus, 0)
    XCTAssertEqual(
      git.run(
        [
          "-c", "user.email=tests@example.invalid", "-c", "user.name=Tests", "commit", "-m",
          "fixture",
        ], rootURL: root
      ).terminationStatus, 0)
    return Fixture(
      root: root,
      head: git.run(["rev-parse", "HEAD"], rootURL: root).standardOutput.trimmedForPublishing)
  }
}
