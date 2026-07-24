import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownPreviewAssetServiceTests: XCTestCase {
  func testPreparesRegisteredMarkdownImageWithAltAndCaption() throws {
    let attachmentID = UUID(uuidString: "93E2B2EE-E9A0-462B-8E5F-27AC9331E7E0")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png",
      altText: "附件替代文本",
      caption: "封面说明"
    )

    let result = MarkdownPreviewAssetService.prepare(
      markdown: "开头\n\n![正文替代文本](/images/cover.png)\n\n结尾",
      attachments: [attachment],
      previewURLByAttachmentID: [attachmentID: "publisher-asset://attachment/asset-id"]
    )

    XCTAssertFalse(result.markdown.contains("![正文替代文本]"))
    let replacement = try XCTUnwrap(result.replacements.first)
    XCTAssertTrue(result.markdown.contains(replacement.token))
    XCTAssertTrue(replacement.html.contains(#"src="publisher-asset://attachment/asset-id""#))
    XCTAssertTrue(replacement.html.contains(#"alt="正文替代文本""#))
    XCTAssertTrue(replacement.html.contains("封面说明"))
  }

  func testPreparesInsertedVideoHTMLWithMediaMIMEType() throws {
    let attachmentID = UUID(uuidString: "B4B607CE-7D30-49F9-9AFB-377F10271A24")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "walkthrough.webm",
      relativePublishPath: "/videos/walkthrough.webm",
      repositoryPath: "static/videos/walkthrough.webm",
      altText: "产品演示"
    )
    let embed = VideoFileSupport.htmlEmbed(
      publicPath: attachment.relativePublishPath,
      accessibleTitle: attachment.altText
    )

    let result = MarkdownPreviewAssetService.prepare(
      markdown: embed,
      attachments: [attachment],
      previewURLByAttachmentID: [attachmentID: "publisher-asset://attachment/video-id"]
    )

    XCTAssertFalse(result.markdown.contains("<video"))
    let replacement = try XCTUnwrap(result.replacements.first)
    XCTAssertTrue(replacement.html.contains("<video controls"))
    XCTAssertTrue(replacement.html.contains(#"type="video/webm""#))
    XCTAssertTrue(replacement.html.contains(#"aria-label="产品演示""#))
  }

  func testLeavesUnregisteredAndCodeSampleAssetsUntouched() {
    let attachmentID = UUID(uuidString: "750F792E-910F-4B1A-821E-D25E5B19EEFB")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png"
    )
    let markdown = """
    ![remote](https://example.com/cover.png)

    ```markdown
    ![sample](/images/cover.png)
    ```
    """

    let result = MarkdownPreviewAssetService.prepare(
      markdown: markdown,
      attachments: [attachment],
      previewURLByAttachmentID: [attachmentID: "publisher-asset://attachment/asset-id"]
    )

    XCTAssertEqual(result.markdown, markdown)
    XCTAssertTrue(result.replacements.isEmpty)
  }

  func testPreparesRawImageUsingRegisteredRepositoryPath() throws {
    let attachmentID = UUID(uuidString: "1D054047-C825-4C08-871B-9F055118D3DC")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "diagram.svg",
      relativePublishPath: "/images/diagram.svg",
      repositoryPath: "static/images/diagram.svg"
    )

    let result = MarkdownPreviewAssetService.prepare(
      markdown: #"<img src="static/images/diagram.svg" alt="结构图">"#,
      attachments: [attachment],
      previewURLByAttachmentID: [attachmentID: "publisher-asset://attachment/diagram-id"]
    )

    let replacement = try XCTUnwrap(result.replacements.first)
    XCTAssertTrue(replacement.html.contains(#"alt="结构图""#))
    XCTAssertTrue(replacement.html.contains(#"class="local-asset local-image""#))
  }

  func testPreparesMarkdownImageWhoseRegisteredPathContainsSpaces() throws {
    let attachmentID = UUID(uuidString: "A79A2B18-AF4E-42BD-B5DC-5B5C28243FE8")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "launch photo.png",
      relativePublishPath: "/images/launch photo.png",
      repositoryPath: "static/images/launch photo.png"
    )

    let result = MarkdownPreviewAssetService.prepare(
      markdown: "![发布现场](/images/launch photo.png)",
      attachments: [attachment],
      previewURLByAttachmentID: [attachmentID: "publisher-asset://attachment/photo-id"]
    )

    let replacement = try XCTUnwrap(result.replacements.first)
    XCTAssertTrue(result.markdown.contains(replacement.token))
    XCTAssertTrue(replacement.html.contains(#"alt="发布现场""#))
  }
}
