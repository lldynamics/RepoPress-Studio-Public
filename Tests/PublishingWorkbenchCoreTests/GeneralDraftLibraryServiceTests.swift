import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class GeneralDraftLibraryServiceTests: XCTestCase {
  func testReportListsPublishingDraftsForCrossSiteCopy() {
    let firstProfile = SiteProfile(name: "个人网站", purpose: .publishing)
    let secondProfile = SiteProfile(name: "项目网站", purpose: .publishing)
    let firstDraft = ArticleDraft(siteProfileID: firstProfile.id, title: "第一篇", slug: "first")
    let secondDraft = ArticleDraft(siteProfileID: secondProfile.id, title: "第二篇", slug: "second")

    let report = GeneralDraftLibraryService().report(
      drafts: [firstDraft, secondDraft],
      profiles: [firstProfile, secondProfile]
    )

    XCTAssertEqual(Set(report.items.map(\.draftID)), Set([firstDraft.id, secondDraft.id]))
    XCTAssertEqual(report.publishingProfileCount, 2)
  }

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
