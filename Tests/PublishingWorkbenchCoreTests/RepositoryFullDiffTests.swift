import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryFullDiffTests: XCTestCase {
  func testFullDiffKeepsLocalStagedUnstagedAndUntrackedTails() throws {
    let (rootURL, profile) = try makeRepository(named: "local")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = LocalRepositoryService()
    let trackedPath = "content/posts/large.md"

    try write(lines(prefix: "base", count: 190), to: rootURL, path: trackedPath)
    try git(["add", trackedPath], at: rootURL)
    try git(["commit", "-m", "Add large article"], at: rootURL)

    var staged = lines(prefix: "staged", count: 190)
    staged += "\nstaged-tail-190"
    try write(staged, to: rootURL, path: trackedPath)
    try git(["add", trackedPath], at: rootURL)
    try write(staged + "\nunstaged-tail-after-stage", to: rootURL, path: trackedPath)

    let tracked = try XCTUnwrap(
      service.gitStatus(rootURL: rootURL).changedFiles.first { $0.destinationPath == trackedPath }
    )
    let trackedDiff = try service.fullDiff(for: tracked, profile: profile)
    XCTAssertTrue(trackedDiff.contains("+staged-tail-190"))
    XCTAssertTrue(trackedDiff.contains("+unstaged-tail-after-stage"))
    XCTAssertGreaterThan(
      trackedDiff.split(separator: "\n", omittingEmptySubsequences: false).count, 160)

    let untrackedPath = "content/posts/untracked-large.md"
    try write(
      lines(prefix: "untracked", count: 190) + "\nuntracked-tail-190", to: rootURL,
      path: untrackedPath)
    let untracked = try XCTUnwrap(
      service.gitStatus(rootURL: rootURL).changedFiles.first { $0.destinationPath == untrackedPath }
    )
    let untrackedDiff = try service.fullDiff(for: untracked, profile: profile)
    XCTAssertTrue(untrackedDiff.contains("+untracked-tail-190"))
    XCTAssertGreaterThan(
      untrackedDiff.split(separator: "\n", omittingEmptySubsequences: false).count, 160)
  }

  func testFullDiffKeepsRemoteTailBeyondPreviewLimit() throws {
    let (rootURL, profile) = try makeRepository(named: "remote")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = LocalRepositoryService()
    let path = "content/posts/remote-large.md"

    try write(lines(prefix: "base", count: 190), to: rootURL, path: path)
    try git(["add", path], at: rootURL)
    try git(["commit", "-m", "Add base article"], at: rootURL)
    try git(["switch", "-c", "remote-work"], at: rootURL)
    try write(lines(prefix: "remote", count: 190) + "\nremote-tail-190", to: rootURL, path: path)
    try git(["add", path], at: rootURL)
    try git(["commit", "-m", "Remote large change"], at: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], at: rootURL)
    try git(["switch", "main"], at: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], at: rootURL)

    let remote = try XCTUnwrap(
      service.remoteChangedFiles(rootURL: rootURL, upstreamName: "origin/main")
        .first { $0.destinationPath == path }
    )
    let remoteDiff = try service.fullDiff(
      for: remote,
      profile: profile,
      upstreamName: "origin/main"
    )

    XCTAssertTrue(remoteDiff.contains("+remote-tail-190"))
    XCTAssertGreaterThan(
      remoteDiff.split(separator: "\n", omittingEmptySubsequences: false).count, 160)
  }

  func testFullDiffRejectsGitRunnerOutputTruncation() throws {
    let (rootURL, profile) = try makeRepository(named: "truncated")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let path = "content/posts/truncated.md"

    try write(lines(prefix: "base", count: 190), to: rootURL, path: path)
    try git(["add", path], at: rootURL)
    try git(["commit", "-m", "Add article"], at: rootURL)
    try write(lines(prefix: "changed", count: 190) + "\ntruncation-tail", to: rootURL, path: path)

    let file = try XCTUnwrap(
      LocalRepositoryService().gitStatus(rootURL: rootURL).changedFiles
        .first { $0.destinationPath == path }
    )
    let service = LocalRepositoryService(
      gitCommandRunner: GitCommandRunner(maximumOutputBytes: 96)
    )

    XCTAssertThrowsError(try service.fullDiff(for: file, profile: profile)) { error in
      guard case .outputTruncated = error as? RepositoryFullDiffError else {
        return XCTFail("Expected outputTruncated, got \(error)")
      }
    }
  }

  private func makeRepository(named name: String) throws -> (URL, SiteProfile) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RepositoryFullDiffTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], at: rootURL)
    try git(["config", "user.email", "tests@example.com"], at: rootURL)
    try git(["config", "user.name", "Tests"], at: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    return (rootURL, profile)
  }

  private func lines(prefix: String, count: Int) -> String {
    (1...count).map { "\(prefix)-line-\($0)" }.joined(separator: "\n")
  }

  private func write(_ contents: String, to rootURL: URL, path: String) throws {
    let fileURL = rootURL.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  @discardableResult
  private func git(_ arguments: [String], at rootURL: URL) throws -> String {
    let result = GitCommandRunner().run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryFullDiffTests",
        code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output]
      )
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
