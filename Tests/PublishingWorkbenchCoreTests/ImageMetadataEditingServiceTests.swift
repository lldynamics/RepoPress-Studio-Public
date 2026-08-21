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
