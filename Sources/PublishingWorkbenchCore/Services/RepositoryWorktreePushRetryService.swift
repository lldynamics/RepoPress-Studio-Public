import Foundation
import PublishingGitCore

/// Rebuilds and retries a non-force push when a reviewed local commit exists
/// but the earlier network push did not complete. Git is the durable source of
/// truth, so this flow also remains available after the app relaunches.
public struct RepositoryWorktreePushRetryService: Sendable {
  private static let maximumBlobByteCount: Int64 = 100 * 1_024 * 1_024

  private struct RawDiffEntry: Sendable {
    let kind: RepositoryWorktreePublishEntryKind
    let status: String
    let path: String
    let sourcePath: String?
  }

  private let git: GitCommandRunner
  private let safetyAnalyzer: RepositoryPublishSafetyAnalyzer
  private let sitePreflightService: RepositoryPublishPreflightService

  public init(
    gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 120),
    safetyAnalyzer: RepositoryPublishSafetyAnalyzer = RepositoryPublishSafetyAnalyzer(),
    sitePreflightService: RepositoryPublishPreflightService = RepositoryPublishPreflightService()
  ) {
    git = gitCommandRunner
    self.safetyAnalyzer = safetyAnalyzer
    self.sitePreflightService = sitePreflightService
  }

  public func prepare(profile: SiteProfile) throws -> RepositoryWorktreePushRetryConfirmation {
    let snapshot = try inspect(profile: profile)
    let safetyReport = safetyAnalyzer.analyze(
      snapshot: worktreeSafetySnapshot(from: snapshot),
      profile: profile
    )
    guard safetyReport.canPublish else {
      throw RepositoryPublishSafetyError.blocked(safetyReport.blockers)
    }
    let preflight = sitePreflightService.run(profile: profile)
    guard !preflight.blocksPublication else {
      throw RepositoryWorktreePublishError.sitePreflightFailed(preflight.message)
    }
    let fileReviews = RepositoryWorktreeReviewService(git: git).capture(
      entries: snapshot.entries,
      root: URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true),
      baseRevision: snapshot.remoteBranchSHA,
      targetRevision: snapshot.localHeadSHA
    )
    guard try inspect(profile: profile) == snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    return RepositoryWorktreePushRetryConfirmation(
      snapshot: snapshot,
      safetyReport: safetyReport,
      sitePreflightResult: preflight,
      fileReviews: fileReviews
    )
  }

  public func push(
    profile: SiteProfile,
    confirmation: RepositoryWorktreePushRetryConfirmation
  ) throws -> RepositoryWorktreePublishResult {
    guard RepositoryWorktreeFileReview.isComplete(
      entries: confirmation.snapshot.entries, reviews: confirmation.fileReviews
    ) else { throw RepositoryWorktreePublishError.incompleteReview }
    let current = try prepare(profile: profile)
    guard current.snapshot == confirmation.snapshot,
      current.safetyReport == confirmation.safetyReport,
      current.sitePreflightResult?.outcome == confirmation.sitePreflightResult?.outcome
    else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let snapshot = confirmation.snapshot
    let rootURL = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
    let pushOriginBeforePush = try validatedPushOrigin(profile: profile, root: rootURL)
    guard pushOriginBeforePush == snapshot.pushOriginURL else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let result = git.run(
      [
        "push", "--porcelain", "origin",
        "\(snapshot.localHeadSHA):refs/heads/\(snapshot.branch)",
      ],
      rootURL: rootURL
    )
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: snapshot.localHeadSHA,
        message: result.output.nilIfEmpty
          ?? CoreL10n.text("推送未完成，请检查网络或仓库权限后重试。")
      )
    }
    let remoteAfterPush = try requiredRemoteSHA(branch: snapshot.branch, root: rootURL)
    guard remoteAfterPush.caseInsensitiveCompare(snapshot.localHeadSHA) == .orderedSame else {
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: snapshot.localHeadSHA,
        message: "推送完成后远端分支又发生变化，未将其误报为精确推送成功。"
      )
    }
    return RepositoryWorktreePublishResult(
      commitSHA: snapshot.localHeadSHA,
      branch: snapshot.branch,
      pushed: true,
      remoteCommitSHA: remoteAfterPush,
      committedPaths: snapshot.paths
    )
  }

  private func inspect(profile: SiteProfile) throws -> RepositoryWorktreePushRetrySnapshot {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw RepositoryWorktreePublishError.missingRepositoryRoot
    }
    let root = rootURL.standardizedFileURL
    try RepositoryWorktreePublishTransitionCoordinator(gitCommandRunner: git)
      .recoverIfNeeded(profile: profile, root: root)
    let topLevel = try output(["rev-parse", "--show-toplevel"], root: root)
      .trimmedForPublishing
    guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path == root.path else {
      throw RepositoryWorktreePublishError.invalidRepository("配置目录不是 Git 工作树根目录。")
    }
    let branchResult = git.run(
      ["symbolic-ref", "--quiet", "--short", "HEAD"],
      rootURL: root
    )
    guard branchResult.terminationStatus == 0 else {
      throw RepositoryWorktreePublishError.detachedHead
    }
    let branch = branchResult.standardOutput.trimmedForPublishing
    let expectedBranch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    guard branch == expectedBranch else {
      throw RepositoryWorktreePublishError.branchMismatch(
        expected: expectedBranch,
        actual: branch.nilIfEmpty ?? "detached HEAD"
      )
    }
    let originRaw = try output(["remote", "get-url", "origin"], root: root)
      .trimmedForPublishing
    let originURL = try validatedOrigin(originRaw, profile: profile, root: root)
    let pushOriginURL = try validatedPushOrigin(profile: profile, root: root)
    let commonDirectoryOutput = try output(["rev-parse", "--git-common-dir"], root: root)
      .trimmedForPublishing
    guard !commonDirectoryOutput.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository("无法确认 Git 元数据目录。")
    }
    let commonDirectory = URL(
      fileURLWithPath: commonDirectoryOutput,
      relativeTo: root
    ).standardizedFileURL.path

    let stagedPaths = try output(
      ["diff", "--cached", "--name-only", "-z", "HEAD", "--"],
      root: root,
      preserveWhitespace: true
    ).split(separator: "\0").map(String.init).sorted()
    guard stagedPaths.isEmpty else {
      throw RepositoryWorktreePublishError.dirtyIndex(stagedPaths)
    }
    let worktreeStatus = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      root: root,
      preserveWhitespace: true
    )
    guard worktreeStatus.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "已有新的未提交文件变更；请先单独审阅，再重试推送已有提交。"
      )
    }

    let localHeadSHA = try output(["rev-parse", "--verify", "HEAD"], root: root)
      .trimmedForPublishing
    let localTreeSHA = try output(["rev-parse", "HEAD^{tree}"], root: root)
      .trimmedForPublishing
    let remoteBranchSHA = try requiredRemoteSHA(branch: branch, root: root)
    guard localHeadSHA.caseInsensitiveCompare(remoteBranchSHA) != .orderedSame else {
      throw RepositoryWorktreePublishError.noChanges
    }
    let ancestor = git.run(
      ["merge-base", "--is-ancestor", remoteBranchSHA, localHeadSHA],
      rootURL: root
    )
    guard ancestor.terminationStatus == 0 else {
      throw RepositoryWorktreePublishError.remoteOutOfDate(
        local: localHeadSHA,
        remote: remoteBranchSHA
      )
    }
    let commitCountText = try output(
      ["rev-list", "--count", "\(remoteBranchSHA)..\(localHeadSHA)"],
      root: root
    ).trimmedForPublishing
    guard let commitCount = Int(commitCountText), commitCount > 0 else {
      throw RepositoryWorktreePublishError.invalidRepository("无法确认待推送的本地提交。")
    }
    let rawDiff = try output(
      [
        "diff", "--name-status", "-z", "--find-renames",
        remoteBranchSHA, localHeadSHA, "--",
      ],
      root: root,
      preserveWhitespace: true
    )
    let entries = try parseDiff(rawDiff).map { try frozenEntry($0, head: localHeadSHA, root: root) }
      .sorted { lhs, rhs in
        if lhs.path == rhs.path { return (lhs.sourcePath ?? "") < (rhs.sourcePath ?? "") }
        return lhs.path < rhs.path
      }
    let lfsPaths = try entries.compactMap { entry -> String? in
      guard entry.kind != .deleted else { return nil }
      return try usesGitLFS(path: entry.path, root: root) ? entry.path : nil
    }
    guard lfsPaths.isEmpty else {
      throw RepositoryWorktreePublishError.unsupportedPaths(lfsPaths.sorted())
    }
    let allPaths = entries.flatMap { entry in
      [entry.path, entry.sourcePath].compactMap { $0 }
    }
    let sensitivePaths = Array(Set(allPaths.filter(isSensitive))).sorted()
    guard sensitivePaths.isEmpty else {
      throw RepositoryWorktreePublishError.sensitivePaths(sensitivePaths)
    }
    let oversizedPaths = entries.filter {
      $0.byteSize > Self.maximumBlobByteCount
    }.map(\.path)
    guard oversizedPaths.isEmpty else {
      throw RepositoryWorktreePublishError.oversizedPaths(oversizedPaths)
    }
    return RepositoryWorktreePushRetrySnapshot(
      repositoryRoot: root.path,
      gitCommonDirectory: commonDirectory,
      branch: branch,
      originURL: originURL,
      pushOriginURL: pushOriginURL,
      remoteBranchSHA: remoteBranchSHA,
      localHeadSHA: localHeadSHA,
      localTreeSHA: localTreeSHA,
      commitCount: commitCount,
      entries: entries
    )
  }

  private func parseDiff(_ value: String) throws -> [RawDiffEntry] {
    let tokens = value.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var index = 0
    var entries: [RawDiffEntry] = []
    while index < tokens.count {
      let status = tokens[index]
      index += 1
      guard let code = status.first else {
        throw RepositoryWorktreePublishError.invalidRepository("无法解析待重试推送的文件清单。")
      }
      let kind: RepositoryWorktreePublishEntryKind
      switch code {
      case "A": kind = .added
      case "M": kind = .modified
      case "D": kind = .deleted
      case "R": kind = .renamed
      case "C": kind = .copied
      case "T": kind = .typeChanged
      default:
        throw RepositoryWorktreePublishError.invalidRepository("待推送提交包含不支持的 Git 状态：\(status)")
      }
      if code == "R" || code == "C" {
        guard index + 1 < tokens.count else {
          throw RepositoryWorktreePublishError.invalidRepository("无法解析重命名文件清单。")
        }
        let sourcePath = tokens[index].normalizedRelativePath()
        let path = tokens[index + 1].normalizedRelativePath()
        index += 2
        try validateRelativePath(sourcePath)
        try validateRelativePath(path)
        entries.append(
          RawDiffEntry(kind: kind, status: status, path: path, sourcePath: sourcePath)
        )
      } else {
        guard index < tokens.count else {
          throw RepositoryWorktreePublishError.invalidRepository("无法解析待推送文件清单。")
        }
        let path = tokens[index].normalizedRelativePath()
        index += 1
        try validateRelativePath(path)
        entries.append(RawDiffEntry(kind: kind, status: status, path: path, sourcePath: nil))
      }
    }
    return entries
  }

  private func frozenEntry(
    _ raw: RawDiffEntry,
    head: String,
    root: URL
  ) throws -> RepositoryWorktreePublishEntry {
    guard raw.kind != .deleted else {
      return RepositoryWorktreePublishEntry(
        kind: raw.kind,
        status: raw.status,
        path: raw.path,
        sourcePath: raw.sourcePath
      )
    }
    let treeEntry = try output(
      ["ls-tree", "-z", head, "--", raw.path],
      root: root,
      preserveWhitespace: true
    )
    guard let tab = treeEntry.firstIndex(of: "\t") else {
      throw RepositoryWorktreePublishError.invalidRepository("无法读取待推送文件：\(raw.path)")
    }
    let header = treeEntry[..<tab].split(separator: " ")
    guard header.count == 3, header[1] == "blob" else {
      throw RepositoryWorktreePublishError.unsupportedPaths([raw.path])
    }
    let mode = String(header[0])
    let blobOID = String(header[2])
    guard mode == "100644" || mode == "100755" else {
      throw RepositoryWorktreePublishError.unsupportedPaths([raw.path])
    }
    let sizeText = try output(["cat-file", "-s", blobOID], root: root)
      .trimmedForPublishing
    guard let byteSize = Int64(sizeText), byteSize >= 0 else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "无法确认待推送文件大小：\(raw.path)"
      )
    }
    return RepositoryWorktreePublishEntry(
      kind: raw.kind,
      status: raw.status,
      path: raw.path,
      sourcePath: raw.sourcePath,
      byteSize: byteSize,
      mode: mode,
      blobOID: blobOID
    )
  }

  private func worktreeSafetySnapshot(
    from snapshot: RepositoryWorktreePushRetrySnapshot
  ) -> RepositoryWorktreePublishSnapshot {
    RepositoryWorktreePublishSnapshot(
      repositoryRoot: snapshot.repositoryRoot,
      gitCommonDirectory: snapshot.gitCommonDirectory,
      branch: snapshot.branch,
      headSHA: snapshot.remoteBranchSHA,
      originURL: snapshot.originURL,
      pushOriginURL: snapshot.pushOriginURL,
      remoteBranchSHA: snapshot.remoteBranchSHA,
      statusFingerprint: "retry:\(snapshot.remoteBranchSHA):\(snapshot.localHeadSHA)",
      entries: snapshot.entries
    )
  }

  private func requiredRemoteSHA(branch: String, root: URL) throws -> String {
    let text = try output(
      ["ls-remote", "--heads", "origin", "refs/heads/\(branch)"],
      root: root
    )
    guard let sha = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
      !sha.isEmpty
    else {
      throw RepositoryWorktreePublishError.remoteBranchMissing(branch)
    }
    return sha
  }

  private func validatedOrigin(
    _ rawOrigin: String,
    profile: SiteProfile,
    root: URL
  ) throws -> String {
    if let remote = GitRemoteParser.parseRepositoryRemote(rawOrigin) {
      guard remote.provider == profile.repositoryProvider,
        normalizedRepositoryBaseURL(remote.repositoryBaseURL)
          == normalizedRepositoryBaseURL(profile.repositoryBaseURL),
        remote.owner.caseInsensitiveCompare(profile.repoOwner.trimmedForPublishing) == .orderedSame,
        remote.name.caseInsensitiveCompare(profile.repoName.trimmedForPublishing) == .orderedSame
      else {
        throw RepositoryWorktreePublishError.originMismatch(remote.displayName)
      }
      return remote.remoteURL
    }
    guard let localURL = localRemoteURL(rawOrigin, root: root) else {
      throw RepositoryWorktreePublishError.originMismatch(
        GitCommandRunner.redactedDiagnosticText(rawOrigin)
      )
    }
    let repositoryName = localURL.deletingPathExtension().lastPathComponent
    let expectedName = profile.repoName.trimmedForPublishing
    let expectedOwner = profile.repoOwner.trimmedForPublishing
      .split(separator: "/").last.map(String.init) ?? ""
    guard !expectedName.isEmpty,
      repositoryName.caseInsensitiveCompare(expectedName) == .orderedSame,
      expectedOwner.isEmpty
        || localURL.deletingLastPathComponent().lastPathComponent
          .caseInsensitiveCompare(expectedOwner) == .orderedSame
    else {
      throw RepositoryWorktreePublishError.originMismatch(localURL.path)
    }
    return localURL.path
  }

  private func validatedPushOrigin(profile: SiteProfile, root: URL) throws -> String {
    let raw = try output(
      ["remote", "get-url", "--push", "--all", "origin"],
      root: root,
      preserveWhitespace: true
    )
    let values = raw.split(whereSeparator: { $0.isNewline }).map(String.init)
    guard values.count == 1, let value = values.first else {
      throw RepositoryWorktreePublishError.originMismatch(
        "origin 必须只有一个经过审阅的推送地址。"
      )
    }
    return try validatedOrigin(value, profile: profile, root: root)
  }

  private func normalizedRepositoryBaseURL(_ value: String) -> String {
    value.trimmedForPublishing.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
  }

  private func localRemoteURL(_ value: String, root: URL) -> URL? {
    if value.lowercased().hasPrefix("file://") {
      return URL(string: value)?.standardizedFileURL
    }
    guard value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") else {
      return nil
    }
    return URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL
  }

  private func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty,
      path == path.normalizedRelativePath(),
      !path.hasPrefix("/"),
      !path.contains("\\"),
      !path.split(separator: "/").contains(".."),
      path != ".git",
      !path.hasPrefix(".git/")
    else {
      throw RepositoryWorktreePublishError.unsupportedPaths([path])
    }
  }

  private func isSensitive(_ path: String) -> Bool {
    let components = path.lowercased().split(separator: "/").map(String.init)
    guard let filename = components.last else { return true }
    if components.contains(where: { [".ssh", ".aws", ".gnupg"].contains($0) }) {
      return true
    }
    if filename == ".env" || filename.hasPrefix(".env.") {
      return true
    }
    if [
      ".npmrc", ".pypirc", ".netrc", "credentials", "credentials.json",
      "id_rsa", "id_ed25519",
    ].contains(filename) {
      return true
    }
    if filename.hasPrefix("service-account") && filename.hasSuffix(".json") {
      return true
    }
    return ["pem", "key", "p12", "pfx", "mobileprovision"]
      .contains((filename as NSString).pathExtension)
  }

  private func usesGitLFS(path: String, root: URL) throws -> Bool {
    let attributes = try output(
      ["check-attr", "-z", "filter", "--", path],
      root: root,
      preserveWhitespace: true
    ).split(separator: "\0", omittingEmptySubsequences: false)
    return attributes.count >= 3 && attributes[2].lowercased() == "lfs"
  }

  private func output(
    _ arguments: [String],
    root: URL,
    preserveWhitespace: Bool = false
  ) throws -> String {
    let result = git.run(
      arguments,
      rootURL: root,
      preserveStandardOutputWhitespace: preserveWhitespace
    )
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryWorktreePublishError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(arguments),
        output: result.output
      )
    }
    return result.standardOutput
  }
}
