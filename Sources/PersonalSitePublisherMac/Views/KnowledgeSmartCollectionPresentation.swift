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

extension KnowledgeSmartCollectionMatchMode {
  var localizedDisplayName: String {
    switch self {
    case .all: String(localized: "同时满足全部规则")
    case .any: String(localized: "满足任一规则")
    }
  }
}

extension KnowledgeSearchScope {
  var localizedDisplayName: String {
    switch self {
    case .currentCollection: String(localized: "当前集合")
    case .allLibrary: String(localized: "全部资料库")
    }
  }
}

extension KnowledgeSearchSignalFilter {
  var localizedDisplayName: String {
    switch self {
    case .all: String(localized: "全部命中")
    case .title: String(localized: "标题命中")
    case .fullText: String(localized: "全文命中")
    case .semantic: String(localized: "语义命中")
    }
  }
}

extension KnowledgeSearchResultSort {
  var localizedDisplayName: String {
    switch self {
    case .relevance: String(localized: "按相关度")
    case .addedNewest: String(localized: "按添加时间")
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
