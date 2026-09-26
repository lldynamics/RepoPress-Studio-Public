import PublishingGitCore
import PublishingSyncCore

extension RepositorySyncCommandBuilder {
  public func plan(
    report: RepositoryScanReport?, profile: SiteProfile
  ) -> RepositorySyncCommandPlan? {
    plan(
      input: RepositorySyncCommandInput(
        rootPath: profile.localRepositoryRootURL?.path,
        hasGitDirectory: report?.hasGitDirectory,
        preferredBranch: profile.branch,
        branchStatus: report?.branchStatus
      )
    )
  }
}
