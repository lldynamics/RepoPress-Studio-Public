import Foundation
import PublishingGitCore

/// Publishes the repository worktree as one ordinary, non-force Git commit.
/// It is deliberately separate from article `PublishPackage` handling because
/// a complete repository transaction must preserve deletes, executable modes,
/// binary blobs, and every non-ignored path.
public struct RepositoryWorktreePublishService: Sendable {
  private static let maximumBlobByteCount: Int64 = 100 * 1_024 * 1_024

  private struct RawStatusEntry: Sendable {
    let status: String
    let path: String
    let sourcePath: String?
  }

  private struct StagedEntry: Sendable {
    let mode: String
    let blobOID: String
    let stage: String
    let path: String
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

  /// Performs no index, commit, or remote mutation.
  public func prepare(
    profile: SiteProfile,
    commitMessage: String
  ) throws -> RepositoryWorktreePublishConfirmation {
    let normalizedMessage = commitMessage.trimmedForPublishing
    guard !normalizedMessage.isEmpty else {
      throw RepositoryWorktreePublishError.invalidCommitMessage
    }
    guard let root = profile.localRepositoryRootURL else {
      throw RepositoryWorktreePublishError.missingRepositoryRoot
    }
    let snapshot = try inspect(profile: profile, root: root)
    let safetyReport = try validatedSafetyReport(snapshot: snapshot, profile: profile)
    let sitePreflightResult = try validatedSitePreflight(profile: profile)
    let afterPreflight = try inspect(profile: profile, root: root)
    guard afterPreflight == snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    return RepositoryWorktreePublishConfirmation(
      snapshot: snapshot,
      commitMessage: normalizedMessage,
      safetyReport: safetyReport,
      sitePreflightResult: sitePreflightResult
    )
  }

  /// Revalidates the complete frozen review, stages all paths, verifies the
  /// resulting index, commits, and pushes one exact non-force refspec.
  public func publish(
    profile: SiteProfile,
    confirmation: RepositoryWorktreePublishConfirmation
  ) throws -> RepositoryWorktreePublishResult {
    guard let root = profile.localRepositoryRootURL else {
      throw RepositoryWorktreePublishError.missingRepositoryRoot
    }
    guard !confirmation.commitMessage.trimmedForPublishing.isEmpty else {
      throw RepositoryWorktreePublishError.invalidCommitMessage
    }
    let current = try inspect(profile: profile, root: root)
    guard current == confirmation.snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let currentSafetyReport = try validatedSafetyReport(snapshot: current, profile: profile)
    guard currentSafetyReport == confirmation.safetyReport else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let sitePreflightResult = try validatedSitePreflight(profile: profile)
    guard confirmation.sitePreflightResult != nil else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    guard sitePreflightResult.outcome == confirmation.sitePreflightResult?.outcome else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let afterPreflight = try inspect(profile: profile, root: root)
    guard afterPreflight == confirmation.snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }

    do {
      _ = try output(["add", "-A", "--", "."], root: root)
      guard try stagedIndexMatches(confirmation.snapshot, root: root),
        try worktreeHasNoChangesBeyondIndex(root: root)
      else {
        restoreEmptyIndex(root: root)
        throw RepositoryWorktreePublishError.stagedVerificationFailed
      }
    } catch {
      restoreEmptyIndex(root: root)
      throw error
    }

    let stagedTree: String
    do {
      stagedTree = try output(["write-tree"], root: root).trimmedForPublishing
      guard !stagedTree.isEmpty else {
        throw RepositoryWorktreePublishError.stagedVerificationFailed
      }
      _ = try output(
        ["commit", "-m", confirmation.commitMessage],
        root: root
      )
    } catch {
      restoreEmptyIndex(root: root)
      throw error
    }

    let commitSHA: String
    do {
      commitSHA = try output(["rev-parse", "HEAD"], root: root).trimmedForPublishing
      let commitTree = try output(["rev-parse", "HEAD^{tree}"], root: root)
        .trimmedForPublishing
      let parentSHA = try output(["rev-parse", "HEAD^"], root: root)
        .trimmedForPublishing
      guard !commitSHA.isEmpty,
        commitTree == stagedTree,
        parentSHA == confirmation.snapshot.headSHA
      else {
        throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
          commitSHA: commitSHA,
          message: "提交结果与已审阅的父提交或文件树不一致，未执行推送。"
        )
      }

