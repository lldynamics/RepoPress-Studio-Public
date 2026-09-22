import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class LocalRepositoryGitStatusReadOnlyTests: XCTestCase {
  func testRepeatedStatusDoesNotRefreshTheIndexForUnchangedFileContents() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPressReadOnlyStatus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.name", "RepoPress Tests"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.invalid"], rootURL: rootURL)
    let articleURL = rootURL.appendingPathComponent("article.md")
    try Data("# Unchanged article\n".utf8).write(to: articleURL)
    try git(["add", "article.md"], rootURL: rootURL)
    try git(["-c", "commit.gpgSign=false", "commit", "-m", "Initial"], rootURL: rootURL)

    let indexURL = rootURL.appendingPathComponent(".git/index")
    let originalIndex = try Data(contentsOf: indexURL)
    let originalIndexAttributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)

    // A stale stat cache makes ordinary `git status` rewrite the index even
    // though the article content is unchanged. That write can restart the
    // repository watcher and cause an endless background scan cycle.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
      ofItemAtPath: articleURL.path
    )

    let service = LocalRepositoryService()
    for _ in 0..<3 {
      let status = service.gitStatus(rootURL: rootURL)
      XCTAssertNotNil(status.branchStatus)
      XCTAssertTrue(status.changedFiles.isEmpty)
      XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
      let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
      XCTAssertEqual(
        attributes[.modificationDate] as? Date,
        originalIndexAttributes[.modificationDate] as? Date
      )
    }

    // Suppressing the optional index refresh must not hide a real edit.
    try Data("# Edited article\n".utf8).write(to: articleURL)
    let changedStatus = service.gitStatus(rootURL: rootURL)
    XCTAssertEqual(changedStatus.changedFiles.map(\.destinationPath), ["article.md"])
    XCTAssertEqual(changedStatus.changedFiles.first?.kind, .modified)
    XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    try gitTestCommand(
      arguments,
      rootURL: rootURL,
      errorDomain: "LocalRepositoryGitStatusReadOnlyTests"
    )
  }
}
