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

  let git: GitCommandRunner
  private let safetyAnalyzer: RepositoryPublishSafetyAnalyzer
  private let sitePreflightService: RepositoryPublishPreflightService
  private let testingAfterCompareAndSwap: (@Sendable () -> Void)?

  private var executionPolicyService: RepositoryGitExecutionPolicyService {
    RepositoryGitExecutionPolicyService(gitCommandRunner: git)
  }

  private var transitionCoordinator: RepositoryWorktreePublishTransitionCoordinator {
    RepositoryWorktreePublishTransitionCoordinator(gitCommandRunner: git)
  }

  public init(
    gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 120),
    safetyAnalyzer: RepositoryPublishSafetyAnalyzer = RepositoryPublishSafetyAnalyzer(),
    sitePreflightService: RepositoryPublishPreflightService = RepositoryPublishPreflightService()
  ) {
    git = gitCommandRunner
    self.safetyAnalyzer = safetyAnalyzer
    self.sitePreflightService = sitePreflightService
    testingAfterCompareAndSwap = nil
  }

  init(
    gitCommandRunner: GitCommandRunner,
    safetyAnalyzer: RepositoryPublishSafetyAnalyzer = RepositoryPublishSafetyAnalyzer(),
    sitePreflightService: RepositoryPublishPreflightService = RepositoryPublishPreflightService(),
    testingAfterCompareAndSwap: @escaping @Sendable () -> Void
  ) {
    git = gitCommandRunner
    self.safetyAnalyzer = safetyAnalyzer
    self.sitePreflightService = sitePreflightService
    self.testingAfterCompareAndSwap = testingAfterCompareAndSwap
  }

  /// Performs no new publication mutation. If a previous process stopped in
  /// the short HEAD/index transition, its app-owned journal is recovered
  /// before a new frozen review is produced.
  ///
  /// A `pathScope` limits the review, commit and drift checks to those exact
  /// repository paths; every other worktree change stays uncommitted and
  /// untouched. The real index must still be clean repository-wide because the
  /// committed tree replaces it after the branch moves.
  public func prepare(
    profile: SiteProfile,
    commitMessage: String,
    articleDraft: ArticleDraft? = nil,
    pathScope: [String]? = nil
  ) throws -> RepositoryWorktreePublishConfirmation {
    let normalizedMessage = commitMessage.trimmedForPublishing
    guard !normalizedMessage.isEmpty else {
      throw RepositoryWorktreePublishError.invalidCommitMessage
    }
    guard let root = profile.localRepositoryRootURL else {
      throw RepositoryWorktreePublishError.missingRepositoryRoot
    }
    let scope = try normalizedPathScope(pathScope, root: root.standardizedFileURL)
    try executionPolicyService.validate(policy: profile.gitExecutionPolicy, rootURL: root)
    try transitionCoordinator.recoverIfNeeded(profile: profile, root: root)
    let snapshot = try inspect(profile: profile, root: root, pathScope: scope)
    let safetyReport = try validatedSafetyReport(snapshot: snapshot, profile: profile)
    let sitePreflightResult = try validatedSitePreflight(
      profile: profile, snapshot: snapshot, pathScope: scope)
    let fileReviews = RepositoryWorktreeReviewService(git: git).capture(
      entries: snapshot.entries, root: root, baseRevision: snapshot.headSHA
    )
    let articleTarget = RepositoryWorktreeArticleVerificationTarget.capture(
      draft: articleDraft, profile: profile, snapshot: snapshot
    )
    let afterPreflight = try inspect(profile: profile, root: root, pathScope: scope)
    guard afterPreflight == snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    return RepositoryWorktreePublishConfirmation(
      snapshot: snapshot,
      commitMessage: normalizedMessage,
      safetyReport: safetyReport,
      sitePreflightResult: sitePreflightResult,
      articleVerificationTarget: articleTarget,
      fileReviews: fileReviews,
      executionPolicy: profile.gitExecutionPolicy,
      pathScope: scope
    )
  }

  /// Revalidates the complete frozen review, stages all reviewed paths,
  /// verifies the resulting index, commits, and pushes one exact non-force
  /// refspec.
  public func publish(
    profile: SiteProfile,
    confirmation: RepositoryWorktreePublishConfirmation,
    beforeMovingHead: (@Sendable (String) throws -> Void)? = nil
  ) throws -> RepositoryWorktreePublishResult {
    guard profile.gitExecutionPolicy == confirmation.executionPolicy else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    guard
      RepositoryWorktreeFileReview.isComplete(
        entries: confirmation.snapshot.entries, reviews: confirmation.fileReviews
      )
        && (confirmation.snapshot.outgoingHistory?.isHistoryReviewComplete ?? true)
    else { throw RepositoryWorktreePublishError.incompleteReview }
    guard let root = profile.localRepositoryRootURL else {
      throw RepositoryWorktreePublishError.missingRepositoryRoot
    }
    let scope = confirmation.pathScope
    guard try normalizedPathScope(scope, root: root.standardizedFileURL) == scope else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    try transitionCoordinator.recoverIfNeeded(profile: profile, root: root)
    guard !confirmation.commitMessage.trimmedForPublishing.isEmpty else {
      throw RepositoryWorktreePublishError.invalidCommitMessage
    }
    let current = try inspect(profile: profile, root: root, pathScope: scope)
    guard current == confirmation.snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let currentSafetyReport = try validatedSafetyReport(snapshot: current, profile: profile)
    guard currentSafetyReport == confirmation.safetyReport else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let sitePreflightResult = try validatedSitePreflight(
      profile: profile, snapshot: current, pathScope: scope)
    guard confirmation.sitePreflightResult != nil else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    guard sitePreflightResult.outcome == confirmation.sitePreflightResult?.outcome else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    let afterPreflight = try inspect(profile: profile, root: root, pathScope: scope)
    guard afterPreflight == confirmation.snapshot else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPress-WorktreeIndex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    if current.entries.isEmpty {
      guard current.outgoingHistory != nil else { throw RepositoryWorktreePublishError.noChanges }
      try beforeMovingHead?(current.headSHA)
      return try pushReviewedCommit(
        profile: profile, confirmation: confirmation, commitSHA: current.headSHA,
        root: root, temporaryDirectory: temporaryDirectory, createdCommit: false)
    }
    let temporaryIndex = temporaryDirectory.appendingPathComponent("index")
    let realIndexFingerprint = try indexFingerprint(root: root)

    _ = try output(
      ["read-tree", confirmation.snapshot.headSHA], root: root, indexURL: temporaryIndex)
    // A scoped publish stages only the reviewed paths that actually changed;
    // a pathspec naming an absent, untracked file would make `git add` fail.
    _ = try output(
      ["add", "-A", "--"] + pathspecs(for: scope.map { _ in confirmation.snapshot.paths }),
      root: root, indexURL: temporaryIndex)
    // Paths outside a scope stay uncommitted; hooks must still leave them alone.
    let repositoryStatusBeforeHooks = try repositoryStatus(root: root)
    guard try stagedIndexMatches(confirmation.snapshot, root: root, indexURL: temporaryIndex),
      try worktreeHasNoChangesBeyondIndex(root: root, indexURL: temporaryIndex, pathScope: scope)
    else {
      throw RepositoryWorktreePublishError.stagedVerificationFailed
    }
    let stagedTree = try output(["write-tree"], root: root, indexURL: temporaryIndex)
      .trimmedForPublishing
    guard !stagedTree.isEmpty else {
      throw RepositoryWorktreePublishError.stagedVerificationFailed
    }
    let execution = RepositoryWorktreeGitExecutionPolicyService(git: git)
    let commitSHA = try execution.commit(
      confirmation: confirmation, tree: stagedTree, root: root, index: temporaryIndex,
      temporaryDirectory: temporaryDirectory
    ) {
      guard try inspect(profile: profile, root: root, pathScope: scope) == confirmation.snapshot,
        try indexFingerprint(root: root) == realIndexFingerprint,
        try stagedIndexMatches(confirmation.snapshot, root: root, indexURL: temporaryIndex),
        try worktreeHasNoChangesBeyondIndex(root: root, indexURL: temporaryIndex, pathScope: scope),
        try repositoryStatus(root: root) == repositoryStatusBeforeHooks,
        try output(["write-tree"], root: root, indexURL: temporaryIndex).trimmedForPublishing
          == stagedTree
      else { throw RepositoryGitExecutionPolicyError.reviewedContentChanged }
    }
    guard !commitSHA.isEmpty else {
      throw RepositoryWorktreePublishError.stagedVerificationFailed
    }

    // The real index is never used to build the tree. Recheck it immediately
    // before moving the branch so a concurrent `git add` cannot be absorbed.
    let beforeCAS = try inspect(profile: profile, root: root, pathScope: scope)
    guard beforeCAS == confirmation.snapshot,
      try indexFingerprint(root: root) == realIndexFingerprint
    else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }

    // Persist the immutable receipt before the first durable ref mutation.
    // A failed receipt write prevents both the ref update and network push.
    try beforeMovingHead?(commitSHA)

    let realIndexURL = try repositoryIndexURL(root: root)
    let transition = try transitionCoordinator.begin(
      root: root,
      branch: confirmation.snapshot.branch,
      previousHeadSHA: confirmation.snapshot.headSHA,
      commitSHA: commitSHA,
      previousIndexFingerprint: realIndexFingerprint,
      indexURL: realIndexURL
    )
    var indexLock: RepositoryWorktreePublishOwnedIndexLock?

    var didMoveHead = false
    var didInstallIndex = false
    do {
      indexLock = try transitionCoordinator.acquireIndexLock(for: transition)
      guard try indexFingerprint(root: root) == realIndexFingerprint else {
        throw RepositoryWorktreePublishError.snapshotDrift
      }
      _ = try output(
        [
          "update-ref", "refs/heads/\(confirmation.snapshot.branch)", commitSHA,
          confirmation.snapshot.headSHA,
        ],
        root: root
      )
      didMoveHead = true
      testingAfterCompareAndSwap?()

      let commitTree = try output(["rev-parse", "\(commitSHA)^{tree}"], root: root)
        .trimmedForPublishing
      guard commitTree == stagedTree else {
        throw RepositoryWorktreePublishError.stagedVerificationFailed
      }
      // Standard Git writers respect index.lock. Rechecking while holding it
      // additionally detects a non-cooperating writer that changed index
      // bytes directly.
      guard try indexFingerprint(root: root) == realIndexFingerprint else {
        throw RepositoryWorktreePublishError.snapshotDrift
      }

      guard let indexLock else {
        throw RepositoryWorktreePublishError.stagedVerificationFailed
      }
      try transitionCoordinator.installIndex(from: temporaryIndex, using: indexLock)
      didInstallIndex = true
      try transitionCoordinator.finish(transition)
    } catch {
      if didMoveHead, !didInstallIndex {
        if transitionCoordinator.rollbackAfterHeadMove(
          indexLock,
          transition: transition,
          root: root
        ) {
          throw error
        }
      }
      if didMoveHead {
        throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
          commitSHA: commitSHA,
          message: "\(error.localizedDescription)；已保留恢复记录，下次操作会继续安全恢复。"
        )
      }
      transitionCoordinator.cancelBeforeHeadMove(indexLock, transition: transition)
      throw error
    }

    return try pushReviewedCommit(
      profile: profile, confirmation: confirmation, commitSHA: commitSHA,
      root: root, temporaryDirectory: temporaryDirectory, createdCommit: true)
  }

  private func validatedSafetyReport(
    snapshot: RepositoryWorktreePublishSnapshot,
    profile: SiteProfile
  ) throws -> RepositoryPublishSafetyReport {
    let local = try RepositoryDraftSourceReview.validatedReport(
      snapshot: snapshot, profile: profile, analyzer: safetyAnalyzer)
    let history = try RepositoryOutgoingPublicationReview.diagnostics(
      snapshot: snapshot, profile: profile, git: git, analyzer: safetyAnalyzer)
    return RepositoryPublishSafetyReport(diagnostics: local.diagnostics + history)
  }

  private func validatedSitePreflight(
    profile: SiteProfile, snapshot: RepositoryWorktreePublishSnapshot, pathScope: [String]?
  ) throws -> RepositoryPublishPreflightResult {
    try RepositoryScopedPreflight.validatedResult(
      profile: profile, snapshot: snapshot, pathScope: pathScope,
      git: git, service: sitePreflightService)
  }

  private func inspect(
    profile: SiteProfile,
    root: URL,
    pathScope: [String]?
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
    let safePushOrigin = try validatedPushOrigin(
      profile: profile,
      root: standardizedRoot
    )

    let head = try output(["rev-parse", "--verify", "HEAD"], root: standardizedRoot)
      .trimmedForPublishing
    guard !head.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository("仓库还没有可发布的提交。")
    }
    let remoteSHA = try requiredRemoteSHA(branch: branch, root: standardizedRoot)
    let outgoingHistory: RepositoryWorktreePushRetrySnapshot?
    if remoteSHA.caseInsensitiveCompare(head) == .orderedSame {
      outgoingHistory = nil
    } else {
      let history = try RepositoryWorktreePushRetryService(gitCommandRunner: git).inspect(
        profile: profile)
      guard history.localHeadSHA == head, history.remoteBranchSHA == remoteSHA else {
        throw RepositoryWorktreePublishError.snapshotDrift
      }
      outgoingHistory = history
    }

    let status = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      root: standardizedRoot
    )
    let repositoryEntries = try parseStatus(status)
    guard !repositoryEntries.isEmpty || outgoingHistory != nil else {
      throw RepositoryWorktreePublishError.noChanges
    }

    // Unmerged and staged paths block every scope: the committed tree later
    // replaces the real index, so it must equal HEAD repository-wide.
    let unmerged =
      repositoryEntries
      .filter { isUnmerged(status: $0.status) }
      .flatMap { [$0.path, $0.sourcePath].compactMap { $0 } }
      .sorted()
    guard unmerged.isEmpty else {
      throw RepositoryWorktreePublishError.unmergedPaths(unmerged)
    }

    let staged =
      repositoryEntries
      .filter { isStaged(status: $0.status) }
      .flatMap { [$0.path, $0.sourcePath].compactMap { $0 } }
      .sorted()
    guard staged.isEmpty else {
      throw RepositoryWorktreePublishError.dirtyIndex(staged)
    }

    let rawEntries: [RawStatusEntry]
    let statusFingerprint: String
    if let pathScope {
      let scopedPaths = Set(pathScope)
      rawEntries = repositoryEntries.filter { scopedPaths.contains($0.path) }
      // Unrelated edits elsewhere in the worktree must not invalidate a
      // scoped review, so only the scoped records form the fingerprint.
      statusFingerprint = rawEntries.map { "\($0.status) \($0.path)\0" }.joined()
    } else {
      rawEntries = repositoryEntries
      statusFingerprint = status
    }
    guard !rawEntries.isEmpty || outgoingHistory != nil else {
      throw RepositoryWorktreePublishError.noChanges
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
      pushOriginURL: safePushOrigin,
      remoteBranchSHA: remoteSHA,
      statusFingerprint: statusFingerprint,
      entries: entries,
      outgoingHistory: outgoingHistory
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
    root: URL,
    indexURL: URL
  ) throws -> Bool {
    let stagedPathOutput = try output(
      ["diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--"],
      root: root,
      indexURL: indexURL
    )
    let stagedPaths = Set(
      stagedPathOutput.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    )
    guard stagedPaths == Set(snapshot.paths) else { return false }

    for entry in snapshot.entries {
      let stageOutput = try output(
        ["ls-files", "--stage", "-z", "--", entry.path],
        root: root,
        indexURL: indexURL
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
          root: root,
          indexURL: indexURL
        )
        guard sourceStage.isEmpty else { return false }
      }
    }
    return true
  }

  private func worktreeHasNoChangesBeyondIndex(
    root: URL, indexURL: URL, pathScope: [String]?
  ) throws -> Bool {
    let diffArguments = ["diff", "--quiet", "--"] + pathspecs(for: pathScope)
    let diff = git.run(
      diffArguments,
      rootURL: root,
      environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
    )
    guard diff.terminationStatus == 0 || diff.terminationStatus == 1 else {
      throw gitFailure(arguments: diffArguments, result: diff)
    }
    guard diff.terminationStatus == 0 else { return false }
    let untracked = try output(
      ["ls-files", "--others", "--exclude-standard", "-z", "--"] + pathspecs(for: pathScope),
      root: root,
      indexURL: indexURL
    )
    return untracked.isEmpty
  }

  private func indexFingerprint(root: URL) throws -> String {
    try output(["ls-files", "--stage", "-z"], root: root)
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

  func validatedPushOrigin(profile: SiteProfile, root: URL) throws -> String {
    let raw = try output(
      ["remote", "get-url", "--push", "--all", "origin"],
      root: root
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

  func requiredRemoteSHA(branch: String, root: URL) throws -> String {
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

  func validateRelativePath(_ path: String, root: URL) throws {
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
}
