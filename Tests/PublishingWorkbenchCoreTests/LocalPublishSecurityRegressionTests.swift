import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class LocalPublishSecurityRegressionTests: XCTestCase {
  func testRecoveryRejectsGitControlPathVariantsWithoutChangingConfig() throws {
    let rootURL = try temporaryDirectoryURL(prefix: "RepoPressPublishSecurity")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
    let configURL = gitURL.appendingPathComponent("config")
    let originalConfig = "[core]\n\trepositoryformatversion = 0\n"
    try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)

    let rollbackDirectory = rootURL.appendingPathComponent(
      ".repopress-local-publish-rollback-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: rollbackDirectory, withIntermediateDirectories: true)
    let service = LocalPublishPreviewService()
    let variants = [
      ".git/config",
      ".GIT/config",
      "./.git/config",
      "content/../.git/config",
      ".git\\config",
    ]

    for repositoryPath in variants {
      let transaction = LocalPublishTransaction(
        phase: .applying,
        rollbackDirectoryPath: rollbackDirectory.path,
        entries: [
          LocalPublishTransactionEntry(
            repositoryPath: repositoryPath,
            backupFileName: nil
          )
        ]
      )
      let transactionURL = service.localPublishTransactionURL(for: rootURL)
      try JSONEncoder().encode(transaction).write(to: transactionURL, options: [.atomic])

      XCTAssertThrowsError(
        try service.recoverInterruptedTransaction(at: rootURL),
        "Git control path must be rejected: \(repositoryPath)"
      ) { error in
        guard case LocalPublishPreviewError.recoveryFailed = error else {
          return XCTFail("Expected recoveryFailed for \(repositoryPath), got \(error)")
        }
      }
      XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), originalConfig)
    }
  }

  func testValidContentRecoveryStillAllowsTheNextPublish() throws {
    let rootURL = try temporaryDirectoryURL(prefix: "RepoPressPublishRecovery")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let articleURL = rootURL.appendingPathComponent("content/posts/article.md")
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let originalContent = "original article\n"
    try originalContent.write(to: articleURL, atomically: true, encoding: .utf8)

    let rollbackDirectory = rootURL.appendingPathComponent(
      ".repopress-local-publish-rollback-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: rollbackDirectory, withIntermediateDirectories: true)
    try originalContent.write(
      to: rollbackDirectory.appendingPathComponent("0-backup"),
      atomically: true,
      encoding: .utf8
    )
    try "interrupted article\n".write(to: articleURL, atomically: true, encoding: .utf8)

    let service = LocalPublishPreviewService()
    let transaction = LocalPublishTransaction(
      phase: .applying,
      rollbackDirectoryPath: rollbackDirectory.path,
      entries: [
        LocalPublishTransactionEntry(
          repositoryPath: "content/posts/article.md",
          backupFileName: "0-backup"
        )
      ]
    )
    try JSONEncoder().encode(transaction).write(
      to: service.localPublishTransactionURL(for: rootURL),
      options: [.atomic]
    )

    try service.recoverInterruptedTransaction(at: rootURL)

    XCTAssertEqual(try String(contentsOf: articleURL, encoding: .utf8), originalContent)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: service.localPublishTransactionURL(for: rootURL).path
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory.path))

    let package = makePackage(
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/article.md",
          content: "next article\n"
        )
      ]
    )
    XCTAssertEqual(
      try service.write(package: package, rootURL: rootURL),
      ["content/posts/article.md"]
    )
    XCTAssertEqual(try String(contentsOf: articleURL, encoding: .utf8), "next article\n")
  }

  func testNormalWriteRejectsGitControlPathBeforeTouchingConfig() throws {
    let rootURL = try temporaryDirectoryURL(prefix: "RepoPressPublishPath")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
    let configURL = gitURL.appendingPathComponent("config")
    let originalConfig = "safe-config\n"
    try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)

    let package = makePackage(
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/../.GIT/config",
          content: "malicious-config\n"
        )
      ]
    )
    XCTAssertThrowsError(try LocalPublishPreviewService().write(package: package, rootURL: rootURL))
    XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), originalConfig)
  }

  private func makePackage(files: [PublishPackageFile]) -> PublishPackage {
    PublishPackage(
      draftID: UUID(),
      title: "Security regression",
      markdownPath: files.first?.repositoryPath ?? "content/posts/article.md",
      files: files,
      commitMessage: "Security regression",
      reviewBranchName: "security-regression",
      reviewTitle: "Security regression",
      reviewChecklist: []
    )
  }
}
