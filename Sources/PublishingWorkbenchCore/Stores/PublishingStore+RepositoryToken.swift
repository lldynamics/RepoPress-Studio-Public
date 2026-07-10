import Foundation

extension PublishingStore {
  func repositoryAccessToken(for profile: SiteProfile) throws -> String? {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    _ = try repositoryTokenStore.migrateLegacyToken(for: profile, to: scope, deleteLegacyToken: false)
    return try repositoryTokenStore.token(for: profile, scope: scope)
  }
}
