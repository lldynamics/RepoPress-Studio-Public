import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct ImageFileSupportTests {
  @Test func acceptsStaticSiteImageFormatsCaseInsensitively() {
    #expect(ImageFileSupport.isSupportedImagePath("assets/hero.JPG"))
    #expect(ImageFileSupport.isSupportedImagePath("static/social/cover.webp"))
    #expect(ImageFileSupport.isSupportedImagePath("public/images/icon.SVG"))
    #expect(ImageFileSupport.isSupportedImagePath("/tmp/photo.HEIC"))
  }

  @Test func rejectsNonImagePublishingFiles() {
    #expect(!ImageFileSupport.isSupportedImagePath("content/post.md"))
    #expect(!ImageFileSupport.isSupportedImagePath("assets/raw/source.psd"))
    #expect(!ImageFileSupport.isSupportedImagePath("package.json"))
  }

  @Test func filtersDroppedFilesToSupportedImagesInOriginalOrder() {
    let urls = [
      URL(fileURLWithPath: "/tmp/cover.PNG"),
      URL(fileURLWithPath: "/tmp/notes.md"),
      URL(fileURLWithPath: "/tmp/diagram.svg"),
    ]

    #expect(
      ImageFileSupport.supportedImageURLs(in: urls).map(\.lastPathComponent)
        == ["cover.PNG", "diagram.svg"]
    )
  }
}
