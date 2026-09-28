import Foundation

/// Tracks live composer windows only for recovery ownership arbitration. It is
/// intentionally process-local: a fresh launch has no active owners, allowing
/// a restored window to claim a persisted orphan without deleting it.
@MainActor
final class MarkdownFrontMatterRecoveryWindowRegistry {
  static let shared = MarkdownFrontMatterRecoveryWindowRegistry()

  private var activeWindowIDs = Set<UUID>()

  func register(_ windowID: UUID) {
    activeWindowIDs.insert(windowID)
  }

  func unregister(_ windowID: UUID) {
    activeWindowIDs.remove(windowID)
  }

  var activeOwners: Set<UUID> { activeWindowIDs }
}
