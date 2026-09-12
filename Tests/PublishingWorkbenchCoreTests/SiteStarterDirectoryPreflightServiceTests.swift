import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class SiteStarterDirectoryPreflightServiceTests: XCTestCase {
  func testPreflightReadsZolaDirectoryWithoutChangingIt() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
    )
    try "# First".write(
      to: rootURL.appendingPathComponent("content/posts/first.md"), atomically: true, encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true
    )

    let before = try FileManager.default.contentsOfDirectory(atPath: rootURL.path).sorted()
    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(path: rootURL.path, selectedSiteKind: .zola)
    )

    XCTAssertTrue(result.exists)
    XCTAssertTrue(result.isDirectory)
    XCTAssertTrue(result.isReadable)
    XCTAssertTrue(result.isGitRepository)
    XCTAssertEqual(result.visibleEntryCount, 3)
    XCTAssertEqual(result.detectedSiteKind, .zola)
    XCTAssertEqual(result.detectionEvidence, ["config.toml (Zola)"])
    XCTAssertEqual(result.selectedContentRootPath, "content")
    XCTAssertEqual(result.markdownFileCount, 1)
    XCTAssertEqual(before, try FileManager.default.contentsOfDirectory(atPath: rootURL.path).sorted())
  }

  func testPreflightReportsMissingDirectoryWithoutCreatingIt() throws {
    let rootURL = try makeTemporaryDirectory().appendingPathComponent("missing", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent()) }

    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(path: rootURL.path, selectedSiteKind: .zola)
    )

    XCTAssertFalse(result.exists)
    XCTAssertFalse(result.isDirectory)
    XCTAssertTrue(result.parentIsDirectory)
    XCTAssertTrue(result.parentIsWritable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
  }

  func testPreflightReportsInvalidExistingPathAsReadError() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("not-a-directory")
    try "fixture".write(to: fileURL, atomically: true, encoding: .utf8)

    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(path: fileURL.path, selectedSiteKind: .zola)
    )

    XCTAssertTrue(result.exists)
    XCTAssertFalse(result.isDirectory)
    XCTAssertFalse(result.isReadable)
    XCTAssertEqual(result.readErrorMessage, CoreL10n.text("所选路径不是目录。"))
    XCTAssertNil(result.visibleEntryCount)
  }

  func testPreflightCountsOnlySelectedContentRoot() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content", isDirectory: true), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("docs/posts", isDirectory: true), withIntermediateDirectories: true
    )
    try "# Zola".write(
      to: rootURL.appendingPathComponent("content/zola.md"), atomically: true, encoding: .utf8
    )
    try "# VitePress".write(
      to: rootURL.appendingPathComponent("docs/posts/vitepress.md"), atomically: true, encoding: .utf8
    )

    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(path: rootURL.path, selectedSiteKind: .vitePress)
    )

    XCTAssertEqual(result.selectedContentRootPath, "docs/posts")
    XCTAssertEqual(result.markdownFileCount, 1)
  }

  func testPreflightReportsAmbiguousConfigInsteadOfChoosingFramework() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try "title: Notes".write(
      to: rootURL.appendingPathComponent("_config.yml"), atomically: true, encoding: .utf8
    )

    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(path: rootURL.path, selectedSiteKind: .zola)
    )

    XCTAssertTrue(result.detectionIsAmbiguous)
    XCTAssertNil(result.detectedSiteKind)
    XCTAssertTrue(result.detectionEvidence.joined().contains("Hexo"))
  }

  func testPreflightStopsTraversalWhenCancelled() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content", isDirectory: true), withIntermediateDirectories: true
    )

    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(
        path: rootURL.path,
        selectedSiteKind: .zola,
        cancellationCheck: { true }
      )
    )

    XCTAssertNil(result.markdownFileCount)
    XCTAssertEqual(result.readErrorMessage, CoreL10n.text("目录预检已取消。"))
  }

  func testPreflightCapsLargeContentTraversal() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let contentURL = rootURL.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    for index in 0...SiteStarterDirectoryPreflightService.maximumTraversalEntries {
      try "# \(index)".write(
        to: contentURL.appendingPathComponent("\(index).md"), atomically: true, encoding: .utf8
      )
    }

    let result = try XCTUnwrap(
      SiteStarterDirectoryPreflightService().inspect(path: rootURL.path, selectedSiteKind: .zola)
    )

    XCTAssertTrue(result.traversalWasCapped)
    XCTAssertEqual(result.markdownFileCount, SiteStarterDirectoryPreflightService.maximumTraversalEntries)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SiteStarterDirectoryPreflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
