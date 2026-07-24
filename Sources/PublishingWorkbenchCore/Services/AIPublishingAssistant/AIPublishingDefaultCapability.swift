import Foundation

/// The small, stable set of AI choices shown at primary entry points.
///
/// The underlying action and prompt catalogs intentionally remain complete so
/// saved conversations and workflows keep decoding across app upgrades.
public enum AIPublishingDefaultCapability: String, CaseIterable, Identifiable, Sendable {
  case continueWriting
  case rewrite
  case condense
  case translate
  case generateMetadata
  case publishingCheck
  case citeKnowledge
  case askAnything

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .continueWriting: "续写"
    case .rewrite: "改写"
    case .condense: "压缩"
    case .translate: "翻译"
    case .generateMetadata: "生成元数据"
    case .publishingCheck: "发布检查"
    case .citeKnowledge: "引用资料"
    case .askAnything: "自由提问"
    }
  }

  public var systemImage: String {
    switch self {
    case .continueWriting: "text.append"
    case .rewrite: "wand.and.stars"
    case .condense: "arrow.down.right.and.arrow.up.left"
    case .translate: "character.book.closed"
    case .generateMetadata: "list.bullet.rectangle.portrait"
    case .publishingCheck: "checkmark.shield"
    case .citeKnowledge: "books.vertical"
    case .askAnything: "bubble.left.and.text.bubble.right"
    }
  }

  /// Direct editor actions represented by this capability. Free-form chat has
  /// no action kind because it opens the conversation input instead.
  public var actionKinds: [AIPublishingActionKind] {
    switch self {
    case .continueWriting: [.continueArticle]
    case .rewrite: [.rewriteSelection]
    case .condense: [.condenseSelection]
    case .translate: [.translateSelectionToChinese, .translateSelectionToEnglish]
    case .generateMetadata: [.draftFrontMatterPack]
    case .publishingCheck: [.publishingReadiness]
    case .citeKnowledge: [.draftReferencesSection]
    case .askAnything: []
    }
  }

  /// Chat shortcuts represented by this capability. Condensing is deliberately
  /// kept as a direct selection action and free-form chat needs no preset.
  public var quickPrompts: [AIPublishingQuickPrompt] {
    switch self {
    case .continueWriting: [.continueWriting]
    case .rewrite: [.tone]
    case .condense: []
    case .translate: [.translateChinese, .translateEnglish]
    case .generateMetadata: [.frontMatterPack]
    case .publishingCheck: [.publishReview]
    case .citeKnowledge: [.sourceChecklist]
    case .askAnything: []
    }
  }

  public static let defaultActionKinds = allCases.flatMap(\.actionKinds)
  public static let defaultQuickPrompts = allCases.flatMap(\.quickPrompts)
}
