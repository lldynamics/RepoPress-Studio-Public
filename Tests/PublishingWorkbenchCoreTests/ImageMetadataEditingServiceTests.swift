import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

final class ImageMetadataEditingServiceTests: XCTestCase {
  private let service = ImageMetadataEditingService()

  func testUpdatesAttachmentMetadataCoverAndEveryMatchingMarkdownReference() throws {
    let attachment = DraftAttachment(
      originalFilename: "hero.png",
      relativePublishPath: "/images/hero.png",
      repositoryPath: "static/images/hero.png"
    )
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Images",
      bodyMarkdown: "![](/images/hero.png)\n\n![](/images/hero.png \"Second\")",
      attachments: [attachment]
    )

    let result = try XCTUnwrap(
      service.updating(
        draft: draft,
        attachmentID: attachment.id,
        altText: "  Hero [wide]\nimage  ",
        caption: "  Launch caption  ",
        isCover: true
      )
    )

    XCTAssertEqual(result.draft.attachments[0].altText, "Hero [wide] image")
    XCTAssertEqual(result.draft.attachments[0].caption, "Launch caption")
    XCTAssertEqual(result.draft.coverAttachmentID, attachment.id)
    XCTAssertEqual(result.updatedMarkdownReferenceCount, 2)
    XCTAssertEqual(
      result.draft.bodyMarkdown,
      "![Hero \\[wide\\] image](/images/hero.png)\n\n![Hero \\[wide\\] image](/images/hero.png \"Second\")"
    )
  }

  func testClearsCoverOnlyWhenEditingCurrentCover() throws {
    let first = DraftAttachment(
      originalFilename: "first.png",
      relativePublishPath: "/images/first.png",
      repositoryPath: "static/images/first.png"
    )
    let second = DraftAttachment(
      originalFilename: "second.png",
      relativePublishPath: "/images/second.png",
      repositoryPath: "static/images/second.png"
    )
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Cover",
      coverAttachmentID: first.id,
      attachments: [first, second]
    )

    let editingInlineImage = try XCTUnwrap(
      service.updating(
        draft: draft,
        attachmentID: second.id,
        altText: "Second",
        caption: "",
        isCover: false
      )
    )
    XCTAssertEqual(editingInlineImage.draft.coverAttachmentID, first.id)

    let clearingCover = try XCTUnwrap(
      service.updating(
        draft: draft,
        attachmentID: first.id,
        altText: "First",
        caption: "",
        isCover: false
      )
    )
    XCTAssertNil(clearingCover.draft.coverAttachmentID)
  }

  func testBuildsEscapedMarkdownReferenceAndRejectsMissingAttachment() {
    XCTAssertEqual(
      service.markdownReference(
        altText: #"Chart \[Q3]"# + "\nwide", imagePath: "/images/chart.png"),
      #"![Chart \\\[Q3\] wide](/images/chart.png)"#
    )

    let draft = ArticleDraft(siteProfileID: UUID(), title: "Missing")
    XCTAssertNil(
      service.updating(
        draft: draft,
        attachmentID: UUID(),
        altText: "Alt",
        caption: "Caption",
        isCover: false
      )
    )
  }

  func testUpdatesAllDuplicateReferencesAndPreservesTheirTitlesWhileEscapingAlt() throws {
    let attachment = DraftAttachment(
      originalFilename: "diagram.png",
      relativePublishPath: "/images/diagram.png",
      repositoryPath: "static/images/diagram.png"
    )
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Escaped image alt",
      bodyMarkdown: """
        ![](/images/diagram.png "first")
        ![old](/images/diagram.png)
        ![](/images/other.png "unrelated")
        """,
      attachments: [attachment]
    )

    let result = try XCTUnwrap(
      service.updating(
        draft: draft,
        attachmentID: attachment.id,
        altText: #"  Folder \images [wide]  "#,
        caption: "",
        isCover: false
      )
    )

    XCTAssertEqual(result.updatedMarkdownReferenceCount, 2)
    XCTAssertEqual(
      result.draft.bodyMarkdown,
      #"""
      ![Folder \\images \[wide\]](/images/diagram.png "first")
      ![Folder \\images \[wide\]](/images/diagram.png)
      ![](/images/other.png "unrelated")
      """#
    )
  }
}

@MainActor
final class RepositoryImageUsageEditingTests: XCTestCase {
  func testEditingByDraftAndAttachmentIDLeavesOtherDraftAndSelectionUntouched() throws {
    let store = makeStore()
    let first = makeDraft(body: "![old](/images/hero.png)")
    let second = makeDraft(body: "second")
    store.updateDraft(first)
    store.updateDraft(second)
    store.selectDraft(first.id)
    let originalSecond = try XCTUnwrap(store.draft(for: second.id))

    XCTAssertTrue(
      store.editRepositoryImageUsage(
        draftID: first.id, attachmentID: first.attachments[0].id,
        expectedRepositoryPath: "static/images/hero.png", profileID: store.activeProfile.id,
        edit: .caption("说明")
      ))

    XCTAssertEqual(store.selectedDraft?.id, first.id)
    XCTAssertEqual(store.draft(for: second.id), originalSecond)
    XCTAssertEqual(store.draft(for: first.id)?.attachments[0].caption, "说明")
    XCTAssertEqual(store.draft(for: first.id)?.bodyMarkdown, first.bodyMarkdown)
  }

  func testAltPreservesInputWhitespaceAndSynchronizesEscapedMarkdownAndStagedBody() throws {
    let store = makeStore()
    var draft = makeDraft(body: "![old](/images/hero.png)")
    draft.externalDraftSource = ExternalDraftSource(
      mappingID: UUID(), relativePath: "hero.md", importedTitle: "Hero", importedFingerprint: "fp"
    )
    store.updateDraft(draft)
    let staged = "前置\n![old](/images/hero.png)\n结尾"
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    XCTAssertEqual(
      store.stageDraftBody(staged, for: draft.id, baseRevision: buffer.revision)?.wasAccepted, true)
    let input = "  [hero]  "

    XCTAssertTrue(
      store.editRepositoryImageUsage(
        draftID: draft.id, attachmentID: draft.attachments[0].id,
        expectedRepositoryPath: "static/images/hero.png", profileID: store.activeProfile.id,
        edit: .altText(input)
      ))

    let updated = try XCTUnwrap(store.draft(for: draft.id))
    XCTAssertEqual(updated.attachments[0].altText, input)
    XCTAssertTrue(updated.bodyMarkdown.contains("![\\[hero\\]](/images/hero.png)"))
    XCTAssertTrue(updated.bodyMarkdown.contains("前置"))
    XCTAssertTrue(updated.bodyMarkdown.contains("结尾"))
    XCTAssertEqual(updated.externalDraftSource?.relativePath, "hero.md")
  }

  func testCaptionAndCoverDoNotRewriteBodyAndStalePathOrForeignProfileAreRejected() throws {
    let store = makeStore()
    let draft = makeDraft(body: "![old](/images/hero.png)")
    store.updateDraft(draft)
    let attachmentID = draft.attachments[0].id

    XCTAssertTrue(
      store.editRepositoryImageUsage(
        draftID: draft.id, attachmentID: attachmentID,
        expectedRepositoryPath: "static/images/hero.png", profileID: store.activeProfile.id,
        edit: .cover(true)
      ))
    XCTAssertEqual(store.draft(for: draft.id)?.bodyMarkdown, draft.bodyMarkdown)
    XCTAssertEqual(store.draft(for: draft.id)?.coverAttachmentID, attachmentID)

    var moved = try XCTUnwrap(store.draft(for: draft.id))
    moved.attachments[0].repositoryPath = "static/images/moved.png"
    store.updateDraft(moved)
    XCTAssertFalse(
      store.editRepositoryImageUsage(
        draftID: draft.id, attachmentID: attachmentID,
        expectedRepositoryPath: "static/images/hero.png", profileID: store.activeProfile.id,
        edit: .caption("stale")
      ))
    XCTAssertFalse(
      store.editRepositoryImageUsage(
        draftID: draft.id, attachmentID: attachmentID,
        expectedRepositoryPath: "static/images/moved.png", profileID: UUID(),
        edit: .caption("foreign")
      ))
  }

  private func makeStore() -> WorkbenchStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("repository-image-usage-\(UUID().uuidString).json")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url), safeMode: true)
  }

  private func makeDraft(body: String) -> ArticleDraft {
    let attachment = DraftAttachment(
      originalFilename: "hero.png", relativePublishPath: "/images/hero.png",
      repositoryPath: "static/images/hero.png", altText: "old"
    )
    return ArticleDraft(
      siteProfileID: makeProfileID, title: UUID().uuidString, slug: UUID().uuidString,
      bodyMarkdown: body, attachments: [attachment]
    )
  }

  private var makeProfileID: UUID { SiteProfile.defaultProfile.id }
}
