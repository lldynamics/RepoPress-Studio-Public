import Foundation
import XCTest

@testable import PersonalSitePublisherMac
import PublishingWorkbenchCore

@MainActor
final class RepositoryHTMLSourceSessionTests: XCTestCase {
  func testRefreshOpenEditAndSaveRoundTrip() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("<main>initial</main>\n".utf8)
      .write(to: fixture.root.appendingPathComponent("index.html"))
    try Data("ignored".utf8)
      .write(to: fixture.root.appendingPathComponent("README.md"))

    let session = RepositoryHTMLSourceSession()
    await session.refreshFiles(profile: fixture.profile)
    XCTAssertEqual(session.files.map(\.repositoryPath), ["index.html"])

    await session.open(path: "index.html", profile: fixture.profile)
    XCTAssertEqual(session.activeDocument?.text, "<main>initial</main>\n")
    session.updateText("<main>saved</main>\n")
    XCTAssertTrue(session.hasUnsavedChanges)

    let didSave = await session.save(profile: fixture.profile)
    XCTAssertTrue(didSave)
    XCTAssertFalse(session.hasUnsavedChanges)
    XCTAssertEqual(
      try String(
        contentsOf: fixture.root.appendingPathComponent("index.html"),
        encoding: .utf8
      ),
      "<main>saved</main>\n"
    )
    session.close()
  }

  func testExternalModificationKeepsEditedDocumentAndReportsConflict() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fileURL = fixture.root.appendingPathComponent("index.html")
    try Data("<p>initial</p>\n".utf8).write(to: fileURL)

    let session = RepositoryHTMLSourceSession()
    await session.open(path: "index.html", profile: fixture.profile)
    session.updateText("<p>editor</p>\n")
    try Data("<p>external</p>\n".utf8).write(to: fileURL)

    let didSave = await session.save(profile: fixture.profile)
    XCTAssertFalse(didSave)
    XCTAssertTrue(session.hasExternalConflict)
    XCTAssertEqual(session.activeDocument?.text, "<p>editor</p>\n")
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "<p>external</p>\n")
    session.close()
  }

  func testFileFilterMatchesPathCaseInsensitivelyAndPreservesOrdering() {
    let files = [
      descriptor("pages/About.HTML"),
      descriptor("index.html"),
      descriptor("templates/post.htm")
    ]
    XCTAssertEqual(
      RepositoryHTMLSourceFileFilter.filtered(files, query: "  PAGES  ").map(\.repositoryPath),
      ["pages/About.HTML"]
    )
    XCTAssertEqual(
      RepositoryHTMLSourceFileFilter.filtered(files, query: "htm").map(\.repositoryPath),
      files.map(\.repositoryPath)
    )
    XCTAssertEqual(
      RepositoryHTMLSourceFileFilter.filtered(files, query: "   ").map(\.repositoryPath),
      files.map(\.repositoryPath)
    )
  }

  private func descriptor(_ path: String) -> RepositoryHTMLFileDescriptor {
    RepositoryHTMLFileDescriptor(
      repositoryPath: path,
      byteSize: 128,
      modificationDate: nil,
      isEditable: true
    )
  }

  private func makeFixture() throws -> (root: URL, profile: SiteProfile) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "html-source-session-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, SiteProfile(name: "Test Site", localRepositoryRootPath: root.path))
  }
}
