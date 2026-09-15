import Foundation
import XCTest
@testable import PublishingWorkbenchCore

extension WorkbenchStoreProfileTests {
  func repositoryTokenStoreForTest() -> KeychainTokenStore {
    KeychainTokenStore(
      service: "PSPMRepoTests.\(UUID().uuidString.prefix(8))",
      accountPrefix: "repo-test",
      inMemory: true
    )
  }

  func preparedGitRepositoryRoot() throws -> URL {
    let rootURL = try temporaryDirectoryURL()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    return rootURL
  }

  func fixedDate() -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 8
    components.day = 29
    components.hour = 10
    return components.date!
  }

  func remoteArticle(title: String, slug: String, body: String) -> String {
    """
    ---
    title: "\(title)"
    slug: \(slug)
    ---

    \(body)
    """
  }

  @discardableResult
  func git(_ arguments: [String], rootURL: URL) throws -> String {
    try gitTestCommand(
      arguments,
      rootURL: rootURL,
      errorDomain: "WorkbenchStoreProfileTests"
    )
  }
}
