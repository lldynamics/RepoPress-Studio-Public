import Foundation
import PublishingGitCore

/// A deliberately narrow synchronizer for an behind-only branch. It never
/// stages, stashes, resets, cleans, commits, pushes, or force-fetches.
public struct RepositorySafeSyncService: Sendable {
  private struct RawStatus: Sendable {
    let status: String
    let path: String
    let sourcePath: String?
  }

  private struct RemoteTreeEntry: Sendable {
    let mode: String
    let blobOID: String
    let path: String
  }

  private struct RecoveryManifest: Codable {
    struct Entry: Codable {
      let path: String
      let blobOID: String
      let mode: String
      let backupRelativePath: String
    }

    let version: Int
    let repositoryRoot: String
    let previousHeadSHA: String
    let targetHeadSHA: String
    let entries: [Entry]
  }

  private let git: GitCommandRunner

  public init(gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 120)) {
    git = gitCommandRunner
  }

  /// Fetches only the configured branch into its ordinary remote-tracking ref.
  /// It does not alter HEAD, the index, local branches, or working files.
  public func prepare(profile: SiteProfile) throws -> RepositorySafeSyncPreparation {
    let root = try requiredRoot(profile)
    let context = try validateContext(profile: profile, root: root)
    try limitedFetch(branch: context.branch, root: root)
    let snapshot = try inspect(profile: profile, root: root, context: context)
    if snapshot.localHeadSHA == snapshot.remoteHeadSHA {
      return .alreadySynchronized(branch: snapshot.branch, headSHA: snapshot.localHeadSHA)
    }
    return .confirmation(RepositorySafeSyncConfirmation(snapshot: snapshot))
  }

  /// Revalidates the full review, copy-backs only proven identical untracked
  /// collisions, and fast-forwards to the exact SHA seen during review.
  public func apply(
    profile: SiteProfile,
    confirmation: RepositorySafeSyncConfirmation,
    recoveryRootURL: URL
  ) throws -> RepositorySafeSyncResult {
    let root = try requiredRoot(profile)
    let context = try validateContext(profile: profile, root: root)
    let current = try inspectWithoutFetch(profile: profile, root: root, context: context)
    guard current == confirmation.snapshot else { throw RepositorySafeSyncError.snapshotDrift }

    let liveRemote = try liveRemoteSHA(branch: context.branch, root: root)
    guard liveRemote == confirmation.snapshot.remoteHeadSHA else {
      throw RepositorySafeSyncError.snapshotDrift
    }
    guard
      try output(["rev-parse", "refs/remotes/origin/\(context.branch)"], root: root)
        .trimmedForPublishing == confirmation.snapshot.remoteHeadSHA
    else { throw RepositorySafeSyncError.snapshotDrift }

    let archive =
      try confirmation.snapshot.identicalUntrackedCollisions.isEmpty
      ? nil
      : makeRecoveryArchive(
        root: root,
        recoveryRootURL: recoveryRootURL,
        snapshot: confirmation.snapshot
      )
    var removedPaths: [String] = []
    var didFastForward = false
    do {
      for collision in confirmation.snapshot.identicalUntrackedCollisions {
        let url = root.appendingPathComponent(collision.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw RepositorySafeSyncError.snapshotDrift
        }
        try FileManager.default.removeItem(at: url)
        removedPaths.append(collision.path)
      }
      _ = try output(["merge", "--ff-only", confirmation.snapshot.remoteHeadSHA], root: root)
      didFastForward = true
      try verifyApplied(snapshot: confirmation.snapshot, root: root)
      let remoteAdvancedAgain =
        try liveRemoteSHA(branch: confirmation.snapshot.branch, root: root)
        != confirmation.snapshot.remoteHeadSHA
      return RepositorySafeSyncResult(
        previousHeadSHA: confirmation.snapshot.localHeadSHA,
        synchronizedHeadSHA: confirmation.snapshot.remoteHeadSHA,
        branch: confirmation.snapshot.branch,
        preservedLocalPaths: confirmation.snapshot.localChanges.map(\.path)
          .filter { !removedPaths.contains($0) }.sorted(),
        reconciledCollisionPaths: removedPaths.sorted(),
        remoteAdvancedAgain: remoteAdvancedAgain,
        recoveryArchiveURL: archive
      )
    } catch {
      let reachedTarget: Bool
      if didFastForward {
        reachedTarget = true
      } else {
        do {
          reachedTarget =
            try output(["rev-parse", "HEAD"], root: root).trimmedForPublishing
            == confirmation.snapshot.remoteHeadSHA
        } catch {
          reachedTarget = false
        }
      }
      if reachedTarget {
        throw RepositorySafeSyncError.partial(
          recoveryDirectory: archive?.path ?? "",
          message:
            "已快进到 \(confirmation.snapshot.remoteHeadSHA.prefix(8))，但后置验证失败：\(error.localizedDescription)"
        )
      }
      guard let archive else { throw error }
      let originalMessage = error.localizedDescription
      let restoration: [String]
      do {
        restoration = try restoreMissingPaths(
          archive: archive,
          root: root,
          expected: confirmation.snapshot.identicalUntrackedCollisions
        )
      } catch let recoveryError as RepositorySafeSyncError {
        throw RepositorySafeSyncError.partial(
          recoveryDirectory: archive.path,
          message: "\(originalMessage)；恢复备份失败：\(recoveryError.localizedDescription)"
        )
      } catch {
        throw RepositorySafeSyncError.partial(
          recoveryDirectory: archive.path,
          message: "\(originalMessage)；恢复备份失败：\(error.localizedDescription)"
        )
      }
      let message = originalMessage
      if restoration.isEmpty {
        throw RepositorySafeSyncError.recoveryRequired(
          recoveryDirectory: archive.path,
          message: message
        )
      }
      throw RepositorySafeSyncError.partial(
        recoveryDirectory: archive.path,
        message: "\(message)；以下路径未自动恢复以免覆盖不同内容：\(restoration.joined(separator: "、"))"
      )
    }
  }

  private func inspect(
    profile: SiteProfile,
    root: URL,
    context: Context
  ) throws -> RepositorySafeSyncSnapshot {
    try inspectSnapshot(
      profile: profile, root: root, context: context, requireRemoteTrackingMatch: true)
  }

  private func inspectWithoutFetch(
    profile: SiteProfile,
    root: URL,
    context: Context
  ) throws -> RepositorySafeSyncSnapshot {
    try inspectSnapshot(
      profile: profile, root: root, context: context, requireRemoteTrackingMatch: false)
  }

  private func inspectSnapshot(
    profile: SiteProfile,
    root: URL,
    context: Context,
    requireRemoteTrackingMatch: Bool
  ) throws -> RepositorySafeSyncSnapshot {
    let head = try output(["rev-parse", "--verify", "HEAD"], root: root).trimmedForPublishing
    let trackedRemote = try output(
      ["rev-parse", "--verify", "refs/remotes/origin/\(context.branch)"], root: root
    ).trimmedForPublishing
    let liveRemote = try liveRemoteSHA(branch: context.branch, root: root)
    guard isSHA(head), isSHA(trackedRemote), isSHA(liveRemote) else {
      throw RepositorySafeSyncError.invalidRepository("无法确认提交 SHA。")
    }
    guard !requireRemoteTrackingMatch || trackedRemote == liveRemote else {
      throw RepositorySafeSyncError.snapshotDrift
    }
    let counts = try aheadBehind(local: head, remote: trackedRemote, root: root)
    if head == trackedRemote {
      return try synchronizedSnapshot(context: context, head: head, root: root)
    }
    guard counts.ahead == 0, counts.behind > 0 else {
      throw RepositorySafeSyncError.notBehind(ahead: counts.ahead, behind: counts.behind)
    }

    let rawStatus = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"], root: root
    )
    let statuses = try parseStatus(rawStatus)
    let unmerged = statuses.filter { isUnmerged($0.status) }.flatMap {
      [$0.path, $0.sourcePath].compactMap { $0 }
    }
    guard unmerged.isEmpty else { throw RepositorySafeSyncError.unmergedPaths(unmerged.sorted()) }
    let staged = statuses.filter { isStaged($0.status) }.flatMap {
      [$0.path, $0.sourcePath].compactMap { $0 }
    }
    guard staged.isEmpty else { throw RepositorySafeSyncError.stagedChanges(staged.sorted()) }
    let localChanges = try statuses.map { try freezeLocalChange($0, root: root) }.sorted {
      $0.path < $1.path
    }

    let rawRemoteDiff = try output(
      ["diff", "--name-status", "--no-renames", "-z", "\(head)..\(trackedRemote)"], root: root
    )
    let remoteChanges = try parseRemoteChanges(rawRemoteDiff, root: root).sorted {
      $0.path < $1.path
    }
    try validateRemoteTreeEntries(remoteChanges, remoteSHA: trackedRemote, root: root)
    let collisions = try validateOverlaps(
      local: localChanges,
      remote: remoteChanges,
      remoteSHA: trackedRemote,
      root: root
    )
    let fingerprint = makeFingerprint(
      context: context,
      head: head,
      remote: trackedRemote,
      behind: counts.behind,
      status: rawStatus,
      remoteDiff: rawRemoteDiff,
      local: localChanges,
      remoteChanges: remoteChanges,
      collisions: collisions
    )
    return RepositorySafeSyncSnapshot(
      repositoryRoot: root.path,
      gitCommonDirectory: context.commonDirectory,
      branch: context.branch,
      upstream: context.upstream,
      originURL: context.originURL,
      localHeadSHA: head,
      remoteHeadSHA: trackedRemote,
      behindCount: counts.behind,
      rawStatusFingerprint: rawStatus,
      remoteDiffFingerprint: rawRemoteDiff,
      localChanges: localChanges,
      remoteChanges: remoteChanges,
      identicalUntrackedCollisions: collisions,
      fingerprint: fingerprint
    )
  }

  private func synchronizedSnapshot(
    context: Context,
    head: String,
    root: URL
  ) throws -> RepositorySafeSyncSnapshot {
    RepositorySafeSyncSnapshot(
      repositoryRoot: root.path,
      gitCommonDirectory: context.commonDirectory,
      branch: context.branch,
      upstream: context.upstream,
      originURL: context.originURL,
      localHeadSHA: head,
      remoteHeadSHA: head,
      behindCount: 0,
      rawStatusFingerprint: "",
      remoteDiffFingerprint: "",
      localChanges: [],
      remoteChanges: [],
      identicalUntrackedCollisions: [],
      fingerprint: "synchronized:\(head)"
    )
  }

  private struct Context: Sendable {
    let branch: String
    let upstream: String
    let originURL: String
    let commonDirectory: String
  }

  private func requiredRoot(_ profile: SiteProfile) throws -> URL {
    guard let root = profile.localRepositoryRootURL else {
      throw RepositorySafeSyncError.missingRepositoryRoot
    }
    let standard = root.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standard.path) else {
      throw RepositorySafeSyncError.invalidRepository("本地仓库目录不存在。")
    }
    return standard
  }

  private func validateContext(profile: SiteProfile, root: URL) throws -> Context {
    let top = try output(["rev-parse", "--show-toplevel"], root: root).trimmedForPublishing
    guard URL(fileURLWithPath: top, isDirectory: true).standardizedFileURL.path == root.path else {
      throw RepositorySafeSyncError.invalidRepository("配置目录不是 Git 工作树根目录。")
    }
    let commonRaw = try output(["rev-parse", "--git-common-dir"], root: root).trimmedForPublishing
    let common = URL(fileURLWithPath: commonRaw, relativeTo: root).standardizedFileURL
    guard !commonRaw.isEmpty, FileManager.default.fileExists(atPath: common.path) else {
      throw RepositorySafeSyncError.invalidRepository("无法确认 Git 共用元数据目录。")
    }
    let branchResult = git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], rootURL: root)
    guard branchResult.terminationStatus == 0 else { throw RepositorySafeSyncError.detachedHead }
    let branch = branchResult.standardOutput.trimmedForPublishing
    let expectedBranch = profile.branch.trimmedForPublishing
    guard !expectedBranch.isEmpty, branch == expectedBranch else {
      throw RepositorySafeSyncError.branchMismatch(expected: expectedBranch, actual: branch)
    }
    let originRaw = try output(["remote", "get-url", "origin"], root: root).trimmedForPublishing
    let origin = try validatedOrigin(originRaw, profile: profile, root: root)
    let upstream = try output(
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], root: root
    ).trimmedForPublishing
    let expectedUpstream = "origin/\(branch)"
    guard upstream == expectedUpstream else {
      throw RepositorySafeSyncError.upstreamMismatch(expected: expectedUpstream, actual: upstream)
    }
    return Context(
      branch: branch, upstream: upstream, originURL: origin, commonDirectory: common.path)
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
      ["rev-list", "--left-right", "--count", "\(local)...\(remote)"], root: root
    )
    .split(whereSeparator: { $0.isWhitespace })
    guard values.count == 2, let ahead = Int(values[0]), let behind = Int(values[1]) else {
      throw RepositorySafeSyncError.invalidRepository("无法计算本地与远端的提交差异。")
    }
    return (ahead, behind)
  }

  private func liveRemoteSHA(branch: String, root: URL) throws -> String {
    let line = try output(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], root: root)
    guard let sha = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
      isSHA(sha)
    else {
      throw RepositorySafeSyncError.remoteBranchMissing(branch)
    }
    return sha
  }

  private func freezeLocalChange(_ raw: RawStatus, root: URL) throws -> RepositorySafeSyncChange {
    try validatePath(raw.path, root: root)
    if let source = raw.sourcePath { try validatePath(source, root: root) }
    let deletion = raw.status.contains("D")
    let url = root.appendingPathComponent(raw.path)
    if deletion && !FileManager.default.fileExists(atPath: url.path) {
      return RepositorySafeSyncChange(
        status: raw.status, path: raw.path, sourcePath: raw.sourcePath, isDeletion: true)
    }
    guard raw.status == "??" || raw.status == " M" || raw.status == " D" else {
      throw RepositorySafeSyncError.unsafeLocalChanges([raw.path])
    }
    let attributes = try regularFileAttributes(url, path: raw.path)
    try requireNoFilters(path: raw.path, root: root)
    let blob = try output(
      ["hash-object", "--no-filters", "--", raw.path], root: root
    )
    .trimmedForPublishing
    guard isSHA(blob) else { throw RepositorySafeSyncError.unsafeLocalChanges([raw.path]) }
    return RepositorySafeSyncChange(
      status: raw.status,
      path: raw.path,
      sourcePath: raw.sourcePath,
      blobOID: blob,
      mode: attributes.mode,
      isDeletion: false
    )
  }

  private func parseRemoteChanges(_ text: String, root: URL) throws -> [RepositorySafeSyncChange] {
    let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    guard fields.count.isMultiple(of: 2) else {
      throw RepositorySafeSyncError.invalidRepository("远端差异记录格式无效。")
    }
    return try stride(from: 0, to: fields.count, by: 2).map { index in
      let status = fields[index]
      let path = fields[index + 1]
      try validatePath(path, root: root)
      return RepositorySafeSyncChange(status: status, path: path, isDeletion: status == "D")
    }
  }

  private func validateOverlaps(
    local: [RepositorySafeSyncChange],
    remote: [RepositorySafeSyncChange],
    remoteSHA: String,
    root: URL
  ) throws -> [RepositorySafeSyncCollision] {
    var collisions: [RepositorySafeSyncCollision] = []
    for localChange in local {
      for remoteChange in remote where pathsOverlap(localChange.path, remoteChange.path) {
        guard localChange.path == remoteChange.path,
          localChange.status == "??",
          remoteChange.status == "A",
          !localChange.isDeletion,
          let localBlob = localChange.blobOID,
          let localMode = localChange.mode
        else {
          throw RepositorySafeSyncError.unsafeRemoteChanges(
            [localChange.path, remoteChange.path].sorted())
        }
        let remoteEntry = try remoteTreeEntry(path: remoteChange.path, sha: remoteSHA, root: root)
        guard remoteEntry.mode == localMode, remoteEntry.blobOID == localBlob else {
          throw RepositorySafeSyncError.collisionMismatch([localChange.path])
        }
        collisions.append(
          RepositorySafeSyncCollision(
            path: localChange.path,
            localBlobOID: localBlob,
            remoteBlobOID: remoteEntry.blobOID,
            mode: localMode
          )
        )
      }
    }
    return Array(Set(collisions)).sorted { $0.path < $1.path }
  }

  private func remoteTreeEntry(path: String, sha: String, root: URL) throws -> RemoteTreeEntry {
    let text = try output(["ls-tree", "-z", sha, "--", path], root: root)
    guard let record = text.split(separator: "\0", omittingEmptySubsequences: true).first,
      let tab = record.firstIndex(of: "\t")
    else { throw RepositorySafeSyncError.unsafeRemoteChanges([path]) }
    let metadata = record[..<tab].split(separator: " ")
    guard metadata.count == 3,
      let mode = metadata.first.map(String.init),
      ["100644", "100755"].contains(mode),
      let blob = metadata.dropFirst(2).first.map(String.init), isSHA(blob),
      String(record[record.index(after: tab)...]) == path
    else { throw RepositorySafeSyncError.unsafeRemoteChanges([path]) }
    return RemoteTreeEntry(mode: mode, blobOID: blob, path: path)
  }

  private func validateRemoteTreeEntries(
    _ changes: [RepositorySafeSyncChange],
    remoteSHA: String,
    root: URL
  ) throws {
    for change in changes where !change.isDeletion {
      _ = try remoteTreeEntry(path: change.path, sha: remoteSHA, root: root)
    }
  }

  private func verifyApplied(snapshot: RepositorySafeSyncSnapshot, root: URL) throws {
    let head = try output(["rev-parse", "HEAD"], root: root).trimmedForPublishing
    guard head == snapshot.remoteHeadSHA else { throw RepositorySafeSyncError.snapshotDrift }
    let upstream = try output(
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], root: root
    ).trimmedForPublishing
    guard upstream == snapshot.upstream else { throw RepositorySafeSyncError.snapshotDrift }
    let index = git.run(["diff", "--cached", "--quiet", "--"], rootURL: root)
    guard index.terminationStatus == 0 else { throw RepositorySafeSyncError.snapshotDrift }
    let unmerged = try output(["ls-files", "-u", "-z"], root: root)
    guard unmerged.isEmpty else { throw RepositorySafeSyncError.snapshotDrift }
    let currentRaw = try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"], root: root
    )
    let current = try parseStatus(currentRaw)
    let expected = snapshot.localChanges.filter { local in
      !snapshot.identicalUntrackedCollisions.contains(where: { $0.path == local.path })
    }
    let frozenCurrent = try current.map { try freezeLocalChange($0, root: root) }.sorted {
      $0.path < $1.path
    }
    guard frozenCurrent == expected.sorted(by: { $0.path < $1.path }) else {
      throw RepositorySafeSyncError.snapshotDrift
    }
    for collision in snapshot.identicalUntrackedCollisions {
      let entry = try remoteTreeEntry(path: collision.path, sha: head, root: root)
      guard entry.blobOID == collision.remoteBlobOID, entry.mode == collision.mode else {
        throw RepositorySafeSyncError.snapshotDrift
      }
    }
  }

  private func makeRecoveryArchive(
    root: URL,
    recoveryRootURL: URL,
    snapshot: RepositorySafeSyncSnapshot
  ) throws -> URL {
    let recoveryRoot = recoveryRootURL.standardizedFileURL
    try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
    let archive = recoveryRoot.appendingPathComponent(
      "RepoPress-SafeSync-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
    var entries: [RecoveryManifest.Entry] = []
    for collision in snapshot.identicalUntrackedCollisions {
      let source = root.appendingPathComponent(collision.path)
      let sourceAttributes = try regularFileAttributes(source, path: collision.path)
      try requireNoFilters(path: collision.path, root: root)
      let sourceBlob = try output(
        ["hash-object", "--no-filters", "--", collision.path],
        root: root
      ).trimmedForPublishing
      guard sourceAttributes.mode == collision.mode, sourceBlob == collision.localBlobOID else {
        throw RepositorySafeSyncError.snapshotDrift
      }
      let backup = archive.appendingPathComponent("files").appendingPathComponent(collision.path)
      try FileManager.default.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: backup)
      let backupAttributes = try regularFileAttributes(backup, path: collision.path)
      let backupBlob = try hashCopiedFileNoFilters(backup, root: root)
      guard backupAttributes.mode == collision.mode, backupBlob == collision.localBlobOID else {
        throw RepositorySafeSyncError.recoveryRequired(
          recoveryDirectory: archive.path,
          message: "恢复副本校验失败，未改动工作区。"
        )
      }
      entries.append(
        .init(
          path: collision.path,
          blobOID: collision.localBlobOID,
          mode: collision.mode,
          backupRelativePath: "files/\(collision.path)"
        )
      )
    }
    let manifest = RecoveryManifest(
      version: 1,
      repositoryRoot: root.path,
      previousHeadSHA: snapshot.localHeadSHA,
      targetHeadSHA: snapshot.remoteHeadSHA,
      entries: entries
    )
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: archive.appendingPathComponent("manifest.json"), options: .atomic)
    return archive
  }

  private func restoreMissingPaths(
    archive: URL,
    root: URL,
    expected: [RepositorySafeSyncCollision]
  ) throws -> [String] {
    var unrestored: [String] = []
    for collision in expected {
      let destination = root.appendingPathComponent(collision.path)
      if FileManager.default.fileExists(atPath: destination.path) {
        let local = try output(
          ["hash-object", "--no-filters", "--", collision.path],
          root: root
        ).trimmedForPublishing
        if local != collision.localBlobOID { unrestored.append(collision.path) }
        continue
      }
      let backup = archive.appendingPathComponent("files").appendingPathComponent(collision.path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: backup, to: destination)
      let restoredAttributes = try regularFileAttributes(destination, path: collision.path)
      let restoredBlob = try output(
        ["hash-object", "--no-filters", "--", collision.path], root: root
      ).trimmedForPublishing
      if restoredAttributes.mode != collision.mode || restoredBlob != collision.localBlobOID {
        unrestored.append(collision.path)
        try FileManager.default.removeItem(at: destination)
      }
    }
    return unrestored.sorted()
  }

  private func parseStatus(_ text: String) throws -> [RawStatus] {
    let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var records: [RawStatus] = []
    var index = 0
    while index < fields.count {
      let field = fields[index]
      guard field.count >= 3 else {
        throw RepositorySafeSyncError.invalidRepository("Git 状态记录不完整。")
      }
      let status = String(field.prefix(2))
      let separator = field.index(field.startIndex, offsetBy: 2)
      guard field[separator] == " " else {
        throw RepositorySafeSyncError.invalidRepository("Git 状态记录格式无效。")
      }
      let path = String(field[field.index(after: separator)...])
      let renamed = status.contains("R") || status.contains("C")
      let source: String?
      if renamed {
        index += 1
        guard index < fields.count else {
          throw RepositorySafeSyncError.invalidRepository("Git 重命名状态缺少源路径。")
        }
        source = fields[index]
      } else {
        source = nil
      }
      records.append(RawStatus(status: status, path: path, sourcePath: source))
      index += 1
    }
    return records
  }

  private func regularFileAttributes(_ url: URL, path: String) throws -> (mode: String, size: Int64)
  {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw RepositorySafeSyncError.unsafeLocalChanges([path])
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular else {
      throw RepositorySafeSyncError.unsafeLocalChanges([path])
    }
    let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    return (
      permissions & 0o111 == 0 ? "100644" : "100755", (attrs[.size] as? NSNumber)?.int64Value ?? 0
    )
  }

  private func requireNoFilters(path: String, root: URL) throws {
    let attributes = try output(
      ["check-attr", "-z", "filter", "working-tree-encoding", "--", path], root: root
    )
    .split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    guard attributes.count >= 6 else { throw RepositorySafeSyncError.unsafeLocalChanges([path]) }
    let values = stride(from: 2, to: attributes.count, by: 3).map { attributes[$0].lowercased() }
    guard values.allSatisfy({ $0 == "unspecified" || $0 == "unset" }) else {
      throw RepositorySafeSyncError.unsafeLocalChanges([path])
    }
  }

  private func hashCopiedFileNoFilters(_ file: URL, root: URL) throws
    -> String
  {
    let name = ".repopress-safe-sync-verify-\(UUID().uuidString)"
    let temporary = root.appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: file, to: temporary)
    return try output(
      ["hash-object", "--no-filters", "--", name], root: root
    ).trimmedForPublishing
  }

  private func validatePath(_ path: String, root: URL) throws {
    let normalized = path.normalizedRelativePath()
    let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
    let resolved = root.appendingPathComponent(path).standardizedFileURL.path
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\u{FFFD}"),
      normalized == path, !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      !pieces.contains(where: { $0.lowercased() == ".git" }), resolved.hasPrefix(root.path + "/")
    else { throw RepositorySafeSyncError.unsafeLocalChanges([path]) }
  }

  private func validatedOrigin(_ raw: String, profile: SiteProfile, root: URL) throws -> String {
    if let remote = GitRemoteParser.parseRepositoryRemote(raw) {
      guard remote.provider == profile.repositoryProvider,
        remote.owner.caseInsensitiveCompare(profile.repoOwner.trimmedForPublishing) == .orderedSame,
        remote.name.caseInsensitiveCompare(profile.repoName.trimmedForPublishing) == .orderedSame
      else { throw RepositorySafeSyncError.originMismatch(remote.displayName) }
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
      throw RepositorySafeSyncError.originMismatch(GitCommandRunner.redactedDiagnosticText(raw))
    }
    let expectedName = profile.repoName.trimmedForPublishing
    let expectedOwner =
      profile.repoOwner.trimmedForPublishing.split(separator: "/").last.map(String.init) ?? ""
    guard !expectedName.isEmpty,
      local.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(expectedName)
        == .orderedSame,
      expectedOwner.isEmpty
        || local.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(expectedOwner)
          == .orderedSame
    else { throw RepositorySafeSyncError.originMismatch(local.path) }
    return local.path
  }

  private func makeFingerprint(
    context: Context,
    head: String,
    remote: String,
    behind: Int,
    status: String,
    remoteDiff: String,
    local: [RepositorySafeSyncChange],
    remoteChanges: [RepositorySafeSyncChange],
    collisions: [RepositorySafeSyncCollision]
  ) -> String {
    let pieces = [
      context.commonDirectory, context.branch, context.upstream, context.originURL, head, remote,
      String(behind), status, remoteDiff,
      local.map(\.id).joined(separator: "\u{1E}"),
      remoteChanges.map(\.id).joined(separator: "\u{1E}"),
      collisions.map(\.id).joined(separator: "\u{1E}"),
    ]
    return Data(pieces.joined(separator: "\u{1D}").utf8).base64EncodedString()
  }

  private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
  }

  private func isUnmerged(_ status: String) -> Bool {
    ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status)
  }

  private func isStaged(_ status: String) -> Bool {
    status.first.map { $0 != " " && $0 != "?" } ?? false
  }

  private func isSHA(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { $0.isHexDigit }
  }

  private func output(_ arguments: [String], root: URL) throws -> String {
    let result = git.run(arguments, rootURL: root, preserveStandardOutputWhitespace: true)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      var diagnostic = result.output
      if result.didTimeOut { diagnostic = "Git 命令超时。\n" + diagnostic }
      if result.wasOutputTruncated { diagnostic = "Git 输出超过安全上限。\n" + diagnostic }
      throw RepositorySafeSyncError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(arguments),
        output: diagnostic.trimmedForPublishing
      )
    }
    return result.standardOutput
  }
}
