import Foundation

extension WorkbenchSnapshot {
  /// A portable backup is data, not authorization to execute local programs.
  /// Normal primary persistence preserves these settings; an explicit backup
  /// restore requires selecting keys and trusting the destination again.
  func removingLocalGitExecutionPermissions() -> WorkbenchSnapshot {
    var result = self
    result.profiles = profiles.map { profile in
      var sanitized = profile
      sanitized.gitExecutionPolicy = nil
      return sanitized
    }
    return result
  }
}
