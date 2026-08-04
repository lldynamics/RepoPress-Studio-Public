import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct WorkbenchStorageUsageServiceTests {
  @Test
  func snapshotCategorizesManagedFilesAndDoesNotFollowSymbolicLinks() throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "storage-usage-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    _ = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: rootURL,
      appVersion: "test"
    )
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)

    try writeFixture(bytes: 1_000, to: layout.knowledgeLibraryURL.appendingPathComponent("captured.bin"))
    try writeFixture(bytes: 2_000, to: layout.rssReaderURL.appendingPathComponent("RSSMedia/image.bin"))
    try writeFixture(bytes: 3_000, to: layout.managedAttachmentsURL.appendingPathComponent("draft/file.bin"))
    try writeFixture(
      bytes: 4_000,
      to: layout.rootURL
        .appendingPathComponent(WorkspaceBackupService.automaticBackupDirectoryName)
        .appendingPathComponent("daily/backup.bin")
    )
    try writeFixture(bytes: 5_000, to: layout.rootURL.appendingPathComponent("other.bin"))
    let outsideURL = parentURL.appendingPathComponent("outside.bin")
    try writeFixture(bytes: 2_000_000, to: outsideURL)

    let service = WorkbenchStorageUsageService()
    let beforeLink = try service.snapshot(for: layout)
    try FileManager.default.createSymbolicLink(
      at: layout.rootURL.appendingPathComponent("outside-link.bin"),
      withDestinationURL: outsideURL
    )
    let afterLink = try service.snapshot(for: layout)

    #expect(afterLink == beforeLink)
    #expect(afterLink.regularFileCount > 5)
    #expect(afterLink.knowledgeLibraryByteCount > 0)
    #expect(afterLink.rssReaderByteCount > 0)
    #expect(afterLink.managedAttachmentsByteCount > 0)
    #expect(afterLink.automaticBackupsByteCount > 0)
    #expect(afterLink.otherByteCount > 0)
    #expect(
      afterLink.totalByteCount
        == afterLink.knowledgeLibraryByteCount
          + afterLink.rssReaderByteCount
          + afterLink.managedAttachmentsByteCount
          + afterLink.automaticBackupsByteCount
          + afterLink.otherByteCount
    )
  }

  private func writeFixture(bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 0xA5, count: bytes).write(to: url)
  }
}
