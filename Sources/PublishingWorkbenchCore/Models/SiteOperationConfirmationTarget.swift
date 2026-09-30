import Foundation

/// The site configuration and resolved repository identity reviewed by a user.
/// A profile ID alone cannot authorize an operation after settings are edited.
public struct SiteOperationConfirmationTarget: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let profile: SiteProfile
  private let repositoryIdentity: LocalRepositoryIdentity?

  public init(profile: SiteProfile) {
    id = UUID()
    self.profile = profile
    repositoryIdentity = LocalRepositoryIdentity(profile: profile)
  }

  public func matches(_ currentProfile: SiteProfile) -> Bool {
    currentProfile == profile
      && LocalRepositoryIdentity(profile: currentProfile) == repositoryIdentity
  }
}

public struct SiteKindChangeConfirmation: Identifiable, Equatable, Sendable {
  public var id: UUID { target.id }
  public let target: SiteOperationConfirmationTarget
  public let siteKind: SiteKind

  public init(profile: SiteProfile, siteKind: SiteKind) {
    target = SiteOperationConfirmationTarget(profile: profile)
    self.siteKind = siteKind
  }
}
