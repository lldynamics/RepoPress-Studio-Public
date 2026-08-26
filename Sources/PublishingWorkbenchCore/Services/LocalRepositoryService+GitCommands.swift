import Foundation
import PublishingGitCore

extension LocalRepositoryService {
  func fetchUpstream(rootURL: URL) -> RepositoryFetchResult {
    let status = gitStatus(rootURL: rootURL)
    guard let upstreamName = status.branchStatus?.upstreamName?.nilIfEmpty else {
      return RepositoryFetchResult(
        status: .skipped,
        remoteName: nil,
        upstreamName: nil,
        message: "当前分支未设置 upstream，跳过远端 fetch。"
      )
    }
    guard let remoteName = remoteName(fromUpstreamName: upstreamName) else {
      return RepositoryFetchResult(
        status: .skipped,
        remoteName: nil,
        upstreamName: upstreamName,
        message: "无法从 upstream \(upstreamName) 识别 remote 名称，跳过远端 fetch。"
      )
    }

    let result = runGitCommand(["fetch", "--prune", remoteName], rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      let detail = result.output.nilIfEmpty.map { "：\($0)" } ?? ""
      return RepositoryFetchResult(
        status: .failed,
        remoteName: remoteName,
        upstreamName: upstreamName,
        message: "fetch \(remoteName) 失败\(detail)"
      )
    }

    return RepositoryFetchResult(
      status: .succeeded,
      remoteName: remoteName,
      upstreamName: upstreamName,
      message: "已 fetch \(remoteName)，upstream \(upstreamName) 已刷新。"
    )
  }

  func remoteName(fromUpstreamName upstreamName: String) -> String? {
    GitRemoteParser.remoteName(fromUpstreamName: upstreamName)
  }

  func localBranches(rootURL: URL) -> [RepositoryBranch] {
    guard let output = runGitOutput(["branch", "--format=%(refname:short)|%(HEAD)|%(upstream:short)"], rootURL: rootURL) else {
      return []
    }

    let branches = output
      .split(separator: "\n")
      .compactMap { parseBranchListLine(String($0)) }

    if branches.contains(where: { $0.isCurrent }) {
      return branches
    }

    if let current = runGitOutput(["branch", "--show-current"], rootURL: rootURL)?.trimmedForPublishing,
       let index = branches.firstIndex(where: { $0.name == current }) {
      var withCurrent = branches
      withCurrent[index].isCurrent = true
      return withCurrent
    }

    return branches
  }

  func parseBranchListLine(_ line: String) -> RepositoryBranch? {
    GitRepositoryOutputParser().parseBranchListLine(line)
  }

  func recentCommits(rootURL: URL, limit: Int) -> [RepositoryCommitInfo] {
    let format = "%H\t%an\t%ad\t%s"
    guard let output = runGitOutput(
      ["log", "-n", "\(limit)", "--date=iso-strict", "--pretty=format:\(format)"],
      rootURL: rootURL
    ) else {
      return []
    }

    return output
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { parseRecentCommitLine(String($0)) }
  }

  func parseRecentCommitLine(_ line: String) -> RepositoryCommitInfo? {
    GitRepositoryOutputParser().parseRecentCommitLine(line, fallbackDate: Date())
  }

  func parseGitDate(_ text: String) -> Date {
    GitRepositoryOutputParser().parseGitDate(text, fallbackDate: Date())
  }

  func ignoredRepositoryPaths(rootURL: URL, paths: [String]) -> [String] {
    let result = runGitCommand(
      ["check-ignore", "--stdin", "-z"],
      rootURL: rootURL,
      inputLines: paths,
      inputDelimiter: .nul
    )
    guard result.terminationStatus == 0 || result.terminationStatus == 1 else {
      return []
    }

    let output = result.standardOutput
    guard !output.isEmpty else {
      return []
    }

    return output
      .split(separator: "\0")
      .map { String($0) }
      .filter { !$0.isEmpty }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  func runGitCommand(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil,
    inputDelimiter: GitCommandInputDelimiter = .newline
  ) -> GitCommandResult {
    gitCommandRunner.run(
      arguments,
      rootURL: rootURL,
      inputLines: inputLines,
      inputDelimiter: inputDelimiter
    )
  }

  func runGitOutput(_ arguments: [String], rootURL: URL) -> String? {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      return nil
    }
    return result.standardOutput
  }

  func parseRepositoryRemote(_ remoteURL: String) -> RepositoryRemote? {
    GitRemoteParser.parseRepositoryRemote(remoteURL)
  }

  func parseBranchStatusLine(_ line: String) -> RepositoryBranchStatus? {
    GitRepositoryOutputParser().parseBranchStatusLine(line)
  }

  func parseSyncCount(label: String, in text: String) -> Int {
    GitRepositoryOutputParser().parseSyncCount(label: label, in: text)
  }

  func diffForChangedFile(_ file: RepositoryChangedFile, rootURL: URL) -> String? {
    guard let plan = RepositoryLocalDiffCommandPolicy().plan(for: file) else {
      return nil
    }

    if file.kind == .untracked {
      guard let arguments = plan.argumentsInExecutionOrder.first else {
        return nil
      }
      return runGitDiff(arguments, rootURL: rootURL)
    }

    let diffs = plan.argumentsInExecutionOrder.map { arguments in
      runGitDiff(arguments, rootURL: rootURL)
    }
    let combined = diffs
      .compactMap { $0?.trimmedForPublishing.nilIfEmpty }
      .joined(separator: "\n")
    return limitedDiff(combined)
  }

  func runGitDiff(_ arguments: [String], rootURL: URL) -> String? {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 || result.terminationStatus == 1 else {
      return nil
    }
    return limitedDiff(result.standardOutput)
  }

  func limitedDiff(_ diff: String) -> String? {
    let trimmed = diff.trimmedForPublishing
    guard !trimmed.isEmpty else {
      return nil
    }

    let maxLineCount = 160
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count > maxLineCount else {
      return trimmed
    }

    return (Array(lines.prefix(maxLineCount)) + ["... diff 已截断，仅显示前 \(maxLineCount) 行 ..."])
      .joined(separator: "\n")
  }
}
