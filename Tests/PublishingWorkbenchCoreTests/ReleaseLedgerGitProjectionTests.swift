import XCTest
@testable import PublishingWorkbenchCore

final class ReleaseLedgerGitProjectionTests: XCTestCase {
  func testGitHistoryCreatesLedgerEntryFromCommitTagAndLightweightNote() throws {
    let commitSHA = String(repeating: "a", count: 40)
    let releaseID = UUID(uuidString: "A18A929C-B4B0-44A9-81F0-D3379BC95D90")!
    let commitDate = Date(timeIntervalSince1970: 1_800_000_000)
    var profile = SiteProfile.defaultProfile
    profile.name = "Git First Site"
    profile.branch = "main"

    let history = RepositoryReleaseHistorySnapshot(
      commits: [
        RepositoryCommitInfo(
          sha: commitSHA,
          shortSHA: String(commitSHA.prefix(8)),
          author: "Release Bot",
          date: commitDate,
          message: "Publish from Git\n\nDetails"
        )
      ],
      tags: [
        RepositoryReleaseTag(
          name: "v1.2.0",
          objectSHA: commitSHA,
          subject: "Version 1.2.0"
        )
      ],
      notes: [
        RepositoryReleaseNote(
          commitSHA: commitSHA,
          rawJSON: "{\"schema\":1}",
          metadata: [
            "releaseID": releaseID.uuidString,
            "kind": ReleaseRecordKind.remoteDirectCommit.rawValue,
            "title": "Production publish",
            "channel": "production",
          ]
        )
      ],
      historyAvailability: .available,
      notesAvailability: .available
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [],
      deploymentStatusSnapshots: [:],
      repositoryHistory: history,
      repositoryProfile: profile
    )

    let entry = try XCTUnwrap(ledger.entries.first)
    XCTAssertEqual(entry.id, releaseID)
    XCTAssertEqual(entry.record.kind, .remoteDirectCommit)
    XCTAssertEqual(entry.record.title, "Production publish")
    XCTAssertEqual(entry.record.commitSHA, commitSHA)
    XCTAssertEqual(entry.record.createdAt, commitDate)
    XCTAssertEqual(entry.record.siteProfileID, profile.id)
    XCTAssertTrue(entry.record.summary.contains("v1.2.0"))
    XCTAssertTrue(entry.record.summary.contains("production"))
    XCTAssertEqual(entry.status, .pendingDeployment)
  }

  func testGitHistoryReconcilesExistingMetadataWithoutDuplicatingCommit() throws {
    let commitSHA = String(repeating: "b", count: 40)
    let recordID = UUID()
    let gitDate = Date(timeIntervalSince1970: 1_700_000_000)
    let record = ReleaseRecord(
      id: recordID,
      kind: .remoteDirectCommit,
      title: "App metadata title",
      summary: "App-only deployment context",
      commitSHA: commitSHA.uppercased(),
      createdAt: Date(timeIntervalSince1970: 123)
    )
    let history = RepositoryReleaseHistorySnapshot(
      commits: [
        RepositoryCommitInfo(
          sha: commitSHA,
          shortSHA: String(commitSHA.prefix(8)),
          author: "Git Author",
          date: gitDate,
          message: "Git subject"
        )
      ],
      historyAvailability: .available,
      notesAvailability: .unavailable
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [:],
      repositoryHistory: history,
      repositoryProfile: .defaultProfile
    )

    XCTAssertEqual(ledger.entries.count, 1)
    let projected = try XCTUnwrap(ledger.entries.first?.record)
    XCTAssertEqual(projected.id, recordID)
    XCTAssertEqual(projected.commitSHA, commitSHA)
    XCTAssertEqual(projected.createdAt, gitDate)
    XCTAssertEqual(projected.title, "App metadata title")
    XCTAssertEqual(projected.summary, "App-only deployment context")
  }

  func testUnavailableGitHistoryKeepsLegacyLedgerUnchanged() throws {
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "Offline failure",
      summary: "Keep recovery metadata"
    )
    let history = RepositoryReleaseHistorySnapshot(
      historyAvailability: .unavailable,
      notesAvailability: .unavailable
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [:],
      repositoryHistory: history,
      repositoryProfile: .defaultProfile
    )

    XCTAssertEqual(ledger.entries.map(\.id), [record.id])
    XCTAssertEqual(ledger.entries.first?.record, record)
  }
}
