import Foundation
import PublishingGitCore

extension LocalRepositoryService {
  /// Detects whether the selected repository is still in a merge or rebase
  /// lifecycle. This remains true after every conflict has been staged; Git's
  /// sequencer marker, not the unmerged-index count, is authoritative.
  public func operationLifecycle(profile: SiteProfile) -> RepositoryOperationLifecycle {
    do {
      guard let lifecycle = try profile.withLocalRepositoryRootAccess({ rootURL in
        try readOperationLifecycle(rootURL: rootURL)
      }) else {
        return RepositoryOperationLifecycle(
          rootPath: "",
          kind: .ambiguous,
          diagnostic: RepositoryOperationLifecycleError.repositoryUnavailable.localizedDescription
        )
      }
      return lifecycle
    } catch {
      let rootPath = profile.resolvedLocalRepositoryRootURL?.standardizedFileURL.path ?? ""
      return RepositoryOperationLifecycle(
        rootPath: rootPath,
        kind: .ambiguous,
        diagnostic: error.localizedDescription
      )
    }
  }

  /// Creates the merge commit after every unresolved index entry has been
  /// staged. A normal staged change without `MERGE_HEAD` is rejected rather
  /// than being committed by this conflict-specific API.
  @discardableResult
  public func commitMerge(
    profile: SiteProfile,
    message: String
  ) throws -> RepositoryOperationLifecycle {
    let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedMessage.isEmpty, normalizedMessage.utf8.count <= 8_192 else {
      throw RepositoryOperationLifecycleError.invalidCommitMessage
    }
    return try performLifecycleAction(
      profile: profile,
      expectedKind: .merge,
      operationName: "完成合并提交",
      arguments: ["commit", "-m", normalizedMessage]
    )
  }

  /// Continues a stopped rebase only when all currently unmerged index entries
  /// have been staged. No merge command can be routed through this API.
  @discardableResult
  public func continueRebase(profile: SiteProfile) throws -> RepositoryOperationLifecycle {
    try performLifecycleAction(
      profile: profile,
      expectedKind: .rebase,
      operationName: "继续变基",
      arguments: ["rebase", "--continue"],
      acceptExistingCommitMessage: true,
      allowedPostOperationKinds: [.none, .rebase]
    )
  }

  /// Restores the pre-merge HEAD using Git's native abort operation. This does
  /// not touch a repository unless `MERGE_HEAD` is currently present.
  @discardableResult
  public func abortMerge(profile: SiteProfile) throws -> RepositoryOperationLifecycle {
    try performLifecycleAction(
      profile: profile,
      expectedKind: .merge,
      operationName: "放弃合并",
      arguments: ["merge", "--abort"],
      requiresResolvedConflicts: false
    )
  }

  /// Restores the pre-rebase HEAD using Git's native abort operation. This does
  /// not route a merge lifecycle through `rebase --abort`.
  @discardableResult
  public func abortRebase(profile: SiteProfile) throws -> RepositoryOperationLifecycle {
    try performLifecycleAction(
      profile: profile,
      expectedKind: .rebase,
      operationName: "放弃变基",
      arguments: ["rebase", "--abort"],
      requiresResolvedConflicts: false
    )
  }

