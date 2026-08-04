import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class VideoFileSupportTests: XCTestCase {
  func testRecognizesSupportedVideoFormatsWithoutChangingSelectionOrder() {
    let urls = [
      URL(fileURLWithPath: "/tmp/intro.MP4"),
      URL(fileURLWithPath: "/tmp/cover.png"),
      URL(fileURLWithPath: "/tmp/demo.webm"),
      URL(fileURLWithPath: "/tmp/clip.mov"),
    ]

    XCTAssertEqual(
      VideoFileSupport.supportedVideoURLs(in: urls).map(\.lastPathComponent),
      ["intro.MP4", "demo.webm", "clip.mov"]
    )
  }

  func testAccessibleTitleUsesHumanReadableFilename() {
    XCTAssertEqual(
      VideoFileSupport.accessibleTitle(for: URL(fileURLWithPath: "/tmp/product_walk-through.mp4")),
      "product walk through"
    )
  }

  func testHTMLVideoEmbedIsResponsiveAccessibleAndEscapesAttributes() {
    let html = VideoFileSupport.htmlEmbed(
      publicPath: "/videos/demo&\"clip.webm",
      accessibleTitle: "Demo <clip> & \"walkthrough\""
    )

    XCTAssertTrue(html.contains("<video controls preload=\"metadata\" playsinline"))
    XCTAssertTrue(html.contains(#"aria-label="Demo &lt;clip&gt; &amp; &quot;walkthrough&quot;""#))
    XCTAssertTrue(html.contains(#"src="/videos/demo&amp;&quot;clip.webm""#))
    XCTAssertTrue(html.contains(#"type="video/webm""#))
    XCTAssertTrue(html.contains(#"<a href="/videos/demo&amp;&quot;clip.webm">"#))
  }

  func testDraftAttachmentMediaKindUsesFilenameAndPaths() {
    let video = DraftAttachment(
      originalFilename: "demo.mp4",
      relativePublishPath: "/videos/demo.mp4",
      repositoryPath: "static/videos/demo.mp4"
    )
    let image = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png"
    )

    XCTAssertEqual(video.mediaKind, .video)
    XCTAssertEqual(image.mediaKind, .image)
  }
}
