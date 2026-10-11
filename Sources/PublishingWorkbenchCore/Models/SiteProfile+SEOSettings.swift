import Foundation

extension SiteProfile {
  /// Resolve the same cached theme policy for both editor and publishing checks.
  /// Template inspection runs off the main actor, never from a SwiftUI getter.
  public func resolveBodyH1DuplicateWarning(repositoryRevision: UUID) async -> Bool {
    if let warnsWhenBodyH1DuplicatesTitle { return warnsWhenBodyH1DuplicatesTitle }
    let profile = self
    return await Task.detached(priority: .utility) {
      ThemeTitleH1Detector().cachedOrDetect(
        profile: profile, repositoryRevision: repositoryRevision) ?? true
    }.value
  }

  public var resolvedWarnsWhenBodyH1DuplicatesTitle: Bool {
    get {
      warnsWhenBodyH1DuplicatesTitle
        ?? ThemeTitleH1Detector.cachedRendersTitleAsH1(profile: self)
        ?? true
    }
    set { warnsWhenBodyH1DuplicatesTitle = newValue }
  }
}