  private func performLifecycleAction(
    profile: SiteProfile,
    expectedKind: RepositoryOperationLifecycleKind,
    operationName: String,
    arguments: [String],
    requiresResolvedConflicts: Bool = true,
    acceptExistingCommitMessage: Bool = false,
    allowedPostOperationKinds: Set<RepositoryOperationLifecycleKind> = [.none]
  ) throws -> RepositoryOperationLifecycle {
    guard profile.resolvedLocalRepositoryRootURL != nil else {
      throw RepositoryOperationLifecycleError.repositoryUnavailable
    }
    guard let value = try profile.withLocalRepositoryRootAccess({ rootURL in
      let before = try readOperationLifecycle(rootURL: rootURL)
      try validateLifecycle(
        before,
        expectedKind: expectedKind,
        requiresResolvedConflicts: requiresResolvedConflicts
      )
      guard before.branchName == profile.branch.trimmedForPublishing else {
        throw RepositoryOperationLifecycleError.repositoryChanged
      }

      let result = runGitCommand(
        arguments,
        rootURL: rootURL,
        acceptExistingCommitMessage: acceptExistingCommitMessage
      )
      if result.terminationStatus != 0 || result.didTimeOut || result.wasOutputTruncated {
        if expectedKind == .rebase,
          let after = try? readOperationLifecycle(rootURL: rootURL),
          after.kind == .rebase,
          after.unresolvedConflictCount > 0
        {
          return after
        }
        throw RepositoryOperationLifecycleError.commandFailed(
          operation: operationName,
          terminated: result.terminationStatus,
          output: result.output
        )
      }

      let after = try readOperationLifecycle(rootURL: rootURL)
      guard after.rootPath == before.rootPath else {
        throw RepositoryOperationLifecycleError.repositoryChanged
      }
      guard after.branchName == before.branchName else {
        throw RepositoryOperationLifecycleError.repositoryChanged
      }
      guard allowedPostOperationKinds.contains(after.kind) else {
        throw RepositoryOperationLifecycleError.operationDidNotFinish(after.kind)
      }
      return after
    }) else {
      throw RepositoryOperationLifecycleError.repositoryUnavailable
    }
    return value
  }

  private func validateLifecycle(
    _ lifecycle: RepositoryOperationLifecycle,
    expectedKind: RepositoryOperationLifecycleKind,
    requiresResolvedConflicts: Bool
  ) throws {
    switch lifecycle.kind {
    case .none:
      throw RepositoryOperationLifecycleError.noOperationInProgress
    case .ambiguous:
      throw RepositoryOperationLifecycleError.ambiguousOperation
    case expectedKind:
      break
    default:
      throw RepositoryOperationLifecycleError.unexpectedOperation(
        expected: expectedKind,
        actual: lifecycle.kind
      )
    }
    if requiresResolvedConflicts, lifecycle.unresolvedConflictCount > 0 {
      throw RepositoryOperationLifecycleError.unresolvedConflicts(lifecycle.unresolvedConflictCount)
    }
  }

  private func readOperationLifecycle(rootURL: URL) throws -> RepositoryOperationLifecycle {
    let canonicalRoot = try verifiedRepositoryRoot(rootURL: rootURL)
    let mergeInProgress = try gitReferenceExists("MERGE_HEAD", rootURL: canonicalRoot)
    let rebaseInProgress = try gitRebaseDirectoryExists(rootURL: canonicalRoot)
    let currentBranchName = try currentBranchName(rootURL: canonicalRoot)
    let branchName: String?
    if rebaseInProgress, currentBranchName == nil {
      branchName = try rebaseOriginalBranchName(rootURL: canonicalRoot)
      guard branchName != nil else {
        throw RepositoryOperationLifecycleError.invalidRepository(
          "无法确认变基开始时的分支。"
        )
      }
    } else {
      branchName = currentBranchName
    }
    let unresolvedConflictCount = try unresolvedConflictCount(rootURL: canonicalRoot)
    let kind: RepositoryOperationLifecycleKind
    switch (mergeInProgress, rebaseInProgress) {
    case (false, false): kind = unresolvedConflictCount == 0 ? .none : .unmergedIndex
    case (true, false): kind = .merge
    case (false, true): kind = .rebase
    case (true, true): kind = .ambiguous
    }

    return RepositoryOperationLifecycle(
      rootPath: canonicalRoot.path,
      branchName: branchName,
      kind: kind,
      unresolvedConflictCount: unresolvedConflictCount
    )
  }

