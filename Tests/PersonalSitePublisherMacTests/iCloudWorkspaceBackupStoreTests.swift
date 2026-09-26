import PublishingBackupCore
import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

final class iCloudWorkspaceBackupStoreTests: XCTestCase {
  func testCurrentLocalCopyIsNotReportedAsUploadedWithoutUploadFlag() {
    let state = iCloudWorkspaceBackupStore.mapAvailability(
      isUploaded: false,
      uploadingError: nil,
      downloadingStatus: .current,
      downloadingError: nil
    )

    XCTAssertEqual(state, .localOnly)
  }

  func testOnlyExplicitUploadedFlagReportsCloudAvailability() {
    let state = iCloudWorkspaceBackupStore.mapAvailability(
      isUploaded: true,
      uploadingError: nil,
      downloadingStatus: .current,
      downloadingError: nil
    )

    XCTAssertEqual(state, .availableInCloud)
  }

  func testRemoteMetadataWithoutDownloadedBytesRequiresDownload() {
    let state = iCloudWorkspaceBackupStore.mapAvailability(
      isUploaded: true,
      uploadingError: nil,
      downloadingStatus: .notDownloaded,
      downloadingError: nil
    )

    XCTAssertEqual(state, .downloadRequired)
  }

  func testUploadErrorTakesPrecedenceOverLocalAvailability() {
    let state = iCloudWorkspaceBackupStore.mapAvailability(
      isUploaded: false,
      uploadingError: "network unavailable",
      downloadingStatus: .downloaded,
      downloadingError: nil
    )

    XCTAssertEqual(state, .failed("network unavailable"))
  }

  func testExplicitUploadAndDownloadProgressAreReported() {
    XCTAssertEqual(
      iCloudWorkspaceBackupStore.mapAvailability(
        isUploaded: false,
        isUploading: true,
        uploadingError: nil,
        downloadingStatus: .downloaded,
        downloadingError: nil
      ),
      .uploading
    )
    XCTAssertEqual(
      iCloudWorkspaceBackupStore.mapAvailability(
        isUploaded: true,
        isDownloading: true,
        uploadingError: nil,
        downloadingStatus: .notDownloaded,
        downloadingError: nil
      ),
      .downloading
    )
  }

  func testPackageIsNotCloudAvailableUntilEveryDeclaredFileIsUploaded() {
    XCTAssertFalse(
      iCloudWorkspaceBackupStore.allPackageItemsUploaded(
        rootUploaded: true,
        payloadUploadFlags: [true, false, true]
      )
    )
    XCTAssertFalse(
      iCloudWorkspaceBackupStore.allPackageItemsUploaded(
        rootUploaded: true,
        payloadUploadFlags: [true, nil]
      )
    )
    XCTAssertTrue(
      iCloudWorkspaceBackupStore.allPackageItemsUploaded(
        rootUploaded: true,
        payloadUploadFlags: [true, true]
      )
    )
  }

  func testManifestPathsDecodeFromTheWorkspaceBackupISO8601Format() throws {
    let record = WorkspaceBackupFileRecord(
      relativePath: "workbench/workbench.json",
      component: .workbenchState,
      byteCount: 12,
      sha256: String(repeating: "a", count: 64)
    )
    let manifest = WorkspaceBackupManifest(
      applicationVersion: "1.0",
      profileCount: 0,
      draftCount: 0,
      draftVersionCount: 0,
      releaseRecordCount: 0,
      attachmentReferenceCount: 0,
      unresolvedAttachmentCount: 0,
      components: [
        WorkspaceBackupComponentSummary(component: .workbenchState, fileCount: 1, byteCount: 12)
      ],
      fileCount: 1,
      totalByteCount: 12,
      attachmentReferences: [],
      files: [record],
      selectedCategories: [.workbench],
      categorySummaries: [
        WorkspaceBackupCategorySummary(category: .workbench, fileCount: 1, byteCount: 12)
      ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(manifest)

    XCTAssertEqual(
      iCloudWorkspaceBackupStore.manifestPayloadPaths(from: data),
      ["workbench/workbench.json"]
    )
  }
}
