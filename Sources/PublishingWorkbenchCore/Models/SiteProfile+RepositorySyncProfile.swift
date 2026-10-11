import PublishingSyncCore

extension SiteProfile: RepositorySyncProfile {
  public var requiresControlledCommitExecution: Bool {
    gitExecutionPolicy?.requiresControlledCommitExecution == true
  }
}
