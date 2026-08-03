import Foundation

public enum SiteDraftFileStoreError: LocalizedError, Equatable {
  case generalDraftCannotBeWritten

  public var errorDescription: String? {
    switch self {
    case .generalDraftCannotBeWritten:
      return CoreL10n.text("通用草稿只保存在软件中；请使用导出功能选择保存位置。")
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

  private let lock = NSLock()
  private let packageBuilder: PublishPackageBuilder
  private let previewService: LocalPublishPreviewService
  private var latestRepositoryPaths: [DraftSiteKey: String] = [:]

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

    lock.lock()
    defer { lock.unlock() }

    let key = DraftSiteKey(draftID: draft.id, profileID: profile.id)
    var preparedDraft = draft
    if let latestRepositoryPath = latestRepositoryPaths[key] {
      preparedDraft.repositoryPath = latestRepositoryPath
    }

    var package = packageBuilder.build(draft: preparedDraft, profile: profile)
    package.files = package.files.filter { $0.kind == .markdown }
    let writtenPaths = try previewService.write(package: package, profile: profile)
    latestRepositoryPaths[key] = package.markdownPath
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
}