      guard try worktreeIsClean(root: root) else {
        throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
          commitSHA: commitSHA,
          message: "提交后工作区又出现变化，未执行推送；请重新审阅。"
        )
      }
      let remoteBeforePush = try requiredRemoteSHA(
        branch: confirmation.snapshot.branch,
        root: root
      )
      guard remoteBeforePush == confirmation.snapshot.remoteBranchSHA else {
        throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
          commitSHA: commitSHA,
          message: "远端分支在提交期间发生变化，非强制推送已停止。"
        )
      }
    } catch let error as RepositoryWorktreePublishError {
      if case .commitSucceededButPushFailed = error {
        throw error
      }
      let recoveredSHA =
        (try? output(["rev-parse", "HEAD"], root: root))?
        .trimmedForPublishing ?? "unknown"
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: recoveredSHA,
        message: error.localizedDescription
      )
    } catch {
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: commitSHAIfAvailable(root: root),
        message: error.localizedDescription
      )
    }

    do {
      _ = try output(
        [
          "push", "--porcelain", "origin",
          "HEAD:refs/heads/\(confirmation.snapshot.branch)",
        ],
        root: root
      )
      let remoteAfterPush = try requiredRemoteSHA(
        branch: confirmation.snapshot.branch,
        root: root
      )
      guard remoteAfterPush.caseInsensitiveCompare(commitSHA) == .orderedSame else {
        throw RepositoryWorktreePublishError.gitFailed(
          command: "git ls-remote --heads origin",
          output: "远端提交与本地提交不一致。"
        )
      }
      return RepositoryWorktreePublishResult(
        commitSHA: commitSHA,
        branch: confirmation.snapshot.branch,
        pushed: true,
        remoteCommitSHA: remoteAfterPush,
        committedPaths: confirmation.snapshot.paths
      )
    } catch {
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: commitSHA,
        message: error.localizedDescription
      )
    }
  }

  private func validatedSafetyReport(
    snapshot: RepositoryWorktreePublishSnapshot,
    profile: SiteProfile
  ) throws -> RepositoryPublishSafetyReport {
    let report = safetyAnalyzer.analyze(snapshot: snapshot, profile: profile)
    guard report.canPublish else {
      throw RepositoryPublishSafetyError.blocked(report.blockers)
    }
    return report
  }

  private func validatedSitePreflight(
    profile: SiteProfile
  ) throws -> RepositoryPublishPreflightResult {
    let result = sitePreflightService.run(profile: profile)
    guard !result.blocksPublication else {
      throw RepositoryWorktreePublishError.sitePreflightFailed(result.message)
    }
    return result
  }

  private func inspect(
    profile: SiteProfile,
    root: URL
  ) throws -> RepositoryWorktreePublishSnapshot {
    let standardizedRoot = root.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standardizedRoot.path) else {
      throw RepositoryWorktreePublishError.invalidRepository("本地仓库目录不存在。")
    }

    let topLevel = try output(["rev-parse", "--show-toplevel"], root: standardizedRoot)
      .trimmedForPublishing
    guard
      URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path
        == standardizedRoot.path
    else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "配置目录不是 Git 工作树根目录。"
      )
    }

    let commonDirectoryOutput = try output(
      ["rev-parse", "--git-common-dir"],
      root: standardizedRoot
    ).trimmedForPublishing
    guard !commonDirectoryOutput.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository("无法确认 Git 元数据目录。")
    }
    let commonDirectory = URL(
      fileURLWithPath: commonDirectoryOutput,
      relativeTo: standardizedRoot
    ).standardizedFileURL.path

    let branchResult = git.run(
      ["symbolic-ref", "--quiet", "--short", "HEAD"],
      rootURL: standardizedRoot
    )
    guard branchResult.terminationStatus == 0 else {
      throw RepositoryWorktreePublishError.detachedHead
    }
    let branch = branchResult.standardOutput.trimmedForPublishing
    let expectedBranch = profile.branch.trimmedForPublishing
    guard !expectedBranch.isEmpty, branch == expectedBranch else {
      throw RepositoryWorktreePublishError.branchMismatch(
        expected: expectedBranch.isEmpty ? "main" : expectedBranch,
        actual: branch.isEmpty ? "detached HEAD" : branch
      )
    }

    let originRaw = try output(
      ["remote", "get-url", "origin"],
      root: standardizedRoot
    ).trimmedForPublishing
    let safeOrigin = try validatedOrigin(
      originRaw,
      profile: profile,
      root: standardizedRoot
    )

    let head = try output(["rev-parse", "--verify", "HEAD"], root: standardizedRoot)
      .trimmedForPublishing
    guard !head.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository("仓库还没有可发布的提交。")
    }
    let remoteSHA = try requiredRemoteSHA(branch: branch, root: standardizedRoot)
    guard remoteSHA.caseInsensitiveCompare(head) == .orderedSame else {
      throw RepositoryWorktreePublishError.remoteOutOfDate(local: head, remote: remoteSHA)
    }

    let status = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      root: standardizedRoot
    )
    let rawEntries = try parseStatus(status)
    guard !rawEntries.isEmpty else {
      throw RepositoryWorktreePublishError.noChanges
    }

    let unmerged =
      rawEntries
      .filter { isUnmerged(status: $0.status) }
      .flatMap { [$0.path, $0.sourcePath].compactMap { $0 } }
      .sorted()
    guard unmerged.isEmpty else {
      throw RepositoryWorktreePublishError.unmergedPaths(unmerged)
    }

    let staged =
      rawEntries
      .filter { isStaged(status: $0.status) }
      .flatMap { [$0.path, $0.sourcePath].compactMap { $0 } }
      .sorted()
    guard staged.isEmpty else {
      throw RepositoryWorktreePublishError.dirtyIndex(staged)
    }

    for rawEntry in rawEntries {
      try validateRelativePath(rawEntry.path, root: standardizedRoot)
      if let sourcePath = rawEntry.sourcePath {
        try validateRelativePath(sourcePath, root: standardizedRoot)
      }
    }

    let allPaths = rawEntries.flatMap { [$0.path, $0.sourcePath].compactMap { $0 } }
    let sensitivePaths = Array(Set(allPaths.filter(isSensitive))).sorted()
    guard sensitivePaths.isEmpty else {
      throw RepositoryWorktreePublishError.sensitivePaths(sensitivePaths)
    }

    let respectsFileMode = try repositoryRespectsFileMode(root: standardizedRoot)
    let entries = try rawEntries.map { rawEntry in
      try frozenEntry(
        rawEntry,
        root: standardizedRoot,
        respectsFileMode: respectsFileMode
      )
    }.sorted { lhs, rhs in
      if lhs.path == rhs.path {
        return (lhs.sourcePath ?? "") < (rhs.sourcePath ?? "")
      }
      return lhs.path < rhs.path
    }

    let unsupportedPaths = entries.filter { entry in
      entry.mode == "120000" || entry.mode == "160000"
    }.map(\.path)
    guard unsupportedPaths.isEmpty else {
      throw RepositoryWorktreePublishError.unsupportedPaths(unsupportedPaths)
    }
    let oversizedPaths = entries.filter {
      $0.byteSize > Self.maximumBlobByteCount
    }.map(\.path)
    guard oversizedPaths.isEmpty else {
      throw RepositoryWorktreePublishError.oversizedPaths(oversizedPaths)
    }

    return RepositoryWorktreePublishSnapshot(
      repositoryRoot: standardizedRoot.path,
      gitCommonDirectory: commonDirectory,
      branch: branch,
      headSHA: head,
      originURL: safeOrigin,
      remoteBranchSHA: remoteSHA,
      statusFingerprint: status,
      entries: entries
    )
  }

  private func frozenEntry(
    _ rawEntry: RawStatusEntry,
    root: URL,
    respectsFileMode: Bool
  ) throws -> RepositoryWorktreePublishEntry {
    let kind = entryKind(status: rawEntry.status)
    let fileURL = root.appendingPathComponent(rawEntry.path)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: fileURL.path,
      isDirectory: &isDirectory
    )

    if kind == .deleted && !exists {
      return RepositoryWorktreePublishEntry(
        kind: kind,
        status: rawEntry.status,
        path: rawEntry.path,
        sourcePath: rawEntry.sourcePath
      )
    }
    guard exists, !isDirectory.boolValue else {
      throw RepositoryWorktreePublishError.unsupportedPaths([rawEntry.path])
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw RepositoryWorktreePublishError.unsupportedPaths([rawEntry.path])
    }
    if try usesGitLFS(path: rawEntry.path, root: root) {
      throw RepositoryWorktreePublishError.unsupportedPaths([rawEntry.path])
    }

    let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let currentPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    let currentMode = currentPermissions & 0o111 == 0 ? "100644" : "100755"
    let trackedMode = try trackedMode(path: rawEntry.path, root: root)
    let mode =
      respectsFileMode || rawEntry.status == "??"
      ? currentMode
      : (trackedMode ?? currentMode)
    let blobOID = try output(
      ["hash-object", "--path=\(rawEntry.path)", "--", rawEntry.path],
      root: root
    ).trimmedForPublishing
    guard !blobOID.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "无法冻结文件 \(rawEntry.path) 的 Git blob。"
      )
    }

    return RepositoryWorktreePublishEntry(
      kind: kind,
      status: rawEntry.status,
      path: rawEntry.path,
      sourcePath: rawEntry.sourcePath,
      byteSize: byteSize,
      mode: mode,
      blobOID: blobOID
    )
  }

  private func stagedIndexMatches(
    _ snapshot: RepositoryWorktreePublishSnapshot,
    root: URL
  ) throws -> Bool {
    let stagedPathOutput = try output(
      ["diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--"],
      root: root
    )
    let stagedPaths = Set(
      stagedPathOutput.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    )
    guard stagedPaths == Set(snapshot.paths) else { return false }

    for entry in snapshot.entries {
      let stageOutput = try output(
        ["ls-files", "--stage", "-z", "--", entry.path],
        root: root
      )
      let stagedEntries = parseStagedEntries(stageOutput)
      if entry.kind == .deleted {
        guard stagedEntries.isEmpty else { return false }
      } else {
        guard stagedEntries.count == 1,
          let staged = stagedEntries.first,
          staged.stage == "0",
          staged.path == entry.path,
          staged.mode == entry.mode,
          staged.blobOID == entry.blobOID
        else {
          return false
        }
      }
      if let sourcePath = entry.sourcePath, sourcePath != entry.path {
        let sourceStage = try output(
          ["ls-files", "--stage", "-z", "--", sourcePath],
          root: root
        )
        guard sourceStage.isEmpty else { return false }
      }
    }
    return true
  }

  private func worktreeHasNoChangesBeyondIndex(root: URL) throws -> Bool {
    let diff = git.run(["diff", "--quiet", "--"], rootURL: root)
    guard diff.terminationStatus == 0 || diff.terminationStatus == 1 else {
      throw gitFailure(arguments: ["diff", "--quiet", "--"], result: diff)
    }
    guard diff.terminationStatus == 0 else { return false }
    let untracked = try output(
      ["ls-files", "--others", "--exclude-standard", "-z"],
      root: root
    )
    return untracked.isEmpty
  }

  private func worktreeIsClean(root: URL) throws -> Bool {
    try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      root: root
    ).isEmpty
  }

  private func restoreEmptyIndex(root: URL) {
    _ = git.run(["reset", "--mixed", "--quiet", "HEAD", "--"], rootURL: root)
  }

  private func validatedOrigin(
    _ rawOrigin: String,
    profile: SiteProfile,
    root: URL
  ) throws -> String {
    if let remote = GitRemoteParser.parseRepositoryRemote(rawOrigin) {
      guard remote.provider == profile.repositoryProvider,
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
    let expectedOwner =
      profile.repoOwner.trimmedForPublishing
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

  private func localRemoteURL(_ value: String, root: URL) -> URL? {
    if value.lowercased().hasPrefix("file://") {
      return URL(string: value)?.standardizedFileURL
    }
    guard value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") else {
      return nil
    }
    return URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL
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

  private func trackedMode(path: String, root: URL) throws -> String? {
    parseStagedEntries(
      try output(["ls-files", "--stage", "-z", "--", path], root: root)
    ).first(where: { $0.stage == "0" && $0.path == path })?.mode
  }

  private func repositoryRespectsFileMode(root: URL) throws -> Bool {
    let arguments = ["config", "--bool", "core.filemode"]
    let result = git.run(arguments, rootURL: root)
    if result.terminationStatus == 1,
      !result.didTimeOut,
      !result.wasOutputTruncated,
      result.standardError.isEmpty
    {
      return true
    }
    guard result.terminationStatus == 0,
      !result.didTimeOut,
      !result.wasOutputTruncated
    else {
      throw gitFailure(arguments: arguments, result: result)
    }
    return result.standardOutput.trimmedForPublishing.lowercased() != "false"
  }

  private func usesGitLFS(path: String, root: URL) throws -> Bool {
    let output = try self.output(
      ["check-attr", "-z", "filter", "--", path],
      root: root
    )
    let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
    return fields.count >= 3 && fields[2].lowercased() == "lfs"
  }

  private func parseStatus(_ text: String) throws -> [RawStatusEntry] {
    let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var entries: [RawStatusEntry] = []
    var index = 0
    while index < fields.count {
      let field = fields[index]
      guard field.count >= 3 else {
        throw RepositoryWorktreePublishError.invalidRepository(
          "Git 状态记录不完整。"
        )
      }
      let status = String(field.prefix(2))
      let separatorIndex = field.index(field.startIndex, offsetBy: 2)
      guard field[separatorIndex] == " " else {
        throw RepositoryWorktreePublishError.invalidRepository(
          "Git 状态记录格式无效。"
        )
      }
      let path = String(field[field.index(after: separatorIndex)...])
      let isRenameOrCopy = status.contains("R") || status.contains("C")
      let sourcePath: String?
      if isRenameOrCopy {
        index += 1
        guard index < fields.count else {
          throw RepositoryWorktreePublishError.invalidRepository(
            "Git 重命名状态缺少源路径。"
          )
        }
        sourcePath = fields[index]
      } else {
        sourcePath = nil
      }
      entries.append(
        RawStatusEntry(status: status, path: path, sourcePath: sourcePath)
      )
      index += 1
    }
    return entries
  }

  private func parseStagedEntries(_ text: String) -> [StagedEntry] {
    text.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
      guard let tabIndex = record.firstIndex(of: "\t") else { return nil }
      let metadata = record[..<tabIndex].split(separator: " ")
      guard metadata.count == 3 else { return nil }
      return StagedEntry(
        mode: String(metadata[0]),
        blobOID: String(metadata[1]),
        stage: String(metadata[2]),
        path: String(record[record.index(after: tabIndex)...])
      )
    }
  }

  private func validateRelativePath(_ path: String, root: URL) throws {
    let normalized = path.normalizedRelativePath()
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    let resolvedPath = root.appendingPathComponent(path).standardizedFileURL.path
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.contains("\0"),
      !path.contains("\u{FFFD}"),
      normalized == path,
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      !components.contains(where: { $0.lowercased() == ".git" }),
      resolvedPath.hasPrefix(root.path + "/")
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

  private func isUnmerged(status: String) -> Bool {
    ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status)
  }

  private func isStaged(status: String) -> Bool {
    guard let first = status.first else { return false }
    return first != " " && first != "?"
  }

  private func entryKind(status: String) -> RepositoryWorktreePublishEntryKind {
    if status.contains("R") { return .renamed }
    if status.contains("C") { return .copied }
    if status.contains("D") { return .deleted }
    if status.contains("T") { return .typeChanged }
    if status == "??" || status.contains("A") { return .added }
    return .modified
  }

  private func output(_ arguments: [String], root: URL) throws -> String {
    let result = git.run(
      arguments,
      rootURL: root,
      preserveStandardOutputWhitespace: true
    )
    guard result.terminationStatus == 0,
      !result.didTimeOut,
      !result.wasOutputTruncated
    else {
      throw gitFailure(arguments: arguments, result: result)
    }
    return result.standardOutput
  }

  private func gitFailure(
    arguments: [String],
    result: GitCommandResult
  ) -> RepositoryWorktreePublishError {
    var diagnostic = result.output
    if result.didTimeOut {
      diagnostic = "Git 命令超时。\n" + diagnostic
    }
    if result.wasOutputTruncated {
      diagnostic = "Git 输出超过安全上限。\n" + diagnostic
    }
    return .gitFailed(
      command: GitCommandRunner.redactedCommandDescription(arguments),
      output: diagnostic.trimmedForPublishing
    )
  }

  private func commitSHAIfAvailable(root: URL) -> String {
    (try? output(["rev-parse", "HEAD"], root: root))?.trimmedForPublishing
      ?? "unknown"
  }
}
