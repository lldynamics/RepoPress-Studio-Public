import XCTest
@testable import PublishingWorkbenchCore

final class LocalRepositoryReleaseHistoryTests: XCTestCase {
  func testReleaseHistoryReadsCommitTagAndNamespacedNote() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPressReleaseHistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try git(["init"], rootURL: rootURL)
    try git(["config", "user.name", "RepoPress Tests"], rootURL: rootURL)
    try git(["config", "user.email", "repopress-tests@example.invalid"], rootURL: rootURL)
    try Data("release\n".utf8).write(to: rootURL.appendingPathComponent("release.txt"))
    try git(["add", "release.txt"], rootURL: rootURL)
    try git(["commit", "-m", "Publish release history"], rootURL: rootURL)
    let commitSHA = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    try git(["tag", "v1.0.0"], rootURL: rootURL)
    try git([
      "notes", "--ref", "refs/notes/repopress/releases", "add", "-m",
      "{\"schema\":1,\"channel\":\"production\",\"title\":\"Release note title\"}",
      commitSHA,
    ], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)

    let snapshot = LocalRepositoryService().releaseHistory(profile: profile)

    XCTAssertEqual(snapshot.historyAvailability, .available)
    XCTAssertEqual(snapshot.notesAvailability, .available)
    XCTAssertEqual(snapshot.commits.first?.sha, commitSHA)
    XCTAssertEqual(snapshot.commits.first?.message, "Publish release history")
    XCTAssertEqual(snapshot.tags.map(\.name), ["v1.0.0"])
    XCTAssertEqual(snapshot.tags.first?.targetSHA, commitSHA)
    XCTAssertEqual(snapshot.notes.first?.commitSHA, commitSHA)
    XCTAssertEqual(snapshot.notes.first?.metadata["channel"], "production")
  }

  func testReleaseHistoryDoesNotDiscoverParentRepository() throws {
    let parentURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPressReleaseHistoryParent-\(UUID().uuidString)", isDirectory: true)
    let childURL = parentURL.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try git(["init"], rootURL: parentURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(childURL)

    let snapshot = LocalRepositoryService().releaseHistory(profile: profile)

    XCTAssertEqual(snapshot.historyAvailability, .unavailable)
    XCTAssertTrue(snapshot.commits.isEmpty)
    XCTAssertEqual(snapshot.diagnostics.first?.source, "repository")
  }

  func testReleaseHistoryCursorDoesNotRepeatPreviousPageBoundary() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPressReleaseHistoryPaging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try git(["init"], rootURL: rootURL)
    try git(["config", "user.name", "RepoPress Tests"], rootURL: rootURL)
    try git(["config", "user.email", "repopress-tests@example.invalid"], rootURL: rootURL)
    for index in 1...4 {
      try Data("release \(index)\n".utf8).write(to: rootURL.appendingPathComponent("release.txt"))
      try git(["add", "release.txt"], rootURL: rootURL)
      try git(["commit", "-m", "Release \(index)"], rootURL: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    let service = LocalRepositoryService()
    let firstPage = service.releaseHistory(
      profile: profile,
      request: .init(limit: 2)
    )
    let cursor = try XCTUnwrap(firstPage.nextCursor)
    let secondPage = service.releaseHistory(
      profile: profile,
      request: .init(limit: 2, cursor: cursor)
    )

    XCTAssertEqual(firstPage.commits.map(\.message), ["Release 4", "Release 3"])
    XCTAssertEqual(secondPage.commits.map(\.message), ["Release 2", "Release 1"])
    XCTAssertFalse(secondPage.commits.map(\.sha).contains(cursor))
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(
      data: output.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    let stderr = String(
      data: errors.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "LocalRepositoryReleaseHistoryTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: stderr]
      )
    }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
