import Foundation

public enum SiteDraftFileStoreError: LocalizedError, Equatable {
  case generalDraftCannotBeWritten
  case projectFileChangedExternally(String)

  public var errorDescription: String? {
    switch self {
    case .generalDraftCannotBeWritten:
      return CoreL10n.text("通用草稿只保存在软件中；请使用导出功能选择保存位置。")
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
  private var latestRepositoryBaselines: [DraftSiteKey: RepositoryFileBaseline] = [:]

  public init(
    packageBuilder: PublishPackageBuilder = PublishPackageBuilder(),
    previewService: LocalPublishPreviewService = LocalPublishPreviewService()
  ) {
    self.packageBuilder = packageBuilder
    self.previewService = previewService
  }

  public func write(
    draft: ArticleDraft,
    profile: SiteProfile
  ) throws -> SiteDraftFileWriteResult {
    guard !draft.isGeneralDraft else {
      throw SiteDraftFileStoreError.generalDraftCannotBeWritten
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
    let writtenPaths = isIdempotentWrite ? [] : try previewService.write(preview: preview, profile: profile)
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
