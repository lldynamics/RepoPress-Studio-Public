import XCTest
@testable import PublishingWorkbenchCore

final class SiteProfileRepositoryBookmarkTests: XCTestCase {
  func testResolvesLocalRepositoryRootFromBookmarkWhenPathIsStale() throws {
    let rootURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/stale/path"
    profile.localRepositoryBookmarkData = try rootURL.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    XCTAssertEqual(profile.resolvedLocalRepositoryRootURL?.standardizedFileURL.path, rootURL.standardizedFileURL.path)

    let resolvedPath = try XCTUnwrap(
      profile.withLocalRepositoryRootAccess { url in
        url.standardizedFileURL.path
      }
    )
    XCTAssertEqual(resolvedPath, rootURL.standardizedFileURL.path)
  }

  func testRememberLocalRepositoryRootAlwaysStoresReadablePath() throws {
    let rootURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    _ = profile.rememberLocalRepositoryRoot(rootURL)

    XCTAssertEqual(profile.localRepositoryRootPath, rootURL.standardizedFileURL.path)
    XCTAssertEqual(profile.resolvedLocalRepositoryRootURL?.standardizedFileURL.path, rootURL.standardizedFileURL.path)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacBookmarkTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
