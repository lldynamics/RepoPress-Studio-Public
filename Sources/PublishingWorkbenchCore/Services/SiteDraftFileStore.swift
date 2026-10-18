import Foundation
import PublishingCoreSupport
import PublishingGitCore

public enum SiteDraftFileStoreError: LocalizedError, Equatable {
  case generalDraftCannotBeWritten
  case projectFileChangedExternally(String)
  case frontMatterRecoveryRequired

  public var errorDescription: String? {
    switch self {
    case .generalDraftCannotBeWritten:
      return CoreL10n.text("仅本地草稿只保存在软件中；请使用导出功能选择保存位置。")
    case .frontMatterRecoveryRequired:
      return CoreL10n.text("文章元数据需要恢复；已停止写入，请重新导入原始文章，以免丢失分类、标签或自定义字段。")
    case .projectFileChangedExternally(let path):
      return CoreL10n.format(
        "项目文件已被其他软件或 Git 修改，已停止自动保存以避免覆盖：%@",
        path
      )
    }
  }
}

public struct SiteDraftFileWriteResult: Equatable, Sendable {
  public var repositoryPath: String
  public var writtenPaths: [String]

  public init(repositoryPath: String, writtenPaths: [String]) {
    self.repositoryPath = repositoryPath
    self.writtenPaths = writtenPaths
  }
}

/// Serializes live Markdown writes so rapid edits cannot leave an older path
/// behind when a draft's slug or date changes.
public final class SiteDraftFileStore: @unchecked Sendable {
  private struct DraftSiteKey: Hashable {
    let draftID: UUID
    let profileID: UUID
  }

  private struct RepositoryFileBaseline {
    let repositoryPath: String
    let contentDigest: String
  }

  private let lock = NSLock()
  private let packageBuilder: PublishPackageBuilder
  private let previewService: LocalPublishPreviewService
  private let moveJournalURL: URL?
  private var latestRepositoryBaselines: [DraftSiteKey: RepositoryFileBaseline] = [:]

  public init(
    packageBuilder: PublishPackageBuilder = PublishPackageBuilder(),
    previewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    moveJournalURL: URL? = nil
  ) {
    self.packageBuilder = packageBuilder
    self.previewService = previewService
    self.moveJournalURL = moveJournalURL
  }

  public func write(
    draft: ArticleDraft,
    profile: SiteProfile
  ) throws -> SiteDraftFileWriteResult {
    guard !draft.isGeneralDraft else {
      throw SiteDraftFileStoreError.generalDraftCannotBeWritten
    }
    guard FrontMatterRenderer().preservationIssue(draft: draft, profile: profile) == nil else {
      throw SiteDraftFileStoreError.frontMatterRecoveryRequired
    }
    guard let repositoryRootURL = profile.localRepositoryRootURL else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }

    lock.lock()
    defer { lock.unlock() }

    // Check a restored/selected location before preview baseline comparison.
    // Otherwise a disconnected volume or deleted folder produces a synthetic
    // missing baseline and is incorrectly reported as an external edit.
    try previewService.validateRepositoryRoot(profile: profile, rootURL: repositoryRootURL)

    let key = DraftSiteKey(draftID: draft.id, profileID: profile.id)
    let draftBaseline = repositoryFileBaseline(for: draft, profile: profile)
    let expectedBaseline = draftBaseline ?? latestRepositoryBaselines[key]
    var preparedDraft = draft
    if draftBaseline == nil, let expectedBaseline {
      preparedDraft.recordProjectFile(
        profile: profile,
        repositoryPath: expectedBaseline.repositoryPath,
        renderedContentDigest: expectedBaseline.contentDigest
      )
    }

