import Foundation
import PublishingGitCore

/// Guarded implementation of the common "stash, rebase, restore" workflow.
/// It never pulls, pushes, resets, cleans, aborts, or force-updates a ref.
public struct RepositoryRebaseSyncService: Sendable {
  private struct Context: Sendable {
    let branch: String
    let upstream: String
    let originURL: String
    let commonDirectory: String
  }

  private struct RawStatus: Sendable {
    let status: String
    let path: String
    let sourcePath: String?
  }

  private struct IndexEntry: Sendable {
    let mode: String
    let blobOID: String
  }

  private let git: GitCommandRunner
  private let recoveryRecorder:
    (@Sendable (RepositoryRebaseRecoveryContext) throws -> Void)?

  public init(
    gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 120),
    recoveryRecorder: (@Sendable (RepositoryRebaseRecoveryContext) throws -> Void)? = nil
  ) {
    git = gitCommandRunner
    self.recoveryRecorder = recoveryRecorder
  }

  public func prepare(profile: SiteProfile) throws -> RepositoryRebaseSyncPreparation {
    let root = try requiredRoot(profile)
    let context = try validateContext(profile: profile, root: root)
    try requireNoOperationInProgress(context: context)
    try limitedFetch(branch: context.branch, root: root)
    let snapshot = try inspect(
      profile: profile,
      root: root,
      context: context,
      requireRemoteTrackingMatch: true
    )
    if snapshot.localHeadSHA == snapshot.remoteHeadSHA {
      return .alreadySynchronized(branch: snapshot.branch, headSHA: snapshot.localHeadSHA)
    }
    guard snapshot.aheadCount > 0, snapshot.behindCount > 0 else {
      throw RepositoryRebaseSyncError.notDiverged(
        ahead: snapshot.aheadCount,
        behind: snapshot.behindCount
      )
    }
    return .confirmation(RepositoryRebaseSyncConfirmation(snapshot: snapshot))
  }

  public func apply(
    profile: SiteProfile,
    confirmation: RepositoryRebaseSyncConfirmation
  ) throws -> RepositoryRebaseSyncResult {
    let root = try requiredRoot(profile)
    let context = try validateContext(profile: profile, root: root)
    try requireNoOperationInProgress(context: context)
    let current = try inspect(
      profile: profile,
      root: root,
      context: context,
      requireRemoteTrackingMatch: false
    )
    guard current == confirmation.snapshot else {
      throw RepositoryRebaseSyncError.snapshotDrift
    }
    let snapshot = confirmation.snapshot
    guard try liveRemoteSHA(branch: context.branch, root: root) == snapshot.remoteHeadSHA,
      try output(["rev-parse", "refs/remotes/origin/\(context.branch)"], root: root)
        .trimmedForPublishing == snapshot.remoteHeadSHA
    else { throw RepositoryRebaseSyncError.snapshotDrift }

    let hasLocalChanges = !snapshot.localChanges.isEmpty
    let stashSHA = try hasLocalChanges ? createVerifiedStash(snapshot: snapshot, root: root) : nil
    func recovery(_ phase: RepositoryRebaseRecoveryContext.Phase) -> RepositoryRebaseRecoveryContext? {
      stashSHA.map { makeRecoveryContext(snapshot: snapshot, stashSHA: $0, phase: phase) }
    }

    let rebaseArguments = ["rebase", snapshot.remoteHeadSHA]
    let rebase = git.run(rebaseArguments, rootURL: root)
    guard rebase.terminationStatus == 0, !rebase.didTimeOut, !rebase.wasOutputTruncated else {
      let conflicts: [String]
      do {
        conflicts = try unmergedPaths(root: root)
      } catch {
        let recovery = recovery(.incomplete)
        try recordRecovery(recovery)
        throw RepositoryRebaseSyncError.partial(
          recovery: recovery,
          message:
            "变基失败，且无法读取冲突路径：\(error.localizedDescription)；\(diagnostic(for: rebase, arguments: rebaseArguments))"
        )
      }
      if !conflicts.isEmpty {
        let recovery = recovery(.rebaseConflict)
        try recordRecovery(recovery)
        throw RepositoryRebaseSyncError.rebaseConflict(
          recovery: recovery,
          paths: conflicts
        )
      }
      let recovery = recovery(.incomplete)
      try recordRecovery(recovery)
      throw RepositoryRebaseSyncError.partial(
        recovery: recovery,
        message: diagnostic(for: rebase, arguments: rebaseArguments)
      )
    }

    let rebasedHead = try output(["rev-parse", "HEAD"], root: root).trimmedForPublishing
    let ancestor = git.run(
      ["merge-base", "--is-ancestor", snapshot.remoteHeadSHA, rebasedHead],
      rootURL: root
    )
    guard ancestor.terminationStatus == 0 else {
      let recovery = recovery(.incomplete)
      try recordRecovery(recovery)
      throw RepositoryRebaseSyncError.partial(
        recovery: recovery,
        message: "变基后无法证明已审阅远端提交是当前 HEAD 的祖先。"
      )
    }

    var stashWasRetained = false
    if let stashSHA {
      let rebaseCompletedRecovery = makeRecoveryContext(
        snapshot: snapshot,
        stashSHA: stashSHA,
        phase: .rebaseCompleted
      )
      try recordRecovery(rebaseCompletedRecovery)
      guard try stashCommitExists(stashSHA, root: root) else {
        throw RepositoryRebaseSyncError.partial(
          recovery: rebaseCompletedRecovery,
          message: "恢复 stash 提交不再可用，未自动恢复或删除任何 stash。"
        )
      }
      let restoreInProgressRecovery = rebaseCompletedRecovery.changingPhase(
        to: .stashRestoreInProgress
      )
      try recordRecovery(restoreInProgressRecovery)
      let restoreArguments = ["stash", "apply", "--index", stashSHA]
      let restore = git.run(restoreArguments, rootURL: root)
      guard restore.terminationStatus == 0, !restore.didTimeOut, !restore.wasOutputTruncated else {
        let conflicts: [String]
        do {
          conflicts = try unmergedPaths(root: root)
        } catch {
          let recovery = restoreInProgressRecovery.changingPhase(to: .incomplete)
          try recordRecovery(recovery)
          throw RepositoryRebaseSyncError.partial(
            recovery: recovery,
            message:
              "恢复 stash 失败，且无法读取冲突路径：\(error.localizedDescription)；\(diagnostic(for: restore, arguments: restoreArguments))"
          )
        }
        if !conflicts.isEmpty {
          let recovery = restoreInProgressRecovery.changingPhase(to: .stashRestoreConflict)
          try recordRecovery(recovery)
          throw RepositoryRebaseSyncError.stashRestoreConflict(
            recovery: recovery,
            paths: conflicts
          )
        }
        let recovery = restoreInProgressRecovery.changingPhase(to: .incomplete)
        try recordRecovery(recovery)
        throw RepositoryRebaseSyncError.partial(
          recovery: recovery,
          message: diagnostic(
            for: restore,
            arguments: restoreArguments
          )
        )
      }
      let remainingConflicts = try unmergedPaths(root: root)
      guard remainingConflicts.isEmpty else {
        let recovery = restoreInProgressRecovery.changingPhase(to: .stashRestoreConflict)
        try recordRecovery(recovery)
        throw RepositoryRebaseSyncError.stashRestoreConflict(
          recovery: recovery,
          paths: remainingConflicts
        )
      }
      try recordRecovery(restoreInProgressRecovery.changingPhase(to: .completed))
      if try currentStashSHA(root: root) == stashSHA {
        let drop = git.run(["stash", "drop", "stash@{0}"], rootURL: root)
        stashWasRetained = drop.terminationStatus != 0 || drop.didTimeOut || drop.wasOutputTruncated
      } else {
        // The requested WIP is restored, but another actor changed the stack.
        // Never guess which reflog entry should be deleted.
        stashWasRetained = true
      }
    }

    return RepositoryRebaseSyncResult(
      branch: snapshot.branch,
      previousHeadSHA: snapshot.localHeadSHA,
      rebasedHeadSHA: rebasedHead,
      restoredLocalChanges: snapshot.localChanges.map(\.path).sorted(),
      stashWasCreated: stashSHA != nil,
      stashWasRetained: stashWasRetained
    )
  }

  /// Restores only the frozen stash commit represented by a persisted recovery
  /// context. It is intentionally unavailable while a merge/rebase sequencer
  /// is present, and never guesses a reflog selector.
  public func restoreAfterRebase(
    profile: SiteProfile,
    recovery: RepositoryRebaseRecoveryContext
  ) throws -> RepositoryRebaseRecoveryResult {
    let root = try requiredRoot(profile)
    let context = try validateContext(profile: profile, root: root)
    try requireNoOperationInProgress(context: context)
    guard [.stashedBeforeRebase, .rebaseConflict, .rebaseCompleted].contains(recovery.phase)
    else {
      throw RepositoryRebaseSyncError.invalidRecoveryContext("当前恢复阶段不允许再次自动应用 stash。")
    }
    try validateRecovery(recovery, root: root, context: context)
    guard try stashCommitExists(recovery.stashCommitSHA, root: root) else {
      throw RepositoryRebaseSyncError.recoveryStashUnavailable(recovery)
    }

    let restoreInProgressRecovery = recovery.changingPhase(to: .stashRestoreInProgress)
    try recordRecovery(restoreInProgressRecovery)
    let arguments = ["stash", "apply", "--index", recovery.stashCommitSHA]
    let restore = git.run(arguments, rootURL: root)
    guard restore.terminationStatus == 0, !restore.didTimeOut, !restore.wasOutputTruncated else {
      let paths: [String]
      do { paths = try unmergedPaths(root: root) } catch {
        let recovery = restoreInProgressRecovery.changingPhase(to: .incomplete)
        try recordRecovery(recovery)
        throw RepositoryRebaseSyncError.partial(
          recovery: recovery,
          message: "恢复 stash 失败，且无法读取冲突路径：\(error.localizedDescription)；\(diagnostic(for: restore, arguments: arguments))"
        )
      }
      if !paths.isEmpty {
        let recovery = restoreInProgressRecovery.changingPhase(to: .stashRestoreConflict)
        try recordRecovery(recovery)
        throw RepositoryRebaseSyncError.stashRestoreConflict(
          recovery: recovery, paths: paths)
      }
      let recovery = restoreInProgressRecovery.changingPhase(to: .incomplete)
      try recordRecovery(recovery)
      throw RepositoryRebaseSyncError.partial(
        recovery: recovery,
        message: diagnostic(for: restore, arguments: arguments)
      )
    }
    let paths = try unmergedPaths(root: root)
    guard paths.isEmpty else {
      let recovery = restoreInProgressRecovery.changingPhase(to: .stashRestoreConflict)
      try recordRecovery(recovery)
      throw RepositoryRebaseSyncError.stashRestoreConflict(
        recovery: recovery, paths: paths)
    }
    try recordRecovery(restoreInProgressRecovery.changingPhase(to: .completed))
    var retained = false
    if try currentStashSHA(root: root) == recovery.stashCommitSHA {
      let drop = git.run(["stash", "drop", "stash@{0}"], rootURL: root)
      retained = drop.terminationStatus != 0 || drop.didTimeOut || drop.wasOutputTruncated
    } else {
      retained = true
    }
    return RepositoryRebaseRecoveryResult(
      branch: recovery.branch,
      restoredHeadSHA: try output(["rev-parse", "HEAD"], root: root).trimmedForPublishing,
      restoredLocalChanges: try statusPaths(root: root),
      stashWasRetained: retained
    )
  }

  private func inspect(
    profile: SiteProfile,
    root: URL,
    context: Context,
    requireRemoteTrackingMatch: Bool
  ) throws -> RepositoryRebaseSyncSnapshot {
    try requireNoOperationInProgress(context: context)
    let head = try output(["rev-parse", "--verify", "HEAD"], root: root).trimmedForPublishing
    let trackedRemote = try output(
      ["rev-parse", "--verify", "refs/remotes/origin/\(context.branch)"],
      root: root
    ).trimmedForPublishing
    let liveRemote = try liveRemoteSHA(branch: context.branch, root: root)
    guard isSHA(head), isSHA(trackedRemote), isSHA(liveRemote) else {
      throw RepositoryRebaseSyncError.invalidRepository("无法确认提交 SHA。")
    }
    guard !requireRemoteTrackingMatch || trackedRemote == liveRemote else {
      throw RepositoryRebaseSyncError.snapshotDrift
    }
    let counts = try aheadBehind(local: head, remote: trackedRemote, root: root)
    let rawStatus = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      root: root,
      preserveWhitespace: true
    )
    let statuses = try parseStatus(rawStatus)
    let unsafe = statuses.filter { !isSupported($0.status) }.flatMap {
      [$0.path, $0.sourcePath].compactMap { $0 }
    }
    guard unsafe.isEmpty else {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges(unsafe.sorted())
    }
    let changes = try statuses.map { try freezeChange($0, root: root) }.sorted {
      $0.path < $1.path
    }
    let stagedDiff = try output(
      ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--"],
      root: root,
      preserveWhitespace: true
    )
    let unstagedDiff = try output(
      ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--"],
      root: root,
      preserveWhitespace: true
    )
    let fingerprint = makeFingerprint(
      context: context,
      head: head,
      remote: trackedRemote,
      ahead: counts.ahead,
      behind: counts.behind,
      rawStatus: rawStatus,
      stagedDiff: stagedDiff,
      unstagedDiff: unstagedDiff,
      changes: changes
    )
    return RepositoryRebaseSyncSnapshot(
      repositoryRoot: root.path,
      gitCommonDirectory: context.commonDirectory,
      branch: context.branch,
      upstream: context.upstream,
      originURL: context.originURL,
      localHeadSHA: head,
      remoteHeadSHA: trackedRemote,
      aheadCount: counts.ahead,
      behindCount: counts.behind,
      rawStatusFingerprint: rawStatus,
      stagedDiffFingerprint: stagedDiff,
      unstagedDiffFingerprint: unstagedDiff,
      localChanges: changes,
      fingerprint: fingerprint
    )
  }

  private func makeRecoveryContext(
    snapshot: RepositoryRebaseSyncSnapshot,
    stashSHA: String,
    phase: RepositoryRebaseRecoveryContext.Phase
  ) -> RepositoryRebaseRecoveryContext {
    RepositoryRebaseRecoveryContext(
      repositoryRoot: snapshot.repositoryRoot,
      gitCommonDirectory: snapshot.gitCommonDirectory,
      branch: snapshot.branch,
      originalHeadSHA: snapshot.localHeadSHA,
      reviewedRemoteHeadSHA: snapshot.remoteHeadSHA,
      stashCommitSHA: stashSHA,
      phase: phase
    )
  }

  private func validateRecovery(
    _ recovery: RepositoryRebaseRecoveryContext,
    root: URL,
    context: Context
  ) throws {
    guard recovery.repositoryRoot == root.path,
      recovery.gitCommonDirectory == context.commonDirectory,
      recovery.branch == context.branch,
      isSHA(recovery.originalHeadSHA), isSHA(recovery.reviewedRemoteHeadSHA),
      isSHA(recovery.stashCommitSHA)
    else { throw RepositoryRebaseSyncError.invalidRecoveryContext("仓库根目录、共用 Git 目录、分支或 SHA 已变化。") }
    let head = try output(["rev-parse", "HEAD"], root: root).trimmedForPublishing
    switch recovery.phase {
    case .stashedBeforeRebase:
      if head != recovery.originalHeadSHA {
        let ancestor = git.run(
          ["merge-base", "--is-ancestor", recovery.reviewedRemoteHeadSHA, head],
          rootURL: root
        )
        guard ancestor.terminationStatus == 0 else {
          throw RepositoryRebaseSyncError.invalidRecoveryContext(
            "当前 HEAD 既不是原始提交，也未包含已审阅远端提交。"
          )
        }
      }
    case .rebaseConflict:
      guard head == recovery.originalHeadSHA else {
        throw RepositoryRebaseSyncError.invalidRecoveryContext("中止变基后 HEAD 未恢复到原始提交。")
      }
    case .rebaseCompleted:
      let ancestor = git.run(
        ["merge-base", "--is-ancestor", recovery.reviewedRemoteHeadSHA, head], rootURL: root)
      guard ancestor.terminationStatus == 0 else {
        throw RepositoryRebaseSyncError.invalidRecoveryContext("当前 HEAD 未包含已审阅远端提交。")
      }
    case .stashRestoreInProgress, .stashRestoreConflict, .incomplete, .completed:
      break
    }
  }

  private func recordRecovery(_ context: RepositoryRebaseRecoveryContext?) throws {
    guard let context, let recoveryRecorder else { return }
    do {
      try recoveryRecorder(context)
    } catch {
      throw RepositoryRebaseSyncError.partial(
        recovery: context,
        message: "无法持久化变基恢复记录，已停止后续 Git 操作：\(error.localizedDescription)"
      )
    }
  }

  private func createVerifiedStash(
    snapshot: RepositoryRebaseSyncSnapshot,
    root: URL
  ) throws -> String {
    let previousStash = try currentStashSHA(root: root)
    let message = "RepoPress rebase sync \(UUID().uuidString)"
    let stash = git.run(
      ["stash", "push", "--include-untracked", "--message", message],
      rootURL: root
    )
    guard stash.terminationStatus == 0, !stash.didTimeOut, !stash.wasOutputTruncated else {
      throw RepositoryRebaseSyncError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(
          ["stash", "push", "--include-untracked", "--message", message]
        ),
        output: stash.output
      )
    }
    let createdStash = try currentStashSHA(root: root)
    guard let currentStash = createdStash, currentStash != previousStash else {
      throw RepositoryRebaseSyncError.partial(
        recovery: createdStash.map {
          makeRecoveryContext(snapshot: snapshot, stashSHA: $0, phase: .incomplete)
        },
        message: "Git 未创建可验证的新 stash，未开始变基。"
      )
    }
    let stashedRecovery = makeRecoveryContext(
      snapshot: snapshot,
      stashSHA: currentStash,
      phase: .stashedBeforeRebase
    )
    try recordRecovery(stashedRecovery)
    let remainingStatus: String
    do {
      remainingStatus = try output(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        root: root,
        preserveWhitespace: true
      )
    } catch {
      let incompleteRecovery = stashedRecovery.changingPhase(to: .incomplete)
      try recordRecovery(incompleteRecovery)
      throw RepositoryRebaseSyncError.partial(
        recovery: incompleteRecovery,
        message: "stash 后无法验证工作区，未开始变基：\(error.localizedDescription)"
      )
    }
    guard remainingStatus.isEmpty else {
      let incompleteRecovery = stashedRecovery.changingPhase(to: .incomplete)
      try recordRecovery(incompleteRecovery)
      throw RepositoryRebaseSyncError.partial(
        recovery: incompleteRecovery,
        message: "stash 后工作区仍有改动，未开始变基。"
      )
    }
    return currentStash
  }

  private func freezeChange(_ raw: RawStatus, root: URL) throws
    -> RepositoryRebaseSyncChange
  {
    try validatePath(raw.path, root: root)
    if let sourcePath = raw.sourcePath { try validatePath(sourcePath, root: root) }
    let indexEntry = try indexEntry(path: raw.path, root: root)
    if indexEntry?.mode == "160000" {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([raw.path])
    }
    let worktree = try worktreeEntry(path: raw.path, root: root)
    return RepositoryRebaseSyncChange(
      status: raw.status,
      path: raw.path,
      sourcePath: raw.sourcePath,
      worktreeBlobOID: worktree?.blobOID,
      worktreeMode: worktree?.mode,
      indexBlobOID: indexEntry?.blobOID,
      indexMode: indexEntry?.mode
    )
  }

  private func worktreeEntry(path: String, root: URL) throws -> IndexEntry? {
    let url = root.appendingPathComponent(path)
    let attrs: [FileAttributeKey: Any]
    do {
      attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return nil
    } catch {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([path])
    }
    guard attrs[.type] as? FileAttributeType == .typeRegular else {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([path])
    }
    try requireNoFilters(path: path, root: root)
    let blob = try output(["hash-object", "--no-filters", "--", path], root: root)
      .trimmedForPublishing
    guard isSHA(blob) else {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([path])
    }
    let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    return IndexEntry(mode: permissions & 0o111 == 0 ? "100644" : "100755", blobOID: blob)
  }

  private func indexEntry(path: String, root: URL) throws -> IndexEntry? {
    let text = try output(
      ["ls-files", "--stage", "-z", "--", path],
      root: root,
      preserveWhitespace: true
    )
    guard let record = text.split(separator: "\0", omittingEmptySubsequences: true).first else {
      return nil
    }
    guard let tab = record.firstIndex(of: "\t") else {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([path])
    }
    let metadata = record[..<tab].split(separator: " ")
    guard metadata.count == 3,
      let mode = metadata.first.map(String.init),
      let blob = metadata.dropFirst().first.map(String.init),
      metadata.last == "0",
      isSHA(blob)
    else { throw RepositoryRebaseSyncError.unsupportedLocalChanges([path]) }
    return IndexEntry(mode: mode, blobOID: blob)
  }

  private func parseStatus(_ text: String) throws -> [RawStatus] {
    let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var records: [RawStatus] = []
    var index = 0
    while index < fields.count {
      let field = fields[index]
      guard field.count >= 3 else {
        throw RepositoryRebaseSyncError.invalidRepository("Git 状态记录不完整。")
      }
      let status = String(field.prefix(2))
      let separator = field.index(field.startIndex, offsetBy: 2)
      guard field[separator] == " " else {
        throw RepositoryRebaseSyncError.invalidRepository("Git 状态记录格式无效。")
      }
      let path = String(field[field.index(after: separator)...])
      let hasSecondPath = status.contains("R") || status.contains("C")
      var sourcePath: String?
      if hasSecondPath {
        index += 1
        guard index < fields.count else {
          throw RepositoryRebaseSyncError.invalidRepository("Git 重命名记录不完整。")
        }
        sourcePath = fields[index]
      }
      records.append(RawStatus(status: status, path: path, sourcePath: sourcePath))
      index += 1
    }
    return records
  }

  private func isSupported(_ status: String) -> Bool {
    if status == "??" { return true }
    guard status.count == 2 else { return false }
    let values = Array(status)
    return [" ", "M", "A", "D"].contains(values[0])
      && [" ", "M", "D"].contains(values[1])
      && status != "  "
  }

  private func unmergedPaths(root: URL) throws -> [String] {
    let text = try output(
      ["diff", "--name-only", "--diff-filter=U", "-z", "--"],
      root: root,
      preserveWhitespace: true
    )
    return text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init).sorted()
  }

  private func statusPaths(root: URL) throws -> [String] {
    let raw = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      root: root,
      preserveWhitespace: true
    )
    return try parseStatus(raw).map(\.path).sorted()
  }

  private func requireNoOperationInProgress(context: Context) throws {
    let common = URL(fileURLWithPath: context.commonDirectory, isDirectory: true)
    let markers: [(String, String)] = [
      ("rebase-apply", "rebase"), ("rebase-merge", "rebase"),
      ("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"),
      ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"), ("sequencer", "sequencer"),
    ]
    for (path, name) in markers
    where FileManager.default.fileExists(
      atPath: common.appendingPathComponent(path).path
    ) {
      throw RepositoryRebaseSyncError.operationInProgress(name)
    }
  }

  private func requiredRoot(_ profile: SiteProfile) throws -> URL {
    guard let root = profile.localRepositoryRootURL else {
      throw RepositoryRebaseSyncError.missingRepositoryRoot
    }
    let standard = root.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standard.path) else {
      throw RepositoryRebaseSyncError.invalidRepository("本地仓库目录不存在。")
    }
    return standard
  }

  private func validateContext(profile: SiteProfile, root: URL) throws -> Context {
    let top = try output(["rev-parse", "--show-toplevel"], root: root).trimmedForPublishing
    guard URL(fileURLWithPath: top, isDirectory: true).standardizedFileURL.path == root.path else {
      throw RepositoryRebaseSyncError.invalidRepository("配置目录不是 Git 工作树根目录。")
    }
    let commonRaw = try output(["rev-parse", "--git-common-dir"], root: root)
      .trimmedForPublishing
    let common = URL(fileURLWithPath: commonRaw, relativeTo: root).standardizedFileURL
    guard !commonRaw.isEmpty, FileManager.default.fileExists(atPath: common.path) else {
      throw RepositoryRebaseSyncError.invalidRepository("无法确认 Git 共用元数据目录。")
    }
    let branchResult = git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], rootURL: root)
    guard branchResult.terminationStatus == 0 else { throw RepositoryRebaseSyncError.detachedHead }
    let branch = branchResult.standardOutput.trimmedForPublishing
    let expectedBranch = profile.branch.trimmedForPublishing
    guard !expectedBranch.isEmpty, branch == expectedBranch else {
      throw RepositoryRebaseSyncError.branchMismatch(expected: expectedBranch, actual: branch)
    }
    let originRaw = try output(["remote", "get-url", "origin"], root: root).trimmedForPublishing
    let origin = try validatedOrigin(originRaw, profile: profile, root: root)
    let upstream = try output(
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      root: root
    ).trimmedForPublishing
    let expectedUpstream = "origin/\(branch)"
    guard upstream == expectedUpstream else {
      throw RepositoryRebaseSyncError.upstreamMismatch(expected: expectedUpstream, actual: upstream)
    }
    return Context(
      branch: branch,
      upstream: upstream,
      originURL: origin,
      commonDirectory: common.path
    )
  }

  private func limitedFetch(branch: String, root: URL) throws {
    _ = try output(
      [
        "fetch", "--no-tags", "origin",
        "refs/heads/\(branch):refs/remotes/origin/\(branch)",
      ],
      root: root
    )
  }

  private func aheadBehind(local: String, remote: String, root: URL) throws -> (
    ahead: Int, behind: Int
  ) {
    let values = try output(
      ["rev-list", "--left-right", "--count", "\(local)...\(remote)"],
      root: root
    ).split(whereSeparator: { $0.isWhitespace })
    guard values.count == 2, let ahead = Int(values[0]), let behind = Int(values[1]) else {
      throw RepositoryRebaseSyncError.invalidRepository("无法计算本地与远端的提交差异。")
    }
    return (ahead, behind)
  }

  private func liveRemoteSHA(branch: String, root: URL) throws -> String {
    let line = try output(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], root: root)
    guard let sha = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
      isSHA(sha)
    else { throw RepositoryRebaseSyncError.remoteBranchMissing(branch) }
    return sha
  }

  private func currentStashSHA(root: URL) throws -> String? {
    let result = git.run(["rev-parse", "--verify", "--quiet", "refs/stash"], rootURL: root)
    if result.terminationStatus == 1 { return nil }
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryRebaseSyncError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(
          ["rev-parse", "--verify", "--quiet", "refs/stash"]
        ),
        output: result.output
      )
    }
    let value = result.standardOutput.trimmedForPublishing
    guard isSHA(value) else {
      throw RepositoryRebaseSyncError.invalidRepository("refs/stash 不是有效提交。")
    }
    return value
  }

  private func stashCommitExists(_ sha: String, root: URL) throws -> Bool {
    guard isSHA(sha) else { return false }
    let result = git.run(["cat-file", "-e", "\(sha)^{commit}"], rootURL: root)
    if result.terminationStatus == 0 { return true }
    if result.terminationStatus == 1 { return false }
    throw RepositoryRebaseSyncError.gitFailed(
      command: GitCommandRunner.redactedCommandDescription(["cat-file", "-e", "\(sha)^{commit}"]),
      output: result.output
    )
  }

  private func requireNoFilters(path: String, root: URL) throws {
    let attributes = try output(
      ["check-attr", "-z", "filter", "working-tree-encoding", "--", path],
      root: root,
      preserveWhitespace: true
    ).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    guard attributes.count >= 6 else {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([path])
    }
    let values = stride(from: 2, to: attributes.count, by: 3).map {
      attributes[$0].lowercased()
    }
    guard values.allSatisfy({ $0 == "unspecified" || $0 == "unset" }) else {
      throw RepositoryRebaseSyncError.unsupportedLocalChanges([path])
    }
  }

  private func validatePath(_ path: String, root: URL) throws {
    let normalized = path.normalizedRelativePath()
    let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
    let resolved = root.appendingPathComponent(path).standardizedFileURL.path
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\u{FFFD}"),
      normalized == path,
      !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      !pieces.contains(where: { $0.lowercased() == ".git" }),
      resolved.hasPrefix(root.path + "/")
    else { throw RepositoryRebaseSyncError.unsupportedLocalChanges([path]) }
  }

  private func validatedOrigin(_ raw: String, profile: SiteProfile, root: URL) throws -> String {
    if let remote = GitRemoteParser.parseRepositoryRemote(raw) {
      guard remote.provider == profile.repositoryProvider,
        remote.owner.caseInsensitiveCompare(profile.repoOwner.trimmedForPublishing) == .orderedSame,
        remote.name.caseInsensitiveCompare(profile.repoName.trimmedForPublishing) == .orderedSame
      else { throw RepositoryRebaseSyncError.originMismatch(remote.displayName) }
      return remote.remoteURL
    }
    let local: URL?
    if raw.lowercased().hasPrefix("file://") {
      local = URL(string: raw)?.standardizedFileURL
    } else if raw.hasPrefix("/") || raw.hasPrefix("./") || raw.hasPrefix("../") {
      local = URL(fileURLWithPath: raw, relativeTo: root).standardizedFileURL
    } else {
      local = nil
    }
    guard let local else {
      throw RepositoryRebaseSyncError.originMismatch(
        GitCommandRunner.redactedDiagnosticText(raw)
      )
    }
    let expectedName = profile.repoName.trimmedForPublishing
    let expectedOwner =
      profile.repoOwner.trimmedForPublishing
      .split(separator: "/").last.map(String.init) ?? ""
    guard !expectedName.isEmpty,
      local.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(expectedName)
        == .orderedSame,
      expectedOwner.isEmpty
        || local.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(expectedOwner)
          == .orderedSame
    else { throw RepositoryRebaseSyncError.originMismatch(local.path) }
    return local.path
  }

  private func makeFingerprint(
    context: Context,
    head: String,
    remote: String,
    ahead: Int,
    behind: Int,
    rawStatus: String,
    stagedDiff: String,
    unstagedDiff: String,
    changes: [RepositoryRebaseSyncChange]
  ) -> String {
    let pieces = [
      context.commonDirectory, context.branch, context.upstream, context.originURL,
      head, remote, String(ahead), String(behind), rawStatus, stagedDiff, unstagedDiff,
      changes.map(\.id).joined(separator: "\u{1E}"),
    ]
    return Data(pieces.joined(separator: "\u{1D}").utf8).base64EncodedString()
  }

  private func isSHA(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { $0.isHexDigit }
  }

  private func diagnostic(for result: GitCommandResult, arguments: [String]) -> String {
    var message = result.output.trimmedForPublishing
    if result.didTimeOut { message = "Git 命令超时。 " + message }
    if result.wasOutputTruncated { message = "Git 输出超过安全上限。 " + message }
    return "\(GitCommandRunner.redactedCommandDescription(arguments)): \(message)"
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
      throw RepositoryRebaseSyncError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(arguments),
        output: result.output
      )
    }
    return result.standardOutput
  }
}
