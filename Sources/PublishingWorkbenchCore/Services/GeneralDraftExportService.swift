import Foundation

public enum GeneralDraftExportError: LocalizedError, Equatable {
  case requiresGeneralDraft

  public var errorDescription: String? {
    switch self {
    case .requiresGeneralDraft:
      return CoreL10n.text("只有通用草稿可以从软件资料库导出。")
    }
  }
}

public struct GeneralDraftExportDocument: Equatable, Sendable {
  public var suggestedFilename: String
  public var markdown: String

  public init(suggestedFilename: String, markdown: String) {
    self.suggestedFilename = suggestedFilename
    self.markdown = markdown
  }
}

public struct GeneralDraftExportService: Sendable {
  private let frontMatterRenderer: FrontMatterRenderer

  public init(frontMatterRenderer: FrontMatterRenderer = FrontMatterRenderer()) {
    self.frontMatterRenderer = frontMatterRenderer
  }

  public func document(
    for draft: ArticleDraft,
    profile: SiteProfile
  ) throws -> GeneralDraftExportDocument {
    guard draft.isGeneralDraft else {
      throw GeneralDraftExportError.requiresGeneralDraft
    }

    let filenameSource = draft.slug.nilIfEmpty ?? draft.title
    let safeFilename =
      SlugService.slug(from: filenameSource).nilIfEmpty
      ?? SlugService.fallbackSlug(date: draft.date)
    return GeneralDraftExportDocument(
      suggestedFilename: "\(safeFilename).md",
      markdown: frontMatterRenderer.renderDocument(draft: draft, profile: profile)
    )
  }
}
