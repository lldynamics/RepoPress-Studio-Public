import Foundation

public enum SEOSocialPreviewCacheState: String, Codable, CaseIterable, Identifiable, Sendable {
  case missing
  case fresh
  case stale

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .missing: return "未生成快照"
    case .fresh: return "缓存可用"
    case .stale: return "缓存已过期"
    }
  }

  public var systemImage: String {
    switch self {
    case .missing: return "rectangle.on.rectangle.slash"
    case .fresh: return "checkmark.circle"
    case .stale: return "clock.badge.exclamationmark"
    }
  }
}

public struct SEOSocialPreviewCachePresentation: Codable, Hashable, Sendable {
  public var state: SEOSocialPreviewCacheState
  public var generatedAt: Date?
  public var message: String
  public var manualRefreshTitle: String

  public init(snapshot: SEOSocialPreviewSnapshot?, isStale: Bool) {
    if let snapshot {
      state = isStale ? .stale : .fresh
      generatedAt = snapshot.generatedAt
    } else {
      state = .missing
      generatedAt = nil
    }
    switch state {
    case .missing:
      message = "点击手动刷新生成搜索、Open Graph 和 Twitter/X 预览快照。"
      manualRefreshTitle = "生成快照"
    case .fresh:
      message = "正在使用缓存快照；只有明确刷新才会重新生成社交预览。"
      manualRefreshTitle = "手动刷新"
    case .stale:
      message = "当前显示的是上次缓存快照；复制发布包前请手动刷新。"
      manualRefreshTitle = "刷新过期快照"
    }
  }

  public var hasSnapshot: Bool { state != .missing }
  public var needsManualRefresh: Bool { state != .fresh }
}

/// Immutable, draft-scoped data consumed by the SEO Inspector. Expensive body
/// scans and cover metadata inspection are prepared away from SwiftUI's body.
public struct WorkbenchSEOInspectorPresentation: Sendable {
  public let draftID: UUID
  public let report: SEOAuditReport
  public let themeTitleH1Resolution: ThemeTitleH1Resolution
  public let socialPreviewSnapshot: SEOSocialPreviewSnapshot?
  public let cachePresentation: SEOSocialPreviewCachePresentation
  public let relatedArticleSuggestions: [SiteRelationSuggestion]
  public let actionMessage: String?

  public init(
    draftID: UUID,
    report: SEOAuditReport,
    themeTitleH1Resolution: ThemeTitleH1Resolution,
    socialPreviewSnapshot: SEOSocialPreviewSnapshot?,
    cachePresentation: SEOSocialPreviewCachePresentation,
    relatedArticleSuggestions: [SiteRelationSuggestion],
    actionMessage: String?
  ) {
    self.draftID = draftID
    self.report = report
    self.themeTitleH1Resolution = themeTitleH1Resolution
    self.socialPreviewSnapshot = socialPreviewSnapshot
    self.cachePresentation = cachePresentation
    self.relatedArticleSuggestions = relatedArticleSuggestions
    self.actionMessage = actionMessage
  }
}
