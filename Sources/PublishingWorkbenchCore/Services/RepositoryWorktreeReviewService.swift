import Foundation
import PublishingGitCore

/// Display evidence captured before the final snapshot comparison. It never
/// rereads mutable files from a confirmation view or writes Git objects.
public struct RepositoryWorktreeFileReview: Hashable, Sendable, Identifiable {
  public let entryID: String
  public let patch: String
  public let notice: String?
  public let imageData: Data?
  public var id: String { entryID }

  public init(entryID: String, patch: String, notice: String? = nil, imageData: Data? = nil) {
    self.entryID = entryID
    self.patch = patch
    self.notice = notice
    self.imageData = imageData
  }

  public static func isComplete(
    entries: [RepositoryWorktreePublishEntry], reviews: [Self]
  ) -> Bool {
    entries.count == reviews.count
      && Set(entries.map(\.id)) == Set(reviews.map(\.entryID))
      && reviews.allSatisfy { $0.notice == nil }
  }
}

struct RepositoryWorktreeReviewService {
  let git: GitCommandRunner

  func capture(
    entries: [RepositoryWorktreePublishEntry],
    root: URL,
    baseRevision: String,
    targetRevision: String? = nil
  ) -> [RepositoryWorktreeFileReview] {
    // Explicitly report oversized evidence instead of silently presenting a
    // truncated patch as a complete review. Bound the whole confirmation too.
    var remainingBytes = 16 * 1_024 * 1_024
    return entries.map { entry in
      guard remainingBytes > 0 else {
        return RepositoryWorktreeFileReview(
          entryID: entry.id, patch: "",
          notice: CoreL10n.text("差异超过应用内审阅容量，未显示完整内容。请缩小本次变更后重新审阅。")
        )
      }
      var runner = git
      runner.maximumOutputBytes = min(remainingBytes, 4 * 1_024 * 1_024)
      let options = [
        "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--full-index",
      ]
      let arguments: [String]
      if entry.status == "??", targetRevision == nil {
        arguments = ["diff", "--no-index"] + options + ["--", "/dev/null", entry.path]
      } else {
        let revisions = [baseRevision] + (targetRevision.map { [$0] } ?? [])
        arguments =
          ["--literal-pathspecs", "diff"] + options + revisions
          + ["--"] + Array(Set([entry.path, entry.sourcePath].compactMap { $0 })).sorted()
      }
      let result = runner.run(arguments, rootURL: root, preserveStandardOutputWhitespace: true)
      guard !result.didTimeOut,
        result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        result.terminationStatus == 0 || result.terminationStatus == 1
      else {
        return RepositoryWorktreeFileReview(
          entryID: entry.id, patch: "",
          notice: CoreL10n.text("无法读取此文件差异，请重新审阅。")
        )
      }
      remainingBytes -= result.standardOutput.utf8.count
      guard
        result.wasOutputTruncated || targetRevision != nil
          || patchMatchesSnapshot(
            result.standardOutput, entry: entry, root: root, baseRevision: baseRevision)
      else {
        return RepositoryWorktreeFileReview(
          entryID: entry.id, patch: "",
          notice: CoreL10n.text("无法读取此文件差异，请重新审阅。")
        )
      }
      let notice =
        result.wasOutputTruncated
        ? CoreL10n.text("差异超过应用内审阅容量，未显示完整内容。请缩小本次变更后重新审阅。")
        : nil
      var imageData: Data?
      if targetRevision == nil, entry.kind != .deleted,
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic"].contains(
          root.appendingPathComponent(entry.path).pathExtension.lowercased()
        ), entry.byteSize > 0, entry.byteSize <= min(Int64(remainingBytes), 4 * 1_024 * 1_024)
      {
        if let data = try? Data(contentsOf: root.appendingPathComponent(entry.path)),
          Self.frozenDataMatches(data, entry: entry, root: root, git: git)
        {
          imageData = data
        } else {
          return RepositoryWorktreeFileReview(
            entryID: entry.id, patch: "",
            notice: CoreL10n.text("无法读取此文件差异，请重新审阅。")
          )
        }
        remainingBytes -= imageData?.count ?? 0
      }
      return RepositoryWorktreeFileReview(
        entryID: entry.id, patch: result.standardOutput, notice: notice, imageData: imageData
      )
    }
  }

  /// Full-index patches carry the Git blob IDs of the bytes actually diffed.
  /// Bind that evidence to the reviewed snapshot, including an ABA edit that
  /// has already been reverted before the final worktree inspection.
  private func patchMatchesSnapshot(
    _ patch: String, entry: RepositoryWorktreePublishEntry, root: URL, baseRevision: String
  ) -> Bool {
    let targetIDs = patch.split(separator: "\n").compactMap { line -> String? in
      guard line.hasPrefix("index ") else { return nil }
      let pair = line.dropFirst(6).split(separator: " ").first?.components(separatedBy: "..")
      guard let pair, pair.count == 2 else { return nil }
      return pair[1]
    }
    if entry.kind == .deleted {
      return !targetIDs.isEmpty && targetIDs.allSatisfy { $0.allSatisfy { $0 == "0" } }
    }
    guard let expected = entry.blobOID else { return false }
    if !targetIDs.isEmpty {
      return targetIDs.contains(expected)
        && targetIDs.allSatisfy { $0 == expected || $0.allSatisfy { $0 == "0" } }
    }
    // Mode-only changes have no index line; their content must equal the base blob.
    let base = git.run(
      ["rev-parse", "--verify", "\(baseRevision):\(entry.sourcePath ?? entry.path)"], rootURL: root
    )
    return base.terminationStatus == 0 && !base.didTimeOut && !base.wasOutputTruncated
      && base.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == expected
  }

  /// Hash the captured bytes, never the mutable source path. --path preserves
  /// the repository's clean/EOL rules without writing a Git object or index.
  static func frozenDataMatches(
    _ data: Data, entry: RepositoryWorktreePublishEntry, root: URL, git: GitCommandRunner
  ) -> Bool {
    guard let expected = entry.blobOID else { return false }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPress-ReviewBytes-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appendingPathComponent("content")
      try data.write(to: file, options: .atomic)
      let hash = git.run(["hash-object", "--path=\(entry.path)", "--", file.path], rootURL: root)
      return hash.terminationStatus == 0 && !hash.didTimeOut && !hash.wasOutputTruncated
        && hash.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    } catch { return false }
  }
}
