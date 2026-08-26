import XCTest
@testable import PublishingWorkbenchCore

final class SiteProfileRepositoryPathTests: XCTestCase {
  func testResolvesLocalRepositoryRootFromStoredPath() throws {
    let rootURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL
      .appendingPathComponent("nested/../", isDirectory: true)
      .path

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
    XCTAssertTrue(profile.rememberLocalRepositoryRoot(rootURL))

    XCTAssertEqual(profile.localRepositoryRootPath, rootURL.standardizedFileURL.path)
    XCTAssertEqual(profile.resolvedLocalRepositoryRootURL?.standardizedFileURL.path, rootURL.standardizedFileURL.path)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacPathTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
