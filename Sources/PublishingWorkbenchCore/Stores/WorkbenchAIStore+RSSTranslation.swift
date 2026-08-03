import Foundation

extension WorkbenchAIStore {
  /// Translates an RSS article through the active AI connection without
  /// putting the article into an AI chat transcript or the knowledge library.
  /// Keychain lookup and remote data-sharing consent remain centralized in the
  /// existing AI store path.
  public func translateRSSArticle(
    _ article: RSSArticle,
    target: RSSArticleTranslationTarget
  ) async throws -> RSSArticleTranslationResult {
    guard store.canUseProtectedWorkbench else {
      throw RSSArticleTranslationError.protectedWorkbenchUnavailable
    }

    let profile = store.activeProfile
    let config = store.aiProviderConfig(for: profile)
    let apiKey = try aiChatAvailableAPIKey(for: profile)
    return try await RSSArticleTranslationService().translate(
      article: article,
      target: target,
      config: config,
      apiKey: apiKey
    )
  }
}
