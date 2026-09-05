import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryRebaseRecoveryStoreTests: XCTestCase {
  func testRoundTripsAndRemovesProfileScopedRecoveryRecord() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileID = UUID()
    let store = RepositoryRebaseRecoveryStore(recoveryArchiveDirectoryURL: root)
    let context = recoveryContext(phase: .stashRestoreInProgress)

    try store.save(context, profileID: profileID)
    XCTAssertEqual(try store.load(profileID: profileID), context)

    try store.remove(profileID: profileID)
    XCTAssertNil(try store.load(profileID: profileID))
  }

  func testRejectsCorruptRecoveryRecord() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileID = UUID()
    let store = RepositoryRebaseRecoveryStore(recoveryArchiveDirectoryURL: root)
    try store.save(recoveryContext(phase: .rebaseConflict), profileID: profileID)

    let recordURL = root
      .appendingPathComponent("RepositoryRebaseRecovery", isDirectory: true)
      .appendingPathComponent(profileID.uuidString.lowercased() + ".json")
    try Data("not-json".utf8).write(to: recordURL, options: .atomic)

    XCTAssertThrowsError(try store.load(profileID: profileID)) { error in
      XCTAssertEqual(
        error as? RepositoryRebaseRecoveryStoreError,
        .invalidRecord
      )
    }
  }

  private func recoveryContext(
    phase: RepositoryRebaseRecoveryContext.Phase
  ) -> RepositoryRebaseRecoveryContext {
    RepositoryRebaseRecoveryContext(
      repositoryRoot: "/tmp/site",
      gitCommonDirectory: "/tmp/site/.git",
      branch: "main",
      originalHeadSHA: String(repeating: "1", count: 40),
      reviewedRemoteHeadSHA: String(repeating: "2", count: 40),
      stashCommitSHA: String(repeating: "3", count: 40),
      phase: phase,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RepositoryRebaseRecoveryStoreTests-" + UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
