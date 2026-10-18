import Foundation

/// Evidence recorded before moving HEAD or contacting the remote. It is a
/// receipt for one reviewed commit, never authority to perform another push.
struct RepositoryWorktreePushRecoveryRecord: Codable, Hashable, Sendable {
  let profileID: UUID
  let repositoryIdentity: DraftRepositoryIdentity
  let repositoryRoot: String
  let gitCommonDirectory: String
  let pushOriginDigest: String
  let commitSHA: String
  let branch: String
  let committedPaths: [String]
  let article: RepositoryWorktreeArticleVerificationTarget?
  let articleTrackingRequest: ArticlePublishTrackingRequest?
  let createdAt: Date

  init(
    profile: SiteProfile, confirmation: RepositoryWorktreePublishConfirmation, commitSHA: String,
    trackingRequest: ArticlePublishTrackingRequest? = nil
  ) {
    profileID = profile.id
    repositoryIdentity = DraftRepositoryIdentity(profile: profile)
    repositoryRoot = confirmation.snapshot.repositoryRoot
    gitCommonDirectory = confirmation.snapshot.gitCommonDirectory
    pushOriginDigest = ArticleDraft.repositoryDocumentDigest(confirmation.snapshot.pushOriginURL)
    self.commitSHA = commitSHA
    branch = confirmation.snapshot.branch
    committedPaths = confirmation.snapshot.paths
    article = confirmation.articleVerificationTarget
    articleTrackingRequest =
      confirmation.isScoped
      ? trackingRequest ?? ArticlePublishTrackingRequest(profile: profile) : nil
    createdAt = Date()
  }
}

/// An independent, atomic journal beside the workspace file survives both a
/// network interruption and a failed workspace save. It contains no credential.
struct RepositoryWorktreePushRecoveryStore: Sendable {
  let directoryURL: URL

  init(workbenchFileURL: URL) {
    directoryURL = workbenchFileURL.deletingPathExtension()
      .appendingPathExtension("worktree-push-recovery")
  }

  func save(_ record: RepositoryWorktreePushRecoveryRecord) throws {
    let destination = try fileURL(for: record)
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let data = try JSONEncoder().encode(record)
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: destination.path)
  }

  func records(profileID: UUID) throws -> [RepositoryWorktreePushRecoveryRecord] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    ).filter {
      $0.lastPathComponent.hasPrefix(profileID.uuidString + "-") && $0.pathExtension == "json"
    }
    .map { url in
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= 1_048_576
      else { throw RepositoryWorktreePublishError.invalidRepository("无法安全读取推送恢复记录。") }
      let record = try JSONDecoder().decode(
        RepositoryWorktreePushRecoveryRecord.self, from: Data(contentsOf: url))
      guard try fileURL(for: record).standardizedFileURL.path == url.standardizedFileURL.path,
        record.profileID == profileID
      else {
        throw RepositoryWorktreePublishError.invalidRepository("推送恢复记录身份不一致。")
      }
      return record
    }.sorted { $0.createdAt > $1.createdAt }
  }

  func remove(_ record: RepositoryWorktreePushRecoveryRecord) throws {
    let url = try fileURL(for: record)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func fileURL(for record: RepositoryWorktreePushRecoveryRecord) throws -> URL {
    guard [40, 64].contains(record.commitSHA.count),
      record.commitSHA.allSatisfy(\.isHexDigit)
    else { throw RepositoryWorktreePublishError.invalidRepository("推送恢复记录的提交标识无效。") }
    return directoryURL.appendingPathComponent(
      record.profileID.uuidString + "-" + record.commitSHA + ".json")
  }
}

extension WorkbenchStore {
  var worktreePushRecoveryStore: RepositoryWorktreePushRecoveryStore {
    RepositoryWorktreePushRecoveryStore(workbenchFileURL: persistenceStore.persistence.fileURL)
  }

  /// Do not discard the independent receipt until the release record has
  /// reached durable workspace storage. Replaying a receipt is idempotent.
  @discardableResult
  func finishWorktreePushRecovery(_ record: RepositoryWorktreePushRecoveryRecord) -> Bool {
    guard !persistenceStore.isRecoveryWriteProtected else { return false }
    persistenceStore.markUnsavedChanges()
    let snapshot = persistenceStore.persistence.snapshot(from: self)
    guard persistenceStore.flush(snapshot: snapshot) else { return false }
    do {
      try worktreePushRecoveryStore.remove(record)
    } catch {
      // The release is durable. Retain the receipt for idempotent replay if
      // journal cleanup is temporarily unavailable.
      return true
    }
    return true
  }
}

extension RepositoryWorktreePushRetryService {
  /// A read-only reconciliation of a recorded attempt. New local edits do
  /// not erase evidence about the earlier commit and are never written here.
  func confirmedRecordedPush(
    _ record: RepositoryWorktreePushRecoveryRecord, profile: SiteProfile
  ) throws -> RepositoryWorktreePublishResult? {
    guard record.profileID == profile.id,
      record.repositoryIdentity == DraftRepositoryIdentity(profile: profile),
      let root = profile.localRepositoryRootURL?.standardizedFileURL,
      root.path == record.repositoryRoot,
      record.branch == (profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"),
      [40, 64].contains(record.commitSHA.count), record.commitSHA.allSatisfy(\.isHexDigit)
    else { throw RepositoryWorktreePublishError.snapshotDrift }
    let topLevel = try output(["rev-parse", "--show-toplevel"], root: root).trimmedForPublishing
    let common = try output(["rev-parse", "--git-common-dir"], root: root).trimmedForPublishing
    guard URL(fileURLWithPath: topLevel).standardizedFileURL == root,
      URL(fileURLWithPath: common, relativeTo: root).standardizedFileURL.path
        == record.gitCommonDirectory,
      try output(["symbolic-ref", "--quiet", "--short", "HEAD"], root: root).trimmedForPublishing
        == record.branch,
      ArticleDraft.repositoryDocumentDigest(try validatedPushOrigin(profile: profile, root: root))
        == record.pushOriginDigest
    else { throw RepositoryWorktreePublishError.snapshotDrift }
    let rawOrigin = try output(["remote", "get-url", "origin"], root: root).trimmedForPublishing
    _ = try validatedOrigin(rawOrigin, profile: profile, root: root)
    let remote = try requiredRemoteSHA(branch: record.branch, root: root)
    guard remote.caseInsensitiveCompare(record.commitSHA) == .orderedSame else { return nil }
    guard
      try output(["cat-file", "-t", record.commitSHA], root: root).trimmedForPublishing == "commit"
    else { throw RepositoryWorktreePublishError.snapshotDrift }
    if let article = record.article, let digest = article.sourceDocumentDigest {
      try validateRelativePath(article.markdownPath)
      let document = try output(
        ["show", record.commitSHA + ":" + article.markdownPath], root: root,
        preserveWhitespace: true)
      guard record.committedPaths.contains(article.markdownPath),
        ArticleDraft.repositoryDocumentDigest(document) == digest
      else { throw RepositoryWorktreePublishError.snapshotDrift }
    }
    guard try requiredRemoteSHA(branch: record.branch, root: root) == remote else {
      throw RepositoryWorktreePublishError.snapshotDrift
    }
    return RepositoryWorktreePublishResult(
      commitSHA: record.commitSHA, branch: record.branch, pushed: true,
      remoteCommitSHA: remote, committedPaths: record.committedPaths)
  }

}
