import Foundation

enum MacMarkdownFrontMatterRecoveryConflictPolicy {
  /// An invalid Front Matter document is raw source that was captured against
  /// both its body and structured metadata. A missing legacy baseline is
  /// intentionally treated as conflicted: applying old source to a newer
  /// draft is worse than preserving that source for an explicit merge.
  static func hasMatchingMetadataRevision(
    baseline: UInt64?,
    current: UInt64
  ) -> Bool {
    baseline == current
  }
}
