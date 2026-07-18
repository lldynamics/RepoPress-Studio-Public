import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class ImageInspectorFocusRequestTests: XCTestCase {
  func testFocusImageInspectorSelectsDraftWorkspaceAndAttachment() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ImageInspectorFocus")
    let attachment = DraftAttachment(
      originalFilename: "hero.png",
      relativePublishPath: "/images/hero.png",
      repositoryPath: "static/images/hero.png"
    )
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: store.activeProfile.id,
      title: "Focused image",
      attachments: [attachment]
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setInspectorPresented(false)

    XCTAssertTrue(store.focusImageInspector(draftID: draft.id, attachmentID: attachment.id))
    XCTAssertEqual(store.selectedDraftID, draft.id)
    XCTAssertEqual(store.selectedSection, .images)
    XCTAssertTrue(store.isInspectorPresented)
    XCTAssertEqual(store.imageInspectorFocusRequest?.draftID, draft.id)
    XCTAssertEqual(store.imageInspectorFocusRequest?.attachmentID, attachment.id)
  }

  func testFocusImageInspectorRejectsAttachmentOutsideDraft() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ImageInspectorFocusMissing")
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: store.activeProfile.id,
      title: "No image"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    XCTAssertFalse(store.focusImageInspector(draftID: draft.id, attachmentID: UUID()))
    XCTAssertNil(store.imageInspectorFocusRequest)
  }
}
