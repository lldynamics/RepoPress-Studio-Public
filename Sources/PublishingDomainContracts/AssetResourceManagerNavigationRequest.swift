import Foundation

/// A navigation request is scoped to the site that owns the resource
/// operation, so opening a completed task cannot redirect the current site.
public struct AssetResourceManagerNavigationRequest: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let profileID: UUID
  public let windowID: UUID?

  public init(id: UUID = UUID(), profileID: UUID, windowID: UUID? = nil) {
    self.id = id
    self.profileID = profileID
    self.windowID = windowID
  }
}
