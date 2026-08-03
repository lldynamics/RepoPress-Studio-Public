import Foundation

public struct RepositorySyncCommandPlan: Codable, Hashable, Sendable {
  public var title: String
  public var summary: String
  public var commands: [String]
  public var notes: [String]

  public init(
    title: String,
    summary: String,
    commands: [String],
    notes: [String] = []
  ) {
    self.title = title
    self.summary = summary
    self.commands = commands
    self.notes = notes
  }

  public var commandText: String {
    commands.joined(separator: "\n")
  }
}

public struct RepositorySyncCommandBuilder {
  public init() {}

  public func plan(report: RepositoryScanReport?, profile: SiteProfile) -> RepositorySyncCommandPlan? {
    guard let rootPath = profile.localRepositoryRootURL?.path.nilIfEmpty else {
      return nil
    }

    let cdCommand = "cd \(posixShellQuote(rootPath))"
    guard let report else {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("先扫描仓库"),
        summary: CoreL10n.text("还没有仓库扫描结果，先刷新本地仓库状态。"),
        commands: [
          cdCommand,
          "git status --short --branch",
        ]
      )
    }

    guard report.hasGitDirectory else {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("不是 Git 工作树"),
        summary: CoreL10n.text("当前目录没有 .git；文章发布命令需要在真实站点 Git 仓库里执行。"),
        commands: [
          cdCommand,
          "git status --short --branch",
        ],
        notes: [CoreL10n.text("请选择已有站点仓库根目录，或先在终端初始化并配置远端。")]
      )
    }

    guard let branchStatus = report.branchStatus else {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("确认 Git 状态"),
        summary: CoreL10n.text("无法识别当前分支；发布前先在终端确认工作树和远端状态。"),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git remote -v",
        ]
      )
    }

    if branchStatus.isDetached {
      let fallbackBranch = profile.branch.nilIfEmpty ?? "main"
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("切回发布分支"),
        summary: CoreL10n.text("当前是 Detached HEAD，先切回可发布分支再写入或提交文章。"),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git switch \(posixShellQuote(fallbackBranch))",
        ],
        notes: [
          CoreL10n.format(
            "如果目标分支不是 %@，请替换为实际发布分支。",
            fallbackBranch
          )
        ]
      )
    }

    let branchName = branchStatus.branchName ?? profile.branch
    let branch = branchName.nilIfEmpty ?? "main"

    guard branchStatus.upstreamName != nil else {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("设置上游分支"),
        summary: CoreL10n.text("当前分支未设置 upstream；可以本地写入，但 PR/MR 和远端差异判断前建议先确认远端。"),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git fetch --prune",
          "git branch --set-upstream-to=\(posixShellQuote("origin/\(branch)")) \(posixShellQuote(branch))",
        ],
        notes: [CoreL10n.text("如果远端或分支名不同，请先用 git remote -v 和 git branch -vv 确认。")]
      )
    }

    if branchStatus.aheadCount > 0 && branchStatus.behindCount > 0 {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("先处理分叉"),
        summary: CoreL10n.format(
          "本地领先 %@，落后 %@；发布前先同步远端，避免覆盖或漏掉站点变更。",
          String(branchStatus.aheadCount),
          String(branchStatus.behindCount)
        ),
        commands: [
          cdCommand,
          "git fetch --prune",
          "git status --short --branch",
          "git pull --ff-only",
        ],
        notes: [CoreL10n.text("如果 fast-forward 失败，说明需要手动处理分叉后再继续发布。")]
      )
    }

    if branchStatus.behindCount > 0 {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("先拉取远端"),
        summary: CoreL10n.format(
          "本地分支落后远端 %@ 个提交；发布前建议先拉取最新站点内容。",
          String(branchStatus.behindCount)
        ),
        commands: [
          cdCommand,
          "git fetch --prune",
          "git pull --ff-only",
        ]
      )
    }

    if branchStatus.aheadCount > 0 {
      return RepositorySyncCommandPlan(
        title: CoreL10n.text("本地有未推送提交"),
        summary: CoreL10n.format(
          "本地领先远端 %@ 个提交；创建新发布前先确认这些提交是否已经准备好推送。",
          String(branchStatus.aheadCount)
        ),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git push",
        ],
        notes: [CoreL10n.text("如果这些提交还需要合并进 PR/MR，请不要直接推送到正式分支。")]
      )
    }

    return RepositorySyncCommandPlan(
      title: CoreL10n.text("分支已同步"),
      summary: CoreL10n.text("当前分支与 upstream 一致，可以继续发布前检查、写入和提交。"),
      commands: [
        cdCommand,
        "git status --short --branch",
      ]
    )
  }
}
