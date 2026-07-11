import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ReleaseQualityGateProjectRootResolverTests: XCTestCase {
  @MainActor
  func testDefaultStoreRefreshCompletesWithoutFallingBackToFilesystemRoot() async throws {
    let persistenceDirectory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "ReleaseQualityGateBackgroundRefreshTests"
    )
    defer { try? FileManager.default.removeItem(at: persistenceDirectory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: persistenceDirectory.appendingPathComponent("workbench.json")
      )
    )

    store.refreshReleaseQualityGate()
    for _ in 0..<250 where store.isReleaseQualityGateRefreshing {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertFalse(store.isReleaseQualityGateRefreshing)
    XCTAssertFalse(store.releaseQualityGateReport.projectRootPath.isEmpty)
    XCTAssertNotEqual(store.releaseQualityGateReport.projectRootPath, "/")
  }

  func testFindsProjectRootAboveAppBundleInsteadOfUsingFilesystemRoot() throws {
    let root = try makeProjectRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("dist/PersonalSitePublisherMac.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let resolved = ReleaseQualityGateProjectRootResolver(environment: [:]).resolve(
      explicitRoot: nil,
      bundleURL: bundleURL,
      currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true)
    )

    XCTAssertEqual(resolved, root.standardizedFileURL)
  }

  func testEnvironmentProjectRootTakesPriority() throws {
    let environmentRoot = try makeProjectRoot()
    let bundleRoot = try makeProjectRoot()
    defer {
      try? FileManager.default.removeItem(at: environmentRoot)
      try? FileManager.default.removeItem(at: bundleRoot)
    }

    let resolved = ReleaseQualityGateProjectRootResolver(environment: [
      ReleaseQualityGateProjectRootResolver.environmentKey: environmentRoot.path
    ]).resolve(
      explicitRoot: nil,
      bundleURL: bundleRoot,
      currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true)
    )

    XCTAssertEqual(resolved, environmentRoot.standardizedFileURL)
  }

  func testReturnsNilWhenNoVerifiedProjectRootExists() {
    let resolved = ReleaseQualityGateProjectRootResolver(environment: [:]).resolve(
      explicitRoot: nil,
      bundleURL: URL(fileURLWithPath: "/Applications/PersonalSitePublisherMac.app", isDirectory: true),
      currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true)
    )

    XCTAssertNil(resolved)
  }

  private func makeProjectRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReleaseQualityGateProjectRootResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("script", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data().write(to: root.appendingPathComponent("Package.swift"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("script/release_checks.json"))
    return root
  }
}
