import Foundation
import PublishingWorkbenchCore

/// A deterministic sample routed through the same render/path services used
/// for real articles, so settings previews cannot drift into a second format.
struct DefaultRuleFrontMatterPreview: Equatable {
  let frontMatter: String
  let markdownPath: String
  let url: String

  static let sampleDate = Date(timeIntervalSinceReferenceDate: 807_703_200) // 2026-08-06 10:00:00 UTC

  static func make(profile: SiteProfile) -> Self {
    let draft = sampleDraft(profile: profile)
    let markdownPath = profile.markdownPath(for: draft)
    let baseURL = URL(string: profile.deploymentSiteURL?.trimmedForPublishing ?? "")
      ?? URL(string: "https://example.com")!
    let resolvedURL = SiteArticleURLResolver().url(
      baseURL: baseURL,
      markdownPath: markdownPath,
      profile: profile
    )
    let url = resolvedURL?.absoluteString
      ?? baseURL.absoluteString

    return Self(
      frontMatter: FrontMatterRenderer().render(draft: draft, profile: profile),
      markdownPath: markdownPath,
      url: url
    )
  }

  static func sampleDraft(profile: SiteProfile) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: "示例文章标题",
      date: sampleDate,
      slug: "example-article",
      tags: profile.defaultTags,
      categories: profile.defaultCategories,
      draft: true,
      summary: "示例摘要"
    )
  }
}
