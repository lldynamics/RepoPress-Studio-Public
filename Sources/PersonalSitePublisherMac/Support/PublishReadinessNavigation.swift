import PublishingWorkbenchCore
import SwiftUI

enum PublishReadinessTarget: Equatable {
  case body(query: String?)
  case metadata(field: String?)
  case images(attachmentID: UUID?)
  case seo
  case repository

  static func preflight(_ issue: PreflightIssue) -> Self {
    field(issue.field, bodyQuery: issue.editorQuery)
  }

  static func image(_ issue: ImageWorkbenchIssue) -> Self {
    if let id = issue.attachmentID { return .images(attachmentID: id) }
    if issue.preflightIssue?.structuredField == .body {
      return .body(query: issue.relatedValue)
    }
    return .images(attachmentID: nil)
  }

  static func seo(_ finding: SEOAuditFinding) -> Self {
    guard finding.field != nil else { return .seo }
    return field(finding.field)
  }

  private static func field(_ field: String?, bodyQuery: String? = nil) -> Self {
    switch field.flatMap(PreflightIssueField.init(rawValue:)) {
    case .body: return .body(query: bodyQuery)
    case .attachments, .cover, .coverAlt: return .images(attachmentID: nil)
    case .repository, .repositoryPath, .repositoryToken, .contentRoot,
      .assetRoot, .markdownPathPattern, .siteKind:
      return .repository
    case .jsonLD: return .seo
    default: return .metadata(field: field)
    }
  }

  var title: String {
    switch self {
    case .body: String(localized: "定位正文")
    case .metadata: String(localized: "编辑元数据")
    case .images: String(localized: "查看图片")
    case .seo: String(localized: "打开 SEO 与社交预览")
    case .repository: String(localized: "打开项目配置")
    }
  }

  var inspectorTab: ArticleInspectorTab? {
    switch self {
    case .metadata: .metadata
    case .seo: .seo
    case .images: .images
    case .body, .repository: nil
    }
  }
}

struct PublishReadinessNavigationRequest: Equatable, Identifiable {
  let id = UUID()
  let draftID: UUID
  let target: PublishReadinessTarget
}

private struct PublishReadinessNavigationRequestKey: EnvironmentKey {
  static let defaultValue: PublishReadinessNavigationRequest? = nil
}

extension EnvironmentValues {
  var publishReadinessNavigationRequest: PublishReadinessNavigationRequest? {
    get { self[PublishReadinessNavigationRequestKey.self] }
    set { self[PublishReadinessNavigationRequestKey.self] = newValue }
  }
}

/// Only anchors that exist in the metadata form are returned.
enum PublishMetadataFieldAnchor {
  static func id(for field: String?) -> String {
    let supported = ["title", "slug", "summary", "tags", "date", "draft"]
    return "publish-metadata-" + (field.flatMap { supported.contains($0) ? $0 : nil } ?? "title")
  }
}
