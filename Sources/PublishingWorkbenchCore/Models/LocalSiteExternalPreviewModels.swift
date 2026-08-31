import Foundation

/// A frozen hand-off between editor persistence and the browser-preview flow.
///
/// The URLs are derived only after the latest editor buffer has been written
/// to the configured project, so callers never need to infer a route from the
/// currently selected draft.
public struct LocalSiteExternalPreviewPreparation: Equatable, Sendable {
  public let draftID: UUID
  public let profileID: UUID
  public let bodyRevision: UInt64
  public let siteURL: URL
  public let articleURL: URL

  public init(
    draftID: UUID,
    profileID: UUID,
    bodyRevision: UInt64,
    siteURL: URL,
    articleURL: URL
  ) {
    self.draftID = draftID
    self.profileID = profileID
    self.bodyRevision = bodyRevision
    self.siteURL = siteURL
    self.articleURL = articleURL
  }
}

public enum LocalSiteExternalPreviewPreparationError: LocalizedError, Equatable, Sendable {
  case draftNotFound
  case generalDraftRequiresProject
  case draftNotAddedToProject
  case inactiveSite
  case projectSaveFailed(String)
  case previewUnavailable

  public var errorDescription: String? {
    switch self {
    case .draftNotFound:
      return CoreL10n.text("找不到要预览的文章。")
    case .generalDraftRequiresProject:
      return CoreL10n.text("通用草稿尚未属于站点；请先将它加入项目再预览。")
    case .draftNotAddedToProject:
      return CoreL10n.text("这篇草稿尚未加入项目；写入项目后才能在浏览器预览。")
    case .inactiveSite:
      return CoreL10n.text("这篇草稿不属于当前站点；请先切换到它所属的站点。")
    case .projectSaveFailed(let message):
      return CoreL10n.format("打开预览前写入项目失败：%@", message)
    case .previewUnavailable:
      return CoreL10n.text("当前站点没有可用的本地预览地址；请先检查项目与预览配置。")
    }
  }
}
