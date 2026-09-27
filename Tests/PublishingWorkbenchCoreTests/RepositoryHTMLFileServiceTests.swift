import Darwin
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryHTMLFileServiceTests: XCTestCase {
  private let service = RepositoryHTMLFileService()

  func testListsRegularHTMLFilesWithoutAnEditabilityLimit() throws {
    let fixture = try makeFixture(file: "Page.HTM", contents: "<p>page</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let largeFile = fixture.root.appendingPathComponent("large.html")
    try Data(repeating: 65, count: 5 * 1_024 * 1_024).write(to: largeFile)
    try Data("ignored".utf8).write(to: fixture.root.appendingPathComponent("README.md"))

    let files = try service.listDocuments(profile: fixture.profile)

    XCTAssertEqual(files.map(\.repositoryPath), ["large.html", "Page.HTM"])
    XCTAssertEqual(files.first?.byteSize, 5 * 1_024 * 1_024)
  }

  func testOriginalFileOperationReceivesRepositoryFileURLForLargeHTML() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalURL = fixture.root.appendingPathComponent("pages/large.html")
    try FileManager.default.createDirectory(
      at: originalURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 65, count: 5 * 1_024 * 1_024).write(to: originalURL)

    let result = try service.withOriginalFileURL(
      profile: fixture.profile,
      repositoryPath: "pages/large.html"
    ) { url in
      XCTAssertEqual(
        url.resolvingSymlinksInPath().standardizedFileURL,
        originalURL.resolvingSymlinksInPath().standardizedFileURL
      )
      return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    XCTAssertEqual(result, 5 * 1_024 * 1_024)
  }

  func testOriginalFileOperationRejectsTraversalNonHTMLAndFileSymlink() throws {
    let fixture = try makeFixture(file: "index.html", contents: "<p>safe</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: fixture.profile, repositoryPath: "../index.html") {
        _ in
      }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .unsafeRepositoryPath)
    }
    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: fixture.profile, repositoryPath: "README.md") { _ in
      }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .unsupportedFileType)
    }

    let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".html")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("linked.html"),
      withDestinationURL: outside
    )
    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: fixture.profile, repositoryPath: "linked.html") {
        _ in
      }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .symbolicLinkNotAllowed)
    }
  }

  func testOriginalFileOperationRejectsIntermediateDirectorySymlinkAndNonRegularFile() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outsideDirectory = fixture.root.deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outsideDirectory) }
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outsideDirectory.appendingPathComponent("page.html"))
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("linked"),
      withDestinationURL: outsideDirectory
    )
    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: fixture.profile, repositoryPath: "linked/page.html")
      { _ in }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .symbolicLinkNotAllowed)
    }

    let fifoURL = fixture.root.appendingPathComponent("pipe.html")
    XCTAssertEqual(Darwin.mkfifo(fifoURL.path, mode_t(0o600)), 0)
    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: fixture.profile, repositoryPath: "pipe.html") { _ in
      }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .fileNotFound)
    }
  }

  func testOriginalFileOperationRejectsRepositoryRootSymlink() throws {
    let fixture = try makeFixture(file: "index.html", contents: "<p>safe</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let linkURL = fixture.root.deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: linkURL) }
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fixture.root)
    let linkedProfile = SiteProfile(name: "Test Site", localRepositoryRootPath: linkURL.path)

    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: linkedProfile, repositoryPath: "index.html") { _ in }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .symbolicLinkNotAllowed)
    }
  }

  func testDirectDescriptorResolvesHiddenAndExcludedTrackedPaths() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for path in [".well-known/site.html", "vendor/template.html"] {
      let url = fixture.root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("<p>tracked</p>".utf8).write(to: url)
      let descriptor = try service.descriptor(profile: fixture.profile, repositoryPath: path)
      XCTAssertEqual(descriptor.repositoryPath, path)
      XCTAssertGreaterThan(descriptor.byteSize, 0)
    }
    XCTAssertTrue(try service.listDocuments(profile: fixture.profile).isEmpty)
  }

  func testFinderAliasIsNotListedOrOpened() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".html")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside".utf8).write(to: outside)
    let alias = fixture.root.appendingPathComponent("external.html")
    let bookmark = try outside.bookmarkData(
      options: [.suitableForBookmarkFile],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    try URL.writeBookmarkData(bookmark, to: alias)
    XCTAssertEqual(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile, true)

    XCTAssertFalse(
      try service.listDocuments(profile: fixture.profile).contains {
        $0.repositoryPath == "external.html"
      }
    )
    XCTAssertThrowsError(
      try service.withOriginalFileURL(profile: fixture.profile, repositoryPath: "external.html") {
        _ in
      }
    ) {
      XCTAssertEqual($0 as? RepositoryHTMLFileError, .aliasFileNotAllowed)
    }
  }

  private func makeFixture(
    file: String? = nil,
    contents: String = ""
  ) throws -> (root: URL, profile: SiteProfile) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("html-source-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let file {
      let url = root.appendingPathComponent(file)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(contents.utf8).write(to: url)
    }
    return (root, SiteProfile(name: "Test Site", localRepositoryRootPath: root.path))
  }
}
