import Foundation

/// A trigger fragment for an existing deployment workflow, never a second
/// deployment pipeline that could overwrite the site's chosen build settings.
public struct ScheduledPublishWorkflowTemplate: Equatable, Sendable {
  public let triggerYAML: String
  public let supportsFutureContent: Bool

  public init(profile: SiteProfile) {
    // Hugo (`buildFuture: false`) and Jekyll (`future: false`) skip
    // future-dated content by default, so a scheduled rebuild publishes it.
    supportsFutureContent = profile.siteKind == .hugo || profile.siteKind == .jekyll
    triggerYAML = """
      # Merge these triggers into your existing GitHub deployment workflow.
      # GitHub uses UTC; 17 * * * * runs at minute 17 of every hour.
      on:
        schedule:
          - cron: '17 * * * *'
        workflow_dispatch:
      """
  }
}
