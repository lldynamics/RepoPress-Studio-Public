import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class GeneralDraftLibraryServiceTests: XCTestCase {
  func testStoreCopiesArticleToAnotherPublishingSite() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
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

final class RetiredExternalDraftFolderDecodingTests: XCTestCase {
  func testLinkedDraftAndMappedProfileDecodeAsPlainRecords() throws {
    let profile = SiteProfile(name: "旧站点")
    var profileObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(profile)) as? [String: Any]
    )
    profileObject["externalDraftFolder"] = [
      "id": UUID().uuidString, "path": "/tmp/vault", "observesChanges": true,
    ]
    let draft = ArticleDraft(siteProfileID: profile.id, scope: .general, title: "外部想法")
    var draftObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(draft)) as? [String: Any]
    )
    draftObject["externalDraftSource"] = [
      "mappingID": UUID().uuidString, "relativePath": "idea.md",
      "importedTitle": "外部想法", "importedFingerprint": "fingerprint",
    ]

    let decodedProfile = try JSONDecoder.workbench.decode(
      SiteProfile.self, from: JSONSerialization.data(withJSONObject: profileObject))
    let decodedDraft = try JSONDecoder.workbench.decode(
      ArticleDraft.self, from: JSONSerialization.data(withJSONObject: draftObject))

    XCTAssertEqual(decodedProfile.name, "旧站点")
    XCTAssertEqual(decodedDraft.title, "外部想法")
    XCTAssertTrue(decodedDraft.isGeneralDraft)
    XCTAssertFalse(
      String(decoding: try JSONEncoder.workbench.encode(decodedDraft), as: UTF8.self)
        .contains("externalDraftSource"))
  }
}
