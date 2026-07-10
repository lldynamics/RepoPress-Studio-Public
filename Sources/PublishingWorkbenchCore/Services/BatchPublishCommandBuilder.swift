import Foundation

public struct BatchPublishCommandBuilder {
  public init() {}

  public func directCommitCommand(plan: BatchPublishPlan, profile: SiteProfile) -> String? {
    guard let rootPath = profile.localRepositoryRootURL?.path else {
      return nil
    }

    let items = plan.writableItems
    guard !items.isEmpty else {
      return nil
    }

    let root = posixShellQuote(rootPath)
    let paths = shellQuotedPaths(for: items)
    let message = posixShellQuote(commitMessage(for: items))
    return "cd \(root) && git add \(paths) && git commit -m \(message)"
  }

  public func reviewBranchCommands(
    plan: BatchPublishPlan,
    profile: SiteProfile,
    now: Date = Date()
  ) -> [String] {
    guard let rootPath = profile.localRepositoryRootURL?.path else {
      return []
    }

    let items = plan.writableItems
    guard !items.isEmpty else {
      return []
    }

    let root = posixShellQuote(rootPath)
    let branchName = reviewBranchName(for: items, now: now)
    let paths = shellQuotedPaths(for: items)
    let message = posixShellQuote(commitMessage(for: items))

    return [
      "cd \(root)",
      "git switch -c \(posixShellQuote(branchName))",
      "git add \(paths)",
      "git commit -m \(message)",
      "git push -u origin \(posixShellQuote(branchName))",
    ]
  }

  public func reviewBranchName(
    for items: [BatchPublishPlanItem],
    now: Date = Date()
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmm"
    let dateToken = formatter.string(from: now)
    return "publish/batch-\(dateToken)-\(items.count)-articles"
  }

  private func commitMessage(for items: [BatchPublishPlanItem]) -> String {
    if items.count == 1, let title = items.first?.draftTitle.nilIfEmpty {
      return "Publish: \(title)"
    }
    return "Publish: \(items.count) articles"
  }

  private func shellQuotedPaths(for items: [BatchPublishPlanItem]) -> String {
    let uniquePaths = Array(
      Set(items.flatMap { item in
        item.package.files.map(\.repositoryPath)
      })
    )
    .sorted()

    return uniquePaths
      .map(posixShellQuote)
      .joined(separator: " ")
  }
}