  private func verifiedRepositoryRoot(rootURL: URL) throws -> URL {
    var isDirectory: ObjCBool = false
    let suppliedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard fileManager.fileExists(atPath: suppliedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw RepositoryOperationLifecycleError.repositoryUnavailable
    }

    let result = runGitCommand(["rev-parse", "--show-toplevel"], rootURL: suppliedRoot)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryOperationLifecycleError.invalidRepository("无法确认 Git 工作树根目录。")
    }
    let reportedPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reportedPath.isEmpty else {
      throw RepositoryOperationLifecycleError.invalidRepository("Git 未返回工作树根目录。")
    }
    let reportedRoot = URL(fileURLWithPath: reportedPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard reportedRoot.path == suppliedRoot.path else {
      throw RepositoryOperationLifecycleError.invalidRepository("配置目录不是 Git 工作树根目录。")
    }
    return reportedRoot
  }

  private func currentBranchName(rootURL: URL) throws -> String? {
    let result = runGitCommand(["symbolic-ref", "--quiet", "--short", "HEAD"], rootURL: rootURL)
    if result.terminationStatus == 1 {
      return nil // Detached HEAD is represented explicitly as no branch name.
    }
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryOperationLifecycleError.invalidRepository("无法确认当前分支。")
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private func gitReferenceExists(_ name: String, rootURL: URL) throws -> Bool {
    let result = runGitCommand(["rev-parse", "--verify", "--quiet", name], rootURL: rootURL)
    if result.terminationStatus == 1 { return false }
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryOperationLifecycleError.invalidRepository("无法确认 Git 操作状态。")
    }
    return true
  }

  private func gitRebaseDirectoryExists(rootURL: URL) throws -> Bool {
    for marker in ["rebase-merge", "rebase-apply"] {
      let result = runGitCommand(["rev-parse", "--git-path", marker], rootURL: rootURL)
      guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
        throw RepositoryOperationLifecycleError.invalidRepository("无法确认 Git 变基状态。")
      }
      let rawPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rawPath.isEmpty else {
        throw RepositoryOperationLifecycleError.invalidRepository("Git 未返回变基状态路径。")
      }
      let markerURL = URL(fileURLWithPath: rawPath, relativeTo: rootURL).standardizedFileURL
      if fileManager.fileExists(atPath: markerURL.path) {
        return true
      }
    }
    return false
  }

  private func rebaseOriginalBranchName(rootURL: URL) throws -> String? {
    for path in ["rebase-merge/head-name", "rebase-apply/head-name"] {
      let result = runGitCommand(["rev-parse", "--git-path", path], rootURL: rootURL)
      guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
        throw RepositoryOperationLifecycleError.invalidRepository("无法定位变基分支记录。")
      }
      let rawPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rawPath.isEmpty else { continue }
      let url = URL(fileURLWithPath: rawPath, relativeTo: rootURL).standardizedFileURL
      guard fileManager.fileExists(atPath: url.path) else { continue }
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4_096,
        resourceValues.isSymbolicLink != true
      else {
        throw RepositoryOperationLifecycleError.invalidRepository("变基分支记录不安全。")
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count <= 4_096, let text = String(data: data, encoding: .utf8) else {
        throw RepositoryOperationLifecycleError.invalidRepository("变基分支记录无效。")
      }
      let reference = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = "refs/heads/"
      guard reference.hasPrefix(prefix) else {
        throw RepositoryOperationLifecycleError.invalidRepository("变基分支记录不是本地分支。")
      }
      let branch = String(reference.dropFirst(prefix.count))
      guard !branch.isEmpty, !branch.contains("\0") else {
        throw RepositoryOperationLifecycleError.invalidRepository("变基分支记录无效。")
      }
      let check = runGitCommand(["check-ref-format", "--branch", branch], rootURL: rootURL)
      guard check.terminationStatus == 0, !check.didTimeOut, !check.wasOutputTruncated else {
        throw RepositoryOperationLifecycleError.invalidRepository("变基分支名称无效。")
      }
      return branch
    }
    return nil
  }

  private func unresolvedConflictCount(rootURL: URL) throws -> Int {
    let result = runGitCommand(["diff", "--name-only", "--diff-filter=U", "-z", "--"], rootURL: rootURL)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryOperationLifecycleError.invalidRepository("无法读取未解决冲突索引。")
    }
    return Set(
      result.standardOutput
        .split(separator: "\0", omittingEmptySubsequences: true)
        .map(String.init)
    ).count
  }
}
