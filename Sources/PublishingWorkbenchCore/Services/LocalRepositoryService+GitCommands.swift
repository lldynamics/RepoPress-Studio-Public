import Foundation

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
    let trimmed = upstreamName.trimmedForPublishing
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !trimmed.contains("\\"),
          !trimmed.contains(".."),
          !trimmed.contains("://"),
          let slashIndex = trimmed.firstIndex(of: "/") else {
      return nil
    }
    let remote = String(trimmed[..<slashIndex]).trimmedForPublishing
    guard !remote.isEmpty,
          remote.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
      return nil
    }
    return remote
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
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }

    let head = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let upstream = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
    let isCurrent = head == "*"
    return RepositoryBranch(name: name, isCurrent: isCurrent, upstreamName: upstream)
  }

  func recentCommits(rootURL: URL, limit: Int) -> [RepositoryCommitInfo] {
    let format = "%H\t%an\t%ad\t%s"
    guard let output = runGitOutput(
      ["log", "-n", "\(limit)", "--date=iso", "--pretty=format:\(format)"],
      rootURL: rootURL
    ) else {
      return []
    }

    return output
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { parseRecentCommitLine(String($0)) }
  }

  func parseRecentCommitLine(_ line: String) -> RepositoryCommitInfo? {
    let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4 else {
      return nil
    }

    let sha = parts[0].trimmedForPublishing
    let author = parts[1].trimmedForPublishing
    let dateText = parts[2].trimmedForPublishing
    let message = parts[3].trimmedForPublishing

    guard !sha.isEmpty, !author.isEmpty, !message.isEmpty else {
      return nil
    }

    return RepositoryCommitInfo(
      sha: sha,
      shortSHA: String(sha.prefix(8)),
      author: author,
      date: parseGitDate(dateText),
      message: message
    )
  }

  func parseGitDate(_ text: String) -> Date {
    let trimmedText = text.trimmedForPublishing
    guard !trimmedText.isEmpty else {
      return Date()
    }

    let strictISO8601 = ISO8601DateFormatter()
    strictISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = strictISO8601.date(from: trimmedText) {
      return date
    }

    strictISO8601.formatOptions = [.withInternetDateTime]
    if let date = strictISO8601.date(from: trimmedText) {
      return date
    }

    return Date()
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
    let trimmed = remoteURL.trimmedForPublishing
    guard let remotePath = remotePathComponents(from: trimmed) else {
      return nil
    }

    let pathComponents = remotePath.path
      .split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty }
    guard pathComponents.count >= 2,
          let provider = repositoryProvider(forHost: remotePath.host) else {
      return nil
    }

    var repositoryName = pathComponents.last ?? ""
    if repositoryName.hasSuffix(".git") {
      repositoryName.removeLast(4)
    }
    let owner = pathComponents.dropLast().joined(separator: "/")
    guard !owner.isEmpty, !repositoryName.isEmpty else {
      return nil
    }

    return RepositoryRemote(
      remoteURL: sanitizedRepositoryRemoteURL(
        trimmed,
        host: remotePath.host,
        path: remotePath.path
      ),
      provider: provider,
      repositoryBaseURL: repositoryBaseURL(provider: provider, host: remotePath.host),
      owner: owner,
      name: repositoryName
    )
  }

  func remotePathComponents(from remoteURL: String) -> (host: String, path: String)? {
    if !remoteURL.contains("://"),
       let colonIndex = scpHostPathSeparator(in: remoteURL) {
      let hostPart = String(remoteURL[..<colonIndex])
      let host = hostPart.components(separatedBy: "@").last ?? hostPart
      let pathStart = remoteURL.index(after: colonIndex)
      return (host: host, path: String(remoteURL[pathStart...]))
    }

    guard let url = URL(string: remoteURL),
          let host = url.host?.nilIfEmpty else {
      return nil
    }
    return (host: host, path: url.path)
  }

  func scpHostPathSeparator(in remoteURL: String) -> String.Index? {
    let searchStart = remoteURL.lastIndex(of: "@").map { remoteURL.index(after: $0) }
      ?? remoteURL.startIndex
    return remoteURL[searchStart...].firstIndex(of: ":")
  }

  func sanitizedRepositoryRemoteURL(
    _ remoteURL: String,
    host: String,
    path: String
  ) -> String {
    if remoteURL.contains("://"), var components = URLComponents(string: remoteURL) {
      components.user = nil
      components.password = nil
      components.query = nil
      components.fragment = nil
      if let sanitized = components.string?.nilIfEmpty {
        return sanitized
      }
    }

    // SCP-style remotes have no standard URL representation. Retain only the
    // host and repository path so usernames, passwords, and token-like user
    // fields can never reach the model or selectable UI text.
    return "\(host):\(path)"
  }

  func repositoryProvider(forHost host: String) -> RepositoryProvider? {
    let lowercaseHost = host.lowercased()
    if lowercaseHost.contains("github") {
      return .github
    }
    if lowercaseHost.contains("gitlab") {
      return .gitlab
    }
    return nil
  }

  func repositoryBaseURL(provider: RepositoryProvider, host: String) -> String {
    switch provider {
    case .github:
      return host.lowercased() == "github.com" ? RepositoryProvider.github.defaultBaseURL : "https://\(host)"
    case .gitlab:
      return "https://\(host)"
    }
  }

  func parseBranchStatusLine(_ line: String) -> RepositoryBranchStatus? {
    let text = line.replacingOccurrences(of: "## ", with: "")
    if text.hasPrefix("HEAD ") || text == "HEAD (no branch)" {
      return RepositoryBranchStatus(branchName: nil, upstreamName: nil, isDetached: true)
    }

    if text.hasPrefix("No commits yet on ") {
      let branch = text.replacingOccurrences(of: "No commits yet on ", with: "")
      return RepositoryBranchStatus(branchName: branch.nilIfEmpty, upstreamName: nil)
    }

    let parts = text.components(separatedBy: "...")
    guard let branchName = parts.first?.nilIfEmpty else {
      return nil
    }

    guard parts.count > 1 else {
      return RepositoryBranchStatus(branchName: branchName, upstreamName: nil)
    }

    let upstreamAndSync = parts[1]
    if let bracketStart = upstreamAndSync.firstIndex(of: "[") {
      let upstream = String(upstreamAndSync[..<bracketStart]).trimmedForPublishing.nilIfEmpty
      let syncText = String(upstreamAndSync[bracketStart...])
      return RepositoryBranchStatus(
        branchName: branchName,
        upstreamName: upstream,
        aheadCount: parseSyncCount(label: "ahead", in: syncText),
        behindCount: parseSyncCount(label: "behind", in: syncText)
      )
    }

    return RepositoryBranchStatus(
      branchName: branchName,
      upstreamName: upstreamAndSync.trimmedForPublishing.nilIfEmpty
    )
  }

  func parseSyncCount(label: String, in text: String) -> Int {
    let pattern = #"\#(label) ([0-9]+)"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
      let range = Range(match.range(at: 1), in: text)
    else {
      return 0
    }
    return Int(text[range]) ?? 0
  }

  func changeKind(status: String) -> RepositoryChangeKind {
    if status == "??" { return .untracked }
    if status.contains("A") { return .added }
    if status.contains("M") { return .modified }
    if status.contains("D") { return .deleted }
    if status.contains("R") { return .renamed }
    return .other
  }

  func diffForChangedFile(_ file: RepositoryChangedFile, rootURL: URL) -> String? {
    if file.kind == .untracked {
      return runGitDiff(["diff", "--no-index", "--", "/dev/null", file.displayPath], rootURL: rootURL)
    }

    let stagedDiff = runGitDiff(["diff", "--cached", "--", file.displayPath], rootURL: rootURL)
    let unstagedDiff = runGitDiff(["diff", "--", file.displayPath], rootURL: rootURL)
    let combined = [stagedDiff, unstagedDiff]
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
