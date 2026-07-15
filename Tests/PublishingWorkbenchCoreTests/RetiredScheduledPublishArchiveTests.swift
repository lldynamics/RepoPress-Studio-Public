import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class RetiredScheduledPublishArchiveTests: XCTestCase {
  func testSavingLegacySnapshotArchivesScheduledPublishJobsBeforeRemoval() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RetiredScheduledPublishArchive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(
      fileURL: directoryURL.appendingPathComponent("workbench.json")
    )
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any]
    )
    legacyObject["formatVersion"] = 5
    legacyObject["scheduledPublishJobs"] = [[
      "id": "11111111-1111-1111-1111-111111111111",
      "draftTitle": "Legacy scheduled article",
      "status": "scheduled",
    ]]
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: legacyObject).write(
      to: persistence.fileURL,
      options: .atomic
    )

    let loadedSnapshot = try XCTUnwrap(persistence.load())
    XCTAssertEqual(try persistence.save(loadedSnapshot), .saved)

    let savedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
    )
    XCTAssertNil(savedObject["scheduledPublishJobs"])

    let archiveURLs = try FileManager.default.contentsOfDirectory(
      at: persistence.retiredFeatureArchiveDirectoryURL,
      includingPropertiesForKeys: nil
    )
    let archiveURL = try XCTUnwrap(archiveURLs.first)
    let archiveObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any]
    )
    let retiredFields = try XCTUnwrap(archiveObject["retiredFields"] as? [String: Any])
    let jobs = try XCTUnwrap(retiredFields["scheduledPublishJobs"] as? [[String: Any]])
    XCTAssertEqual(jobs.first?["draftTitle"] as? String, "Legacy scheduled article")
  }
}
