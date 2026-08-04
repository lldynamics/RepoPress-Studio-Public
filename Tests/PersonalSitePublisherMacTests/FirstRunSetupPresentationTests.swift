import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class FirstRunSetupPresentationTests: XCTestCase {
  func testFirstRunOffersTheThreePathsInProductOrder() {
    XCTAssertEqual(
      FirstRunSetupPath.allCases.map(\.rawValue),
      [
        "connectExistingRepository",
        "createNewSite",
        "localDrafts",
      ]
    )
    XCTAssertEqual(
      FirstRunSetupPath.allCases.map(\.title),
      ["连接已有仓库", "创建新站点", "暂不配置站点"]
    )
  }

  @MainActor
  func testLocalDraftWorkspaceReusesAnEmptyDefaultProfile() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstRunLocalDrafts-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL)
    )

    store.prepareLocalDraftWorkspace()

    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.activeProfile.name, "本地草稿")
    XCTAssertEqual(store.activeProfile.purpose, SiteProfilePurpose.generalDraftBackup)
    XCTAssertTrue(store.activeProfile.localRepositoryRootPath.isEmpty)
    XCTAssertEqual(store.draftListContentScope, DraftListContentScope.general)
    XCTAssertEqual(store.selectedSection, WorkspaceSection.writing)
    XCTAssertTrue(store.selectedDraft?.isGeneralDraft == true)
  }
}
