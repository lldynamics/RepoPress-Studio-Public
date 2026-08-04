import XCTest
@testable import PublishingWorkbenchCore

final class SiteProfilePurposeTests: XCTestCase {
  func testDefaultProfileIdentifierRemainsStable() {
    XCTAssertEqual(
      SiteProfile.defaultProfileID.uuidString,
      "F44F7DB7-8D6F-44A3-A4F3-1D0C05931F31"
    )
  }

  func testPurposeStatusCopyMatchesRepositoryReadiness() {
    XCTAssertEqual(SiteProfilePurpose.publishing.repositoryStatusWhenUnconfigured, "未选择本地仓库")
    XCTAssertEqual(SiteProfilePurpose.repositoryBackup.repositoryStatusWhenUnconfigured, "待选择备份仓库")
    XCTAssertEqual(SiteProfilePurpose.generalDraftBackup.repositoryStatusWhenUnconfigured, "素材库模式")

    XCTAssertTrue(SiteProfilePurpose.publishing.requiresRepositoryReadiness)
    XCTAssertTrue(SiteProfilePurpose.repositoryBackup.requiresRepositoryReadiness)
    XCTAssertFalse(SiteProfilePurpose.generalDraftBackup.requiresRepositoryReadiness)
  }

  func testPurposeHasSidebarSymbols() {
    XCTAssertEqual(SiteProfilePurpose.publishing.systemImage, "globe")
    XCTAssertEqual(SiteProfilePurpose.repositoryBackup.systemImage, "externaldrive")
    XCTAssertEqual(SiteProfilePurpose.generalDraftBackup.systemImage, "doc.text")
  }
}
