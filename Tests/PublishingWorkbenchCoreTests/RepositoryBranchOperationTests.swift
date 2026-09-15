import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RepositoryBranchOperationTests: XCTestCase {
  @MainActor
  func testRepositoryScanRefreshesBranchAndCommitInventory() async throws {
    let fixture = try makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositoryBranchInventoryTests")
    store.updateActiveProfile(fixture.profile)

    await store.scanRepositoryAsync()

    XCTAssertEqual(store.localRepositoryBranches.first(where: \.isCurrent)?.name, "main")
    XCTAssertEqual(store.localRepositoryRecentCommits.first?.message, "Initial")
  }

  @MainActor
  func testStoreSwitchesRealBranchAndAlignsPublishTarget() async throws {
    let fixture = try makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    try git(["branch", "release"], rootURL: fixture.rootURL)
    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositoryBranchSwitchTests")
    store.updateActiveProfile(fixture.profile)
    await store.scanRepositoryAsync()

    await store.switchActiveProfileRepositoryBranch(to: "release")

    XCTAssertEqual(try git(["branch", "--show-current"], rootURL: fixture.rootURL), "release")
    XCTAssertEqual(store.activeProfile.branch, "release")
    XCTAssertEqual(store.localRepositoryBranches.first(where: \.isCurrent)?.name, "release")
    XCTAssertFalse(store.isLocalRepositoryBranchOperationRunning)
  }

  private func makeRepository() throws -> (rootURL: URL, profile: SiteProfile) {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "RepositoryBranchOperationTests"
    )
    do {
      try git(["init", "-b", "main"], rootURL: rootURL)
      try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
      try git(["config", "user.name", "Tests"], rootURL: rootURL)
      try "initial\n".write(
        to: rootURL.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
      )
      try git(["add", "README.md"], rootURL: rootURL)
      try git(["commit", "-m", "Initial"], rootURL: rootURL)
    } catch {
      try? FileManager.default.removeItem(at: rootURL)
      throw error
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.branch = "main"
    return (rootURL, profile)
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    try gitTestCommand(
      arguments,
      rootURL: rootURL,
      errorDomain: "RepositoryBranchOperationTests"
    )
  }
}
