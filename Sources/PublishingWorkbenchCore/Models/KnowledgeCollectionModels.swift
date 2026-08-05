import Foundation

import Foundation

public enum KnowledgeDocumentKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case article
  case book
  case webpage
  case pdf
  case markdown
  case text
  case note
  case other

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .article: "文章"
    case .book: "书籍"
    case .webpage: "网页"
    case .pdf: "PDF"
    case .markdown: "Markdown"
    case .text: "文本"
    case .note: "笔记"
    case .other: "其他"
    }
  }

  public var systemImage: String {
    switch self {
    case .article: "doc.text"
    case .book: "books.vertical"
    case .webpage: "globe"
    case .pdf: "doc.richtext"
    case .markdown: "text.document"
    case .text: "doc.plaintext"
    case .note: "note.text"
    case .other: "archivebox"
    }
  }
}
public enum KnowledgeImportDisposition: String, Codable, Sendable {
  case new
  case update
  case duplicate

  public var displayName: String {
    switch self {
    case .new: "新增"
    case .update: "更新"
    case .duplicate: "重复"
    }
  }
}

public enum KnowledgeRetrievalPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
  case off
  case automatic
  case pinnedOnly

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .off: "关闭资料库"
    case .automatic: "自动检索"
    case .pinnedOnly: "仅固定资料"
    }
  }

  public var detail: String {
    switch self {
    case .off: "本轮对话不读取资料库。"
    case .automatic: "根据当前文章和问题自动寻找相关片段。"
    case .pinnedOnly: "只使用你为当前对话固定的资料。"
    }
  }
}

public struct KnowledgeFolder: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum KnowledgeFolderScope: Hashable, Sendable {
  case all
  case unfiled
  case folder(UUID)
  case smartCollection(KnowledgeSmartCollectionRule)
  case savedCollection(KnowledgeSavedCollection)
}

public enum KnowledgeSmartCollectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case author
  case tag
  case sourceDomain
  case time
  case aiPermission

  public var id: String { rawValue }
}

public enum KnowledgeSmartTimeBucket: String, Codable, CaseIterable, Identifiable, Sendable {
  case today
  case thisWeek
  case thisMonth
  case earlier

  public var id: String { rawValue }
}

public enum KnowledgeSmartCollectionRule: Codable, Hashable, Sendable {
  case author(String)
  case tag(String)
  case sourceDomain(String)
  case time(KnowledgeSmartTimeBucket)
  case aiPermission(Bool)

  public var kind: KnowledgeSmartCollectionKind {
    switch self {
    case .author: .author
    case .tag: .tag
    case .sourceDomain: .sourceDomain
    case .time: .time
    case .aiPermission: .aiPermission
    }
  }

  public var id: String {
    switch self {
    case .author(let value): "author:\(value.lowercased())"
    case .tag(let value): "tag:\(value.lowercased())"
    case .sourceDomain(let value): "domain:\(value.lowercased())"
    case .time(let value): "time:\(value.rawValue)"
    case .aiPermission(let value): "ai:\(value)"
    }
  }
}

public enum KnowledgeSmartCollectionMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case all
  case any

  public var id: String { rawValue }
}

public struct KnowledgeSavedCollection: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var rules: [KnowledgeSmartCollectionRule]
  public var matchMode: KnowledgeSmartCollectionMatchMode
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    rules: [KnowledgeSmartCollectionRule],
    matchMode: KnowledgeSmartCollectionMatchMode = .all,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    var seen = Set<String>()
    self.rules = rules.filter { seen.insert($0.id).inserted }
    self.matchMode = matchMode
    self.createdAt = createdAt
  }
}

public struct KnowledgeSmartCollection: Identifiable, Hashable, Sendable {
  public var id: String { rule.id }
  public var rule: KnowledgeSmartCollectionRule
  public var documentCount: Int

  public init(rule: KnowledgeSmartCollectionRule, documentCount: Int) {
    self.rule = rule
    self.documentCount = max(0, documentCount)
  }
}

