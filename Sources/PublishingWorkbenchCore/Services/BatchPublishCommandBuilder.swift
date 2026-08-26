import Foundation
import PublishingGitCore

public struct BatchPublishCommandBuilder {
  public init() {}

  public func directCommitCommand(plan: BatchPublishPlan, profile: SiteProfile) -> String? {
    BatchGitCommandPolicy().directCommitCommand(
      rootPath: profile.localRepositoryRootURL?.path,
      items: plan.writableItems.map(Self.commandItem)
    )
  }

  public func reviewBranchCommands(
    plan: BatchPublishPlan,
    profile: SiteProfile,
    now: Date = Date()
  ) -> [String] {
    BatchGitCommandPolicy().reviewBranchCommands(
      rootPath: profile.localRepositoryRootURL?.path,
      items: plan.writableItems.map(Self.commandItem),
      now: now
    )
  }

  public func reviewBranchName(
    for items: [BatchPublishPlanItem],
    now: Date = Date()
  ) -> String {
    BatchGitCommandPolicy().reviewBranchName(
      for: items.map(Self.commandItem),
      now: now
    )
  }

  private static func commandItem(_ item: BatchPublishPlanItem) -> BatchGitCommandItem {
    BatchGitCommandItem(
      title: item.draftTitle,
      repositoryPaths: item.package.files.map(\.repositoryPath)
    )
  }
}
