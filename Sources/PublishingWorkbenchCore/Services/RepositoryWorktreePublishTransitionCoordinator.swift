import CryptoKit
import Foundation
import PublishingGitCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct RepositoryWorktreePublishTransitionRecord: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let identifier: UUID
  let repositoryRoot: String
  let branch: String
  let previousHeadSHA: String
  let commitSHA: String
  let previousIndexFingerprintSHA256: String
  let indexPath: String

  init(
    identifier: UUID = UUID(),
    repositoryRoot: String,
    branch: String,
    previousHeadSHA: String,
    commitSHA: String,
    previousIndexFingerprint: String,
    indexPath: String
  ) {
    version = Self.currentVersion
    self.identifier = identifier
    self.repositoryRoot = repositoryRoot
    self.branch = branch
    self.previousHeadSHA = previousHeadSHA
    self.commitSHA = commitSHA
    previousIndexFingerprintSHA256 = Self.digest(previousIndexFingerprint)
    self.indexPath = indexPath
  }

  static func digest(_ value: String) -> String {
    Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
  }
}

struct RepositoryWorktreePublishTransition {
  let record: RepositoryWorktreePublishTransitionRecord
  let journalURL: URL
  let markerURL: URL
  let indexURL: URL
  let indexLockURL: URL
}

struct RepositoryWorktreePublishOwnedIndexLock {
  let transition: RepositoryWorktreePublishTransition
  let handle: FileHandle
}

/// Makes the short ref/index transition recoverable across process death.
/// The durable journal is stored in the worktree's Git directory, never in
/// the publishable worktree. A hard-linked owner marker lets recovery remove
/// only the exact `index.lock` created by RepoPress.
struct RepositoryWorktreePublishTransitionCoordinator {
  private static let journalFileName = "repopress-worktree-publish-transaction.json"
  private static let markerPrefix = "repopress-worktree-index-owner-"
  private static let maximumJournalByteCount = 64 * 1_024

  private let git: GitCommandRunner
  private let fileManager = FileManager.default

  init(gitCommandRunner: GitCommandRunner) {
    git = gitCommandRunner
  }

  func recoverIfNeeded(profile: SiteProfile, root: URL) throws {
    let root = root.standardizedFileURL
    let gitDirectory = try repositoryGitDirectory(root: root)
    let journalURL = gitDirectory.appendingPathComponent(Self.journalFileName)
    guard fileManager.fileExists(atPath: journalURL.path) else { return }
    guard !isSymbolicLink(journalURL) else {
      throw recoveryFailure("恢复记录不能是符号链接。")
    }
    let data = try BoundedFileReader.data(
      at: journalURL,
      maximumByteCount: Self.maximumJournalByteCount
    )
    let record: RepositoryWorktreePublishTransitionRecord
    do {
      record = try JSONDecoder().decode(
        RepositoryWorktreePublishTransitionRecord.self,
        from: data
      )
    } catch {
      throw recoveryFailure("无法读取发布恢复记录。")
    }
    let indexURL = try repositoryIndexURL(root: root)
    let markerURL = gitDirectory.appendingPathComponent(
      Self.markerPrefix + record.identifier.uuidString
    )
    let transition = RepositoryWorktreePublishTransition(
      record: record,
      journalURL: journalURL,
      markerURL: markerURL,
      indexURL: indexURL,
      indexLockURL: URL(fileURLWithPath: indexURL.path + ".lock")
    )
    guard record.version == RepositoryWorktreePublishTransitionRecord.currentVersion,
      record.repositoryRoot == root.path,
      record.indexPath == indexURL.path,
      record.branch == profile.branch.trimmedForPublishing,
      isSHA(record.previousHeadSHA),
      isSHA(record.commitSHA),
      !record.previousIndexFingerprintSHA256.isEmpty
    else {
      throw recoveryFailure("发布恢复记录与当前仓库不匹配。")
    }
    let branch = try output(
      ["symbolic-ref", "--quiet", "--short", "HEAD"],
      root: root
    ).trimmedForPublishing
    guard branch == record.branch else {
      throw recoveryFailure("当前分支与发布恢复记录不匹配。")
    }
    let currentHead = try output(["rev-parse", "--verify", "HEAD"], root: root)
      .trimmedForPublishing
    let currentFingerprint = try indexFingerprint(root: root)
    let currentFingerprintDigest = RepositoryWorktreePublishTransitionRecord.digest(
      currentFingerprint
    )

    if currentHead == record.previousHeadSHA {
      guard currentFingerprintDigest == record.previousIndexFingerprintSHA256 else {
        throw recoveryFailure("真实 index 已被其他操作修改，未自动清理恢复记录。")
      }
      try removeOwnedArtifacts(transition)
      return
    }

    guard currentHead == record.commitSHA else {
      throw recoveryFailure("HEAD 已被其他操作修改，未自动回退或覆盖。")
    }
    if currentFingerprintDigest == record.previousIndexFingerprintSHA256 {
      try ensureIndexLockIsOwnedOrAbsent(transition)
      _ = try output(
        [
          "update-ref", "refs/heads/\(record.branch)",
          record.previousHeadSHA, record.commitSHA,
        ],
        root: root
      )
      try removeOwnedArtifacts(transition)
      return
    }

    guard try indexMatchesHead(root: root) else {
      throw recoveryFailure("HEAD 与 index 都发生变化，未自动回退或覆盖。")
    }
    try removeOwnedArtifacts(transition)
  }

