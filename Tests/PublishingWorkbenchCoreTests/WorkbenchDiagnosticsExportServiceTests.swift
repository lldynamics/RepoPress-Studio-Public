import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchDiagnosticsExportServiceTests: XCTestCase {
  func testSanitizedContextRemovesURLsUsernamesAndCredentialValues() {
    let context = WorkbenchDiagnosticsContext(
      appVersion: "1.0",
      buildVersion: "42",
      isSafeMode: false,
      isQuickHideActive: false,
      hasPersistenceRecoveryMessage: false,
      draftCount: 1,
      pendingDraftRecoveryCount: 0,
      profileCount: 1,
      activeSiteKind: "Zola",
      repositoryProvider: "GitHub",
      hasLocalRepository: true,
      hasRepositoryToken: true,
      hasDeploymentToken: true,
      lastSaveStatus: "失败",
      statusMessages: [
        "remote=https://alice:url-secret@example.com/site.git?token=url-token",
        "Authorization: Bearer bearer-secret token=token-secret sk-abcdefghijklmnopqrstuvwxyz",
      ]
    )

    let sanitized = WorkbenchDiagnosticsExportService.sanitized(context)
    let text = sanitized.statusMessages.joined(separator: "\n")

    XCTAssertFalse(text.contains("alice"))
    XCTAssertFalse(text.contains("url-secret"))
    XCTAssertFalse(text.contains("url-token"))
    XCTAssertFalse(text.contains("bearer-secret"))
    XCTAssertFalse(text.contains("token-secret"))
    XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuvwxyz"))
    XCTAssertTrue(text.contains("https://example.com/site.git"))
    XCTAssertTrue(text.contains("[REDACTED]"))
  }

  func testUserInitiatedExportCreatesZipWithoutWorkspaceContent() throws {
    let directoryURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "DiagnosticsExport")
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let context = WorkbenchDiagnosticsContext(
      appVersion: "1.0",
      buildVersion: "42",
      isSafeMode: true,
      isQuickHideActive: false,
      hasPersistenceRecoveryMessage: true,
      draftCount: 4,
      pendingDraftRecoveryCount: 1,
      profileCount: 2,
      activeSiteKind: "Zola",
      repositoryProvider: "GitHub",
      hasLocalRepository: true,
      hasRepositoryToken: true,
      hasDeploymentToken: true,
      lastSaveStatus: "已保存",
      statusMessages: ["正文不应进入诊断包：这是用户草稿正文。"]
    )

    let archiveURL = try WorkbenchDiagnosticsExportService().export(
      context: context,
      to: directoryURL
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    XCTAssertGreaterThan(try Data(contentsOf: archiveURL).count, 0)
    XCTAssertTrue(archiveURL.lastPathComponent.hasPrefix("RepoPress-Diagnostics-"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("workbench.json").path))
  }
}
