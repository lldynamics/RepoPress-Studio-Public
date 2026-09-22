import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class PublishExecutionRecordTests: RemoteRepositoryPublishServiceTestCase {
  private func package(content: String = "# Frozen") -> PublishPackage {
    PublishPackage(
      draftID: UUID(), title: "Frozen", markdownPath: "content/frozen.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/frozen.md", content: content)
      ],
      commitMessage: "Publish frozen", reviewBranchName: "publish/frozen",
      reviewTitle: "Publish frozen", reviewChecklist: [])
  }

  private func preview(mode: RemoteRepositoryPublishMode = .directCommit)
    -> RemoteRepositoryPublishPreview
  {
    RemoteRepositoryPublishPreview(
      provider: .github, repositoryName: "owner/site", mode: mode,
      branchName: mode == .directCommit ? "main" : "publish/frozen", targetBranch: "main",
      changedPaths: ["content/frozen.md"], hasToken: true,
      accessCheck: RemoteRepositoryAccessCheck(
        provider: .github, repositoryName: "owner/site", defaultBranch: "main",
        canRead: true, canWrite: true, message: "ok"), blockingIssues: [], warningIssues: [])
  }

  func testFreezeExecutionPlanStoresMediaFingerprintAndSurvivesSourceRemoval() throws {
    let source = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "frozen-media-\(UUID().uuidString).bin")
    try Data("media bytes".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let file = PublishPackageFile(
      kind: .image, repositoryPath: "static/media.bin", sourceFilePath: source.path)
    let package = PublishPackage(
      draftID: UUID(), title: "Media", markdownPath: "content/media.md", files: [file],
      commitMessage: "Media", reviewBranchName: "publish/media", reviewTitle: "Media",
      reviewChecklist: [])
    let service = RemoteRepositoryPublishService()
    let frozen = try service.freezeExecutionPlan(
      package: package, batchItems: [], profile: githubProfileForDeletion(),
      preview: RemoteRepositoryPublishPreview(
        provider: .github, repositoryName: "owner/site", mode: .directCommit,
        branchName: "main", targetBranch: "main", changedPaths: [file.repositoryPath],
        hasToken: true,
        accessCheck: RemoteRepositoryAccessCheck(
          provider: .github, repositoryName: "owner/site", defaultBranch: "main", canRead: true,
          canWrite: true, message: "ok"), blockingIssues: [], warningIssues: []))
    XCTAssertEqual(
      frozen.contentSHA256ByPath[file.repositoryPath],
      WorkbenchRecordPayload.digest(Data("media bytes".utf8)))
    XCTAssertEqual(
      frozen.package.files.first?.reviewedSourceSHA256,
      frozen.contentSHA256ByPath[file.repositoryPath])
    try FileManager.default.removeItem(at: source)
    XCTAssertNoThrow(try frozen.validate())
  }

  func testRecordSerializationPreservesPendingStateAndEvents() throws {
    let id = UUID()
    let plan = PublishExecutionPlan(
      package: package(), batchItems: [],
      target: RemoteRepositoryPublishTargetSnapshot(
        profile: githubProfileForDeletion(), preview: preview()),
      branchName: "main",
      contentSHA256ByPath: [
        "content/frozen.md": WorkbenchRecordPayload.digest(Data("# Frozen".utf8))
      ],
      gitBlobSHAByPath: [
        "content/frozen.md": RemoteRepositoryPublishService().gitBlobSHA(for: Data("# Frozen".utf8))
      ])
    var record = PublishExecutionRecord(id: id, plan: plan, now: fixedDate())
    record.observe(RemoteRepositoryPublishProgress(stage: .uploadingFiles, message: "upload"))
    let data = try JSONEncoder().encode(record)
    let restored = try JSONDecoder().decode(PublishExecutionRecord.self, from: data)
    XCTAssertEqual(restored.id, id)
    XCTAssertEqual(restored.state, .awaitingRemoteResult)
    XCTAssertEqual(restored.events.map(\.stage), [.preparing, .uploadingFiles])
    XCTAssertTrue(PublishExecutionRecord.retained([restored]).contains(restored))
  }

  func testRetainedKeepsPendingRecordsWhileCappingTerminalHistory() throws {
    let plan = PublishExecutionPlan(
      package: package(), batchItems: [],
      target: RemoteRepositoryPublishTargetSnapshot(
        profile: githubProfileForDeletion(), preview: preview()),
      branchName: "main",
      contentSHA256ByPath: [
        "content/frozen.md": WorkbenchRecordPayload.digest(Data("# Frozen".utf8))
      ],
      gitBlobSHAByPath: [
        "content/frozen.md": RemoteRepositoryPublishService().gitBlobSHA(for: Data("# Frozen".utf8))
      ])
    let pending = PublishExecutionRecord(id: UUID(), plan: plan)
    var terminal = PublishExecutionRecord(id: UUID(), plan: plan)
    terminal.state = .remoteAccepted
    let retained = PublishExecutionRecord.retained(
      Array(repeating: terminal, count: 101) + [pending])
    XCTAssertEqual(retained.count, 101)
    XCTAssertTrue(retained.contains(pending))
  }
}
