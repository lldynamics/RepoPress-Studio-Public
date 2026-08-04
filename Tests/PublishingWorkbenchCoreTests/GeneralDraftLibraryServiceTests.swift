import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class GeneralDraftLibraryServiceTests: XCTestCase {
  func testStoreCopiesArticleToAnotherPublishingSite() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let source = try XCTUnwrap(store.selectedDraft)
    let targetProfile = store.createProfile(named: "项目网站")

    let copied = try XCTUnwrap(store.copyDraft(source.id, toProfileID: targetProfile.id))

    XCTAssertEqual(copied.siteProfileID, targetProfile.id)
    XCTAssertEqual(copied.status, .draft)
    XCTAssertNil(copied.repositoryPath)
    XCTAssertNil(copied.repositorySHA)
    XCTAssertEqual(store.selectedDraftID, copied.id)
    XCTAssertEqual(store.selectedSection, .writing)
  }
}