  func begin(
    root: URL,
    branch: String,
    previousHeadSHA: String,
    commitSHA: String,
    previousIndexFingerprint: String,
    indexURL: URL
  ) throws -> RepositoryWorktreePublishTransition {
    let root = root.standardizedFileURL
    let gitDirectory = try repositoryGitDirectory(root: root)
    let journalURL = gitDirectory.appendingPathComponent(Self.journalFileName)
    guard !fileManager.fileExists(atPath: journalURL.path) else {
      throw recoveryFailure("仍有未完成的整仓库发布恢复记录。")
    }
    let record = RepositoryWorktreePublishTransitionRecord(
      repositoryRoot: root.path,
      branch: branch,
      previousHeadSHA: previousHeadSHA,
      commitSHA: commitSHA,
      previousIndexFingerprint: previousIndexFingerprint,
      indexPath: indexURL.path
    )
    let markerURL = gitDirectory.appendingPathComponent(
      Self.markerPrefix + record.identifier.uuidString
    )
    let transition = RepositoryWorktreePublishTransition(
      record: record,
      journalURL: journalURL,
      markerURL: markerURL,
      indexURL: indexURL,
      indexLockURL: URL(fileURLWithPath: indexURL.path + ".lock")
    )
    do {
      try createMarker(at: markerURL, identifier: record.identifier)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(record).write(to: journalURL, options: [.atomic])
      let handle = try FileHandle(forWritingTo: journalURL)
      try handle.synchronize()
      try handle.close()
      return transition
    } catch {
      try? fileManager.removeItem(at: markerURL)
      try? fileManager.removeItem(at: journalURL)
      throw error
    }
  }

