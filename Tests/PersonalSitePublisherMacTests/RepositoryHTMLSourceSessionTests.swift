import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class RepositoryHTMLSourceSessionTests: XCTestCase {
  func testRefreshListsHTMLWithoutChangingRepositoryFiles() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("<main>initial</main>\n".utf8)
      .write(to: fixture.root.appendingPathComponent("index.html"))
    try Data("ignored".utf8)
      .write(to: fixture.root.appendingPathComponent("README.md"))

    let session = RepositoryHTMLSourceSession()
    await session.refreshFiles(profile: fixture.profile)
    XCTAssertEqual(session.files.map(\.repositoryPath), ["index.html"])

    XCTAssertEqual(
      try String(
        contentsOf: fixture.root.appendingPathComponent("index.html"),
        encoding: .utf8
      ),
      "<main>initial</main>\n"
    )
  }

  func testQueuedFileRequestCanBeConsumed() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let session = RepositoryHTMLSourceSession()
    session.requestOpen(repositoryPath: "index.html", profile: fixture.profile)
    let request = session.openRequest
    XCTAssertEqual(request?.repositoryPath, "index.html")
    XCTAssertEqual(
      request?.repositoryIdentity,
      RepositoryHTMLSourceRepositoryIdentity(profile: fixture.profile)
    )
    session.consumeOpenRequest(id: UUID())
    XCTAssertEqual(session.openRequest?.id, request?.id)
    if let request { session.consumeOpenRequest(id: request.id) }
    XCTAssertNil(session.openRequest)
  }

  func testRepositorySwitchDropsOldRequestAndFileList() async throws {
    let first = try makeFixture()
    let second = try makeFixture()
    defer {
      try? FileManager.default.removeItem(at: first.root)
      try? FileManager.default.removeItem(at: second.root)
    }
    try Data("first".utf8).write(to: first.root.appendingPathComponent("same.html"))
    try Data("second".utf8).write(to: second.root.appendingPathComponent("other.html"))
    let session = RepositoryHTMLSourceSession()
    await session.refreshFiles(profile: first.profile)
    session.requestOpen(repositoryPath: "same.html", profile: first.profile)

    await session.refreshFiles(profile: second.profile)

    XCTAssertNil(session.openRequest)
    XCTAssertEqual(session.files.map(\.repositoryPath), ["other.html"])
    XCTAssertEqual(
      session.repositoryIdentity,
      RepositoryHTMLSourceRepositoryIdentity(profile: second.profile)
    )
  }

  func testValidatedDeepLinkAddsFileOutsideBrowserScan() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let path = ".well-known/site.html"
    let url = fixture.root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("<p>tracked</p>".utf8).write(to: url)
    let session = RepositoryHTMLSourceSession()
    await session.refreshFiles(profile: fixture.profile)
    XCTAssertTrue(session.files.isEmpty)

    let file = try RepositoryHTMLFileService().descriptor(
      profile: fixture.profile,
      repositoryPath: path
    )
    session.includeValidatedFile(file, profile: fixture.profile)
    XCTAssertEqual(session.files.map(\.repositoryPath), [path])
  }

  func testFileFilterMatchesPathCaseInsensitivelyAndPreservesOrdering() {
    let files = [
      descriptor("pages/About.HTML"),
      descriptor("index.html"),
      descriptor("templates/post.htm"),
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
      modificationDate: nil
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

final class RepositoryContextStageTests: XCTestCase {
  func testPrimaryNavigationOnlyContainsRepositoryInspectionCategories() {
    XCTAssertEqual(
      RepositoryContextStage.navigationStages,
      [.overview, .changes, .source, .history]
    )
  }

  func testSourceFileBrowserHasItsOwnNavigationDestination() {
    XCTAssertEqual(RepositoryContextStage.source.primaryNavigationStage, .source)
  }

  func testOnlyRepositoryIndependentCategoriesRemainAvailableWithoutARepository() {
    XCTAssertFalse(RepositoryContextStage.overview.requiresRepository)
    XCTAssertFalse(RepositoryContextStage.history.requiresRepository)
    XCTAssertTrue(RepositoryContextStage.changes.requiresRepository)
    XCTAssertTrue(RepositoryContextStage.source.requiresRepository)
  }
}

final class OperationalWorkspaceContextStageTests: XCTestCase {
  func testImageWorkbenchNavigationKeepsTaskOrderStable() {
    XCTAssertEqual(
      ImageWorkbenchContextStage.navigationStages,
      [.overview, .resources]
    )
    XCTAssertEqual(
      Set(ImageWorkbenchContextStage.navigationStages.map(\.id)).count,
      ImageWorkbenchContextStage.navigationStages.count
    )
  }

  func testContentHealthNavigationUsesOneProblemList() {
    let expectedFilters: [ContentHealthContextFilter] = [.overview]
    XCTAssertEqual(
      ContentHealthContextFilter.navigationFilters,
      expectedFilters
    )
    XCTAssertEqual(
      Set(ContentHealthContextFilter.navigationFilters.map(\.id)).count,
      ContentHealthContextFilter.navigationFilters.count
    )
  }
}
