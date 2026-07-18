import PublishingWorkbenchCore
import SwiftUI

extension KnowledgeSmartCollectionKind {
  var localizedDisplayName: String {
    switch self {
    case .author: String(localized: "作者")
    case .tag: String(localized: "标签")
    case .sourceDomain: String(localized: "来源域名")
    case .time: String(localized: "添加时间")
    case .aiPermission: String(localized: "AI 权限")
    }
  }

  var systemImage: String {
    switch self {
    case .author: "person.2"
    case .tag: "tag"
    case .sourceDomain: "globe"
    case .time: "calendar"
    case .aiPermission: "sparkles"
    }
  }
}

extension KnowledgeSmartCollectionRule {
  var localizedDisplayName: String {
    switch self {
    case .author(let value), .tag(let value), .sourceDomain(let value):
      value
    case .time(let bucket):
      bucket.localizedDisplayName
    case .aiPermission(true):
      String(localized: "允许 AI 使用")
    case .aiPermission(false):
      String(localized: "不允许 AI 使用")
    }
  }

  var systemImage: String {
    switch self {
    case .author: "person"
    case .tag: "tag"
    case .sourceDomain: "globe"
    case .time: "calendar"
    case .aiPermission(true): "sparkles"
    case .aiPermission(false): "sparkles.slash"
    }
  }
}

extension KnowledgeSmartTimeBucket {
  var localizedDisplayName: String {
    switch self {
    case .today: String(localized: "今天添加")
    case .thisWeek: String(localized: "本周添加")
    case .thisMonth: String(localized: "本月添加")
    case .earlier: String(localized: "更早添加")
    }
  }
}

extension KnowledgeRelatedChapterReason {
  var localizedDisplayName: String {
    switch self {
    case .sameDocument: String(localized: "同书章节")
    case .author(let value): String(format: String(localized: "同作者·%@"), value)
    case .tag(let value): String(format: String(localized: "共同标签·%@"), value)
    case .sourceDomain(let value): String(format: String(localized: "同来源·%@"), value)
    case .nearbyTime: String(localized: "同期添加")
    case .semantic: String(localized: "语义相关")
    }
  }
}