  func acquireIndexLock(
    for transition: RepositoryWorktreePublishTransition
  ) throws -> RepositoryWorktreePublishOwnedIndexLock {
    let status = transition.markerURL.path.withCString { markerPath in
      transition.indexLockURL.path.withCString { lockPath in
        link(markerPath, lockPath)
      }
    }
    guard status == 0 else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "Git index 正被其他操作占用，请等待后重新审阅。"
      )
    }
    do {
      let handle = try FileHandle(forWritingTo: transition.markerURL)
      return RepositoryWorktreePublishOwnedIndexLock(
        transition: transition,
        handle: handle
      )
    } catch {
      try? removeOwnedArtifacts(transition)
      throw error
    }
  }

  func installIndex(
    from sourceURL: URL,
    using lock: RepositoryWorktreePublishOwnedIndexLock
  ) throws {
    let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
    try lock.handle.truncate(atOffset: 0)
    try lock.handle.write(contentsOf: data)
    try lock.handle.synchronize()
    try lock.handle.close()
    let transition = lock.transition
    let status = transition.indexLockURL.path.withCString { sourcePath in
      transition.indexURL.path.withCString { destinationPath in
        rename(sourcePath, destinationPath)
      }
    }
    guard status == 0 else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "无法原子更新 Git index。"
      )
    }
    // The index is already installed once rename succeeds. Marker cleanup is
    // finalized with the durable journal so a cleanup error can be recovered
    // without rolling HEAD back against the new index.
    try? fileManager.removeItem(at: transition.markerURL)
  }

  func finish(_ transition: RepositoryWorktreePublishTransition) throws {
    if fileManager.fileExists(atPath: transition.markerURL.path) {
      try fileManager.removeItem(at: transition.markerURL)
    }
    try fileManager.removeItem(at: transition.journalURL)
  }

  func cancelBeforeHeadMove(
    _ lock: RepositoryWorktreePublishOwnedIndexLock?,
    transition: RepositoryWorktreePublishTransition
  ) {
    try? lock?.handle.close()
    try? removeOwnedArtifacts(transition)
  }

  func rollbackAfterHeadMove(
    _ lock: RepositoryWorktreePublishOwnedIndexLock?,
    transition: RepositoryWorktreePublishTransition,
    root: URL
  ) -> Bool {
    try? lock?.handle.close()
    let record = transition.record
    do {
      _ = try output(
        [
          "update-ref", "refs/heads/\(record.branch)",
          record.previousHeadSHA, record.commitSHA,
        ],
        root: root
      )
      try removeOwnedArtifacts(transition)
      return true
    } catch {
      return false
    }
  }

  private func createMarker(at url: URL, identifier: UUID) throws {
    let descriptor = url.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      throw recoveryFailure("无法创建发布恢复标记。")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: Data(identifier.uuidString.utf8))
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      try? fileManager.removeItem(at: url)
      throw error
    }
  }

  private func removeOwnedArtifacts(
    _ transition: RepositoryWorktreePublishTransition
  ) throws {
    try ensureIndexLockIsOwnedOrAbsent(transition)
    if fileManager.fileExists(atPath: transition.indexLockURL.path) {
      try fileManager.removeItem(at: transition.indexLockURL)
    }
    if fileManager.fileExists(atPath: transition.markerURL.path) {
      try fileManager.removeItem(at: transition.markerURL)
    }
    if fileManager.fileExists(atPath: transition.journalURL.path) {
      try fileManager.removeItem(at: transition.journalURL)
    }
  }

  private func ensureIndexLockIsOwnedOrAbsent(
    _ transition: RepositoryWorktreePublishTransition
  ) throws {
    guard fileManager.fileExists(atPath: transition.indexLockURL.path) else { return }
    guard fileManager.fileExists(atPath: transition.markerURL.path),
      try sameFileIdentity(transition.indexLockURL, transition.markerURL)
    else {
      throw recoveryFailure("Git index.lock 属于其他操作，未自动删除。")
    }
  }

  private func sameFileIdentity(_ lhs: URL, _ rhs: URL) throws -> Bool {
    let lhsAttributes = try fileManager.attributesOfItem(atPath: lhs.path)
    let rhsAttributes = try fileManager.attributesOfItem(atPath: rhs.path)
    guard let lhsDevice = lhsAttributes[.systemNumber] as? NSNumber,
      let rhsDevice = rhsAttributes[.systemNumber] as? NSNumber,
      let lhsFile = lhsAttributes[.systemFileNumber] as? NSNumber,
      let rhsFile = rhsAttributes[.systemFileNumber] as? NSNumber
    else {
      return false
    }
    return lhsDevice == rhsDevice && lhsFile == rhsFile
  }

  private func repositoryGitDirectory(root: URL) throws -> URL {
    let value = try output(["rev-parse", "--absolute-git-dir"], root: root)
      .trimmedForPublishing
    guard value.hasPrefix("/") else {
      throw recoveryFailure("无法定位 Git 元数据目录。")
    }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
  }

  private func repositoryIndexURL(root: URL) throws -> URL {
    let value = try output(["rev-parse", "--git-path", "index"], root: root)
      .trimmedForPublishing
    guard !value.isEmpty else {
      throw recoveryFailure("无法定位 Git index。")
    }
    return URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL
  }

  private func indexFingerprint(root: URL) throws -> String {
    try output(["ls-files", "--stage", "-z"], root: root, preserveWhitespace: true)
  }

  private func indexMatchesHead(root: URL) throws -> Bool {
    let result = git.run(["diff", "--cached", "--quiet", "HEAD", "--"], rootURL: root)
    guard result.terminationStatus == 0 || result.terminationStatus == 1,
      !result.didTimeOut,
      !result.wasOutputTruncated
    else {
      throw recoveryFailure("无法核对恢复后的 Git index。")
    }
    return result.terminationStatus == 0
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

  private func isSHA(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy(\.isHexDigit)
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func recoveryFailure(_ message: String) -> RepositoryWorktreePublishError {
    .invalidRepository("整仓库发布恢复失败：\(message)")
  }
}
