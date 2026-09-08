import Foundation

/// Preserves an explicit resource selection across scans. The first completed
/// scan selects the candidates it discovers; every later scan only removes
/// paths that no longer exist, so a user-cleared list stays cleared and newly
/// discovered paths require an explicit choice.
enum AssetResourceSelectionPolicy {
  static func normalizedSelection(
    currentSelection: Set<String>,
    candidates: Set<String>,
    hasInitializedSelection: Bool
  ) -> (selection: Set<String>, hasInitializedSelection: Bool) {
    guard hasInitializedSelection else {
      return (candidates, true)
    }
    return (currentSelection.intersection(candidates), true)
  }
}