    var package = packageBuilder.build(draft: preparedDraft, profile: profile)
    package.files = package.files.filter { $0.kind == .markdown }
    guard
      let writtenDocument = package.files.first(where: {
        $0.operation == .upsert
          && $0.repositoryPath.normalizedRelativePath()
            == package.markdownPath.normalizedRelativePath()
      })?.content
    else {
      throw LocalPublishPreviewError.invalidPreview(package.markdownPath)
    }
    // Capture the destination baseline and carry it through to the actual
    // write.  The preview writer revalidates every target immediately before
    // mutation, so an external editor update between these operations fails
    // closed instead of being overwritten.  A moved draft's package includes
    // both the old deletion and new upsert, protecting both paths.
    let preview = previewService.preview(package: package, profile: profile)
    let isIdempotentWrite = try validateRepositoryBaseline(
      preview: preview,
      expectedBaseline: expectedBaseline,
      destinationPath: package.markdownPath,
      intendedDocument: writtenDocument,
      hasOnlyDestinationUpsert: package.files.count == 1
        && package.files.first?.operation == .upsert
        && package.files.first?.repositoryPath.normalizedRelativePath()
          == package.markdownPath.normalizedRelativePath()
    )
    if !isIdempotentWrite {
      // Persist ownership before the disk transaction removes the old path.
      try recordMoves(package: package, profile: profile, root: repositoryRootURL)
    }
    let writtenPaths =
      isIdempotentWrite ? [] : try previewService.write(preview: preview, profile: profile)
    latestRepositoryBaselines[key] = RepositoryFileBaseline(
      repositoryPath: package.markdownPath.normalizedRelativePath(),
      contentDigest: ArticleDraft.repositoryDocumentDigest(writtenDocument)
    )
    return SiteDraftFileWriteResult(
      repositoryPath: package.markdownPath,
      writtenPaths: writtenPaths
    )
  }

  public func writeAsync(
    draft: ArticleDraft,
    profile: SiteProfile
  ) async throws -> SiteDraftFileWriteResult {
    try await Task.detached(priority: .utility) {
      try self.write(draft: draft, profile: profile)
    }.value
  }

  private struct PendingMove: Codable {
    let draftID: UUID
    let identity: DraftRepositoryIdentity
    let rootPath: String
    let oldPath: String
    let head: String
    let treeEntry: String
  }

  private func moveGit(_ arguments: [String], root: URL) throws -> String {
    let result = GitCommandRunner().run(
      arguments, rootURL: root, preserveStandardOutputWhitespace: true)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryWorktreePublishError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(arguments), output: result.output)
    }
    return result.standardOutput
  }

  private func recordMoves(
    package: PublishPackage, profile: SiteProfile, root: URL
  ) throws {
    guard let moveJournalURL else { return }
    let deletions = package.files.filter { $0.operation == .delete && $0.kind == .markdown }
    guard !deletions.isEmpty else { return }
    let headResult = GitCommandRunner().run(["rev-parse", "--verify", "HEAD"], rootURL: root)
    // A project without its first Git commit has no tracked old path to retire.
    guard !headResult.didTimeOut, !headResult.wasOutputTruncated else {
      throw RepositoryGitExecutionPolicyError.reviewedContentChanged
    }
    guard headResult.terminationStatus == 0 else { return }
    let head = headResult.standardOutput.trimmedForPublishing
    for file in deletions {
      let path = file.repositoryPath.normalizedRelativePath()
      let entry = try moveGit(["ls-tree", "-z", head, "--", ":(literal)\(path)"], root: root)
      guard !entry.isEmpty else { continue }
      let move = PendingMove(
        draftID: package.draftID, identity: DraftRepositoryIdentity(profile: profile),
        rootPath: root.standardizedFileURL.path, oldPath: path, head: head, treeEntry: entry)
      try FileManager.default.createDirectory(
        at: moveJournalURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
      try JSONEncoder().encode(move).write(
        to: moveJournalURL.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }
  }

  func recordPendingMoves(package: PublishPackage, profile: SiteProfile) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let root = profile.localRepositoryRootURL else { return }
    try recordMoves(package: package, profile: profile, root: root)
  }

  /// Includes only explicit, still-uncommitted deletions owned by this article.
  /// Recreated paths and changed Git baselines require a new whole-repository review.
  func pendingMovePaths(
    draft: ArticleDraft, profile: SiteProfile, otherArticlePaths: Set<String>,
    revision: String = "HEAD"
  ) throws -> [String] {
    lock.lock()
    defer { lock.unlock() }
    guard let moveJournalURL, let root = profile.localRepositoryRootURL,
      FileManager.default.fileExists(atPath: moveJournalURL.path)
    else { return [] }
    var paths: Set<String> = []
    for url in try FileManager.default.contentsOfDirectory(
      at: moveJournalURL, includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
      let move = try JSONDecoder().decode(
        PendingMove.self, from: SafeFileReader.data(at: url, maximumByteCount: 1_048_576))
      guard move.draftID == draft.id, move.identity == DraftRepositoryIdentity(profile: profile),
        move.rootPath == root.standardizedFileURL.path
      else { continue }
      guard [40, 64].contains(move.head.count), move.head.allSatisfy(\.isHexDigit),
        !move.oldPath.hasPrefix("/"),
        !move.oldPath.split(separator: "/", omittingEmptySubsequences: false)
          .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      else { throw SiteDraftFileStoreError.projectFileChangedExternally(move.oldPath) }
      // A move back to the original filename no longer needs its deletion.
      if move.oldPath == profile.markdownPath(for: draft) {
        try FileManager.default.removeItem(at: url)
        continue
      }
      // The same blob on a rewound or unrelated branch is not evidence that
      // the original deletion still belongs to this history.
      let ancestry = GitCommandRunner().run(
        ["merge-base", "--is-ancestor", move.head, revision], rootURL: root)
      guard ancestry.terminationStatus == 0, !ancestry.didTimeOut,
        !ancestry.wasOutputTruncated
      else { throw SiteDraftFileStoreError.projectFileChangedExternally(move.oldPath) }
      let entry = try moveGit(
        ["ls-tree", "-z", revision, "--", ":(literal)\(move.oldPath)"], root: root)
      if entry.isEmpty {
        try FileManager.default.removeItem(at: url)
        continue
      }
      let history = try moveGit(
        ["log", "--format=%H", "\(move.head)..\(revision)", "--", ":(literal)\(move.oldPath)"],
        root: root)
      let oldURL = root.appendingPathComponent(move.oldPath)
      let oldPathExists: Bool
      do {
        _ = try FileManager.default.attributesOfItem(atPath: oldURL.path)
        oldPathExists = true
      } catch CocoaError.fileReadNoSuchFile {
        oldPathExists = false
      }
      guard entry == move.treeEntry, history.trimmedForPublishing.isEmpty,
        !otherArticlePaths.contains(move.oldPath), !oldPathExists
      else { throw SiteDraftFileStoreError.projectFileChangedExternally(move.oldPath) }
      paths.insert(move.oldPath)
    }
    return paths.sorted()
  }

  private func repositoryFileBaseline(
    for draft: ArticleDraft,
    profile: SiteProfile
  ) -> RepositoryFileBaseline? {
    guard let binding = draft.repositoryBinding,
      binding.identity == nil || binding.identity == DraftRepositoryIdentity(profile: profile),
      let contentDigest = binding.projectFileContentDigest?.trimmedForPublishing.nilIfEmpty,
      let repositoryPath = binding.repositoryPath.normalizedRelativePath().nilIfEmpty,
      draft.repositoryPath?.normalizedRelativePath().nilIfEmpty == repositoryPath
    else {
      return nil
    }
    return RepositoryFileBaseline(
      repositoryPath: repositoryPath,
      contentDigest: contentDigest
    )
  }

  /// The repository binding is the last disk state the app actually wrote or
  /// imported. Comparing it with the preview baseline closes the autosave
  /// debounce window: a file changed before preview generation is still
  /// recognized as external instead of becoming the baseline to overwrite.
  private func validateRepositoryBaseline(
    preview: LocalPublishPreview,
    expectedBaseline: RepositoryFileBaseline?,
    destinationPath: String,
    intendedDocument: String,
    hasOnlyDestinationUpsert: Bool
  ) throws -> Bool {
    let normalizedDestinationPath = destinationPath.normalizedRelativePath()
    if let expectedBaseline {
      let baselineState = try previewBaselineState(
        for: expectedBaseline.repositoryPath,
        in: preview
      )
      guard case .fileDigest(let digest) = baselineState else {
        throw SiteDraftFileStoreError.projectFileChangedExternally(
          expectedBaseline.repositoryPath
        )
      }

      let actualDigest = hexadecimalDigest(digest)
      if actualDigest != expectedBaseline.contentDigest.lowercased() {
        // A completed write can outlive its persisted baseline. Only accept
        // exact intended bytes at the unchanged path, and only for the one
        // upsert this store owns. Moves and multi-operation packages remain
        // protected by the normal conflict path.
        guard
          expectedBaseline.repositoryPath.normalizedRelativePath() == normalizedDestinationPath,
          hasOnlyDestinationUpsert,
          actualDigest == ArticleDraft.repositoryDocumentDigest(intendedDocument)
        else {
          throw SiteDraftFileStoreError.projectFileChangedExternally(
            expectedBaseline.repositoryPath
          )
        }
        return true
      }

      if expectedBaseline.repositoryPath.normalizedRelativePath()
        == normalizedDestinationPath
      {
        return false
      }
    }

    // A first materialization or a path move must never replace an unrelated
    // file that appeared at the destination. The user can coordinate or
    // import that file first, establishing a new trusted binding.
    let destinationState = try previewBaselineState(
      for: normalizedDestinationPath,
      in: preview
    )
    guard destinationState == .missing else {
      throw SiteDraftFileStoreError.projectFileChangedExternally(
        normalizedDestinationPath
      )
    }
    return false
  }

  private func previewBaselineState(
    for repositoryPath: String,
    in preview: LocalPublishPreview
  ) throws -> LocalPublishFileState {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    guard
      let diff = preview.fileDiffs.first(where: {
        $0.path.normalizedRelativePath() == normalizedPath
      }),
      let baselineState = diff.baselineState
    else {
      throw LocalPublishPreviewError.invalidPreview(repositoryPath)
    }
    return baselineState
  }

  private func hexadecimalDigest(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