public enum KnowledgeDocumentSortField: String, CaseIterable, Identifiable, Sendable {
  case title
  case kind
  case fileSize
  case addedAt
  case updatedAt

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .title: "标题"
    case .kind: "类型"
    case .fileSize: "文件大小"
    case .addedAt: "添加时间"
    case .updatedAt: "更新时间"
    }
  }
}

public enum KnowledgeSortDirection: String, CaseIterable, Identifiable, Sendable {
  case ascending
  case descending

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .ascending: "升序"
    case .descending: "降序"
    }
  }

  public var systemImage: String {
    switch self {
    case .ascending: "arrow.up"
    case .descending: "arrow.down"
    }
  }
}

public struct KnowledgeDocumentSort: Hashable, Sendable {
  public var field: KnowledgeDocumentSortField
  public var direction: KnowledgeSortDirection

  public init(
    field: KnowledgeDocumentSortField = .addedAt,
    direction: KnowledgeSortDirection = .descending
  ) {
    self.field = field
    self.direction = direction
  }

  public func sorted(_ documents: [KnowledgeDocument]) -> [KnowledgeDocument] {
    documents.sorted { lhs, rhs in
      let comparison = primaryComparison(lhs, rhs)
      if comparison != .orderedSame {
        return direction == .ascending
          ? comparison == .orderedAscending
          : comparison == .orderedDescending
      }
      let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
      if titleComparison != .orderedSame {
        return titleComparison == .orderedAscending
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func primaryComparison(_ lhs: KnowledgeDocument, _ rhs: KnowledgeDocument) -> ComparisonResult {
    switch field {
    case .title:
      return lhs.title.localizedStandardCompare(rhs.title)
    case .kind:
      return lhs.kind.displayName.localizedStandardCompare(rhs.kind.displayName)
    case .fileSize:
      return compare(lhs.sourceByteCount, rhs.sourceByteCount)
    case .addedAt:
      return compare(lhs.importedAt, rhs.importedAt)
    case .updatedAt:
      return compare(lhs.updatedAt, rhs.updatedAt)
    }
  }

  private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    if lhs < rhs { return .orderedAscending }
    if lhs > rhs { return .orderedDescending }
    return .orderedSame
  }
}

public enum KnowledgeSearchScope: String, CaseIterable, Identifiable, Sendable {
  case currentCollection
  case allLibrary

  public var id: String { rawValue }
}

public enum KnowledgeSearchSignalFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case title
  case fullText
  case semantic

  public var id: String { rawValue }

  public var signal: KnowledgeRetrievalSignal? {
    switch self {
    case .all: nil
    case .title: .title
    case .fullText: .fullText
    case .semantic: .semantic
    }
  }
}

public enum KnowledgeSearchResultSort: String, CaseIterable, Identifiable, Sendable {
  case relevance
  case addedNewest

  public var id: String { rawValue }
}

public struct KnowledgeSearchFilter: Hashable, Sendable {
  public var scope: KnowledgeSearchScope
  public var signal: KnowledgeSearchSignalFilter
  public var sort: KnowledgeSearchResultSort

  public init(
    scope: KnowledgeSearchScope = .currentCollection,
    signal: KnowledgeSearchSignalFilter = .all,
    sort: KnowledgeSearchResultSort = .relevance
  ) {
    self.scope = scope
    self.signal = signal
    self.sort = sort
  }

  public func filtered(
    _ results: [KnowledgeSearchResult],
    isInCurrentCollection: (KnowledgeDocument) -> Bool
  ) -> [KnowledgeSearchResult] {
    let scoped = results.filter { result in
      (scope == .allLibrary || isInCurrentCollection(result.document))
        && (signal.signal.map(result.signals.contains) ?? true)
    }
    switch sort {
    case .relevance:
      return scoped
    case .addedNewest:
      return scoped.sorted {
        if $0.document.importedAt != $1.document.importedAt {
          return $0.document.importedAt > $1.document.importedAt
        }
        if $0.document.id != $1.document.id {
          return $0.document.title.localizedStandardCompare($1.document.title) == .orderedAscending
        }
        return $0.chunk.ordinal < $1.chunk.ordinal
      }
    }
  }
}
