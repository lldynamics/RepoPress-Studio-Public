import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore
@testable import PublishingWorkbenchCore

final class MenuBarStatusPresentationTests: XCTestCase {
  func testNewerPendingReleaseTakesPrecedenceOverEarlierSuccess() {
    let profile = SiteProfile(name: "Site", localRepositoryRootPath: "/tmp/site")
    let older = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "Earlier",
      summary: "",
      siteProfileID: profile.id,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let newer = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "Newer",
      summary: "",
      siteProfileID: profile.id,
      createdAt: Date(timeIntervalSince1970: 200)
    )
    let local = ReleaseRecord(
      kind: .localWrite,
      title: "Local draft",
      summary: "",
      siteProfileID: profile.id,
      createdAt: Date(timeIntervalSince1970: 300)
    )
    let entries = [
      ReleaseLedgerEntry(
        id: older.id,
        record: older,
        status: .succeeded,
        statusMessage: "Earlier deployment succeeded",
        deploymentStatus: nil,
        rollbackDraft: nil
      ),
      ReleaseLedgerEntry(
        id: newer.id,
        record: newer,
        status: .pendingDeployment,
        statusMessage: "Check pending",
        deploymentStatus: nil,
        rollbackDraft: nil
      ),
      ReleaseLedgerEntry(
        id: local.id,
        record: local,
        status: .localOnly,
        statusMessage: "Local only",
        deploymentStatus: nil,
        rollbackDraft: nil
      ),
    ]

    let presentation = MenuBarStatusPresentation(profile: profile, report: nil, entries: entries)

    XCTAssertEqual(
      presentation.deploymentSummary, ReleaseLedgerStatus.pendingDeployment.localizedDisplayName)
    XCTAssertEqual(presentation.repositorySummary, String(localized: "尚未扫描仓库"))
  }

  func testUnconfiguredRepositoryAndMissingDeploymentRemainUnknown() {
    let profile = SiteProfile(name: "Notes")
    let presentation = MenuBarStatusPresentation(profile: profile, report: nil, entries: [])

    XCTAssertEqual(presentation.repositorySummary, String(localized: "未配置本地仓库"))
    XCTAssertEqual(presentation.deploymentSummary, String(localized: "尚无部署记录"))
    XCTAssertNil(presentation.repositoryScannedAt)
    XCTAssertNil(presentation.deploymentCheckedAt)
  }

  func testGitSummaryCountsUncommittedFilesOnlyAfterValidScan() {
    let profile = SiteProfile(name: "Site", localRepositoryRootPath: "/tmp/site")
    let scannedAt = Date(timeIntervalSince1970: 400)
    let report = RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: nil,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [.init(status: " M", path: "post.md", kind: .modified)],
      preflightIssues: [],
      scannedAt: scannedAt
    )

    let presentation = MenuBarStatusPresentation(profile: profile, report: report, entries: [])

    XCTAssertTrue(presentation.repositorySummary.contains("1"))
    XCTAssertNotEqual(presentation.repositorySummary, String(localized: "工作区干净"))
    XCTAssertEqual(presentation.repositoryScannedAt, scannedAt)
  }

  @MainActor
  func testQuickCaptureSavesToKnowledgeLibraryAndClearsInput() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MenuBarQuickCapture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let knowledge = KnowledgeStore(service: service)
    let capture = MenuBarQuickCaptureState()
    capture.text = "  Idea title\nDetails  "

    await capture.save(using: knowledge)

    let note = try XCTUnwrap(service.notes().first)
    XCTAssertEqual(note.title, "Idea title")
    XCTAssertEqual(note.markdown, "Idea title\nDetails")
    XCTAssertEqual(capture.text, "")
  }
}
