import Foundation
import PublishingWorkbenchCore

enum FirstRunRulePreviewPresentation {
  static func markdownPath(profile: SiteProfile, date: Date = Date()) -> String? {
    guard
      RepositoryPublishingRuleValidation.isValid(
        contentRoot: profile.contentRoot,
        markdownPathPattern: profile.markdownPathPattern
      )
    else { return nil }
    let example = ArticleDraft(
      siteProfileID: profile.id, title: "My first post", date: date, slug: "my-first-post")
    return profile.markdownPath(for: example)
  }
}
