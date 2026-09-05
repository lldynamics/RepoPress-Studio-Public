import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class FirstRunRulePreviewPresentationTests: XCTestCase {
  func testExampleUsesTheActualSiteTemplateAndDate() throws {
    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "articles"
    profile.markdownPathPattern = "articles/{year}/{month}/{day}/{slug}/index.md"
    let date = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 5, hour: 12)))
    XCTAssertEqual(
      FirstRunRulePreviewPresentation.markdownPath(profile: profile, date: date),
      "articles/2026/09/05/my-first-post/index.md")
    profile.contentRoot = "src/content/blog"
    profile.markdownPathPattern = "src/content/blog/{slug}.mdx"
    XCTAssertEqual(
      FirstRunRulePreviewPresentation.markdownPath(profile: profile, date: date),
      "src/content/blog/my-first-post.mdx")
  }

  func testInvalidRulesDoNotPresentAValidLookingExample() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "../outside/{slug}.md"
    XCTAssertNil(FirstRunRulePreviewPresentation.markdownPath(profile: profile))
    profile.markdownPathPattern = "content/posts/fixed.md"
    XCTAssertNil(FirstRunRulePreviewPresentation.markdownPath(profile: profile))
  }
}
