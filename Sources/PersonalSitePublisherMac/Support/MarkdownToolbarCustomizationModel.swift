import Foundation
import SwiftUI

enum MarkdownToolbarItemID: String, CaseIterable, Codable, Hashable, Identifiable {
  // Header Items
  case saveStatus
  case writingToolDensity
  case findReplace
  case outline
  case contextPanelMenu
  case shortcutHelp
  case exportMenu
  case aiActions
  case autoInlineAI
  case aiChat
  case localPreview
  case preparePublish

  // Formatting Items
  case headingMenu
  case listMenu
  case heading1
  case heading2
  case heading3
  case bold
  case italic
  case inlineCode
  case blockquote
  case codeBlock
  case unorderedList
  case orderedList
  case taskList
  case link
  case image
  case moreInsertions
  case diagnostics
  case formatChineseTypography
  case copyRichText

  var id: String { rawValue }

  var title: String {
    switch self {
    case .saveStatus: return "保存状态"
    case .writingToolDensity: return "工具密度"
    case .findReplace: return "查找与替换"
    case .outline: return "文章大纲"
    case .contextPanelMenu: return "上下文面板"
    case .shortcutHelp: return "快捷键说明"
    case .exportMenu: return "导出文章"
    case .aiActions: return "AI 常用操作"
    case .autoInlineAI: return "自动 AI 续写"
    case .aiChat: return "AI 对话"
    case .localPreview: return "本地站点预览"
    case .preparePublish: return "准备发布"
    case .copyRichText: return "公众号/知乎复制"

    case .headingMenu: return "标题"
    case .listMenu: return "列表"
    case .heading1: return "一级标题"
    case .heading2: return "二级标题"
    case .heading3: return "三级标题"
    case .bold: return "粗体"
    case .italic: return "斜体"
    case .inlineCode: return "行内代码"
    case .blockquote: return "引用"
    case .codeBlock: return "代码块"
    case .unorderedList: return "无序列表"
    case .orderedList: return "有序列表"
    case .taskList: return "任务列表"
    case .link: return "链接"
    case .image: return "插图"
    case .moreInsertions: return "更多插入选项"
    case .diagnostics: return "正文诊断"
    case .formatChineseTypography: return "中英文排版"
    }
  }

  var systemImage: String {
    switch self {
    case .saveStatus: return "checkmark.circle"
    case .writingToolDensity: return "slider.horizontal.3"
    case .findReplace: return "magnifyingglass"
    case .outline: return "list.bullet.indent"
    case .contextPanelMenu: return "sidebar.right"
    case .shortcutHelp: return "keyboard"
    case .exportMenu: return "square.and.arrow.up"
    case .aiActions: return "sparkles"
    case .autoInlineAI: return "wand.and.stars"
    case .aiChat: return "sparkles"
    case .localPreview: return "play.rectangle"
    case .preparePublish: return "paperplane"
    case .copyRichText: return "doc.on.doc.fill"

    case .headingMenu: return "textformat.size"
    case .listMenu: return "list.bullet"
    case .heading1: return "textformat.size"
    case .heading2: return "textformat.size"
    case .heading3: return "textformat.size"
    case .bold: return "bold"
    case .italic: return "italic"
    case .inlineCode: return "chevron.left.forwardslash.chevron.right"
    case .blockquote: return "text.quote"
    case .codeBlock: return "curlybraces.square"
    case .unorderedList: return "list.bullet"
    case .orderedList: return "list.number"
    case .taskList: return "checklist"
    case .link: return "link"
    case .image: return "photo"
    case .moreInsertions: return "ellipsis.circle"
    case .diagnostics: return "waveform.badge.exclamationmark"
    case .formatChineseTypography: return "textformat"
    }
  }

  var isMandatory: Bool {
    switch self {
    case .saveStatus, .preparePublish:
      return true
    default:
      return false
    }
  }

  /// 是否属于 AI 工具组。
  /// 工具栏会在此组第一项之前自动插入分隔线。
  var isAIGroupItem: Bool {
    switch self {
    case .aiActions, .autoInlineAI, .aiChat:
      return true
    default:
      return false
    }
  }

  /// 资源不足时的折叠优先级。
  /// 数字越小越优先保留，同级内依用户排序保留。
  var collapseOrder: Int {
    switch self {
    case .saveStatus: return 0  // 常驻，不参与折叠
    case .preparePublish: return 0  // 常驻，不参与折叠
    case .aiChat: return 2  // AI 对话，核心入口
    case .autoInlineAI: return 3
    case .findReplace: return 4
    case .aiActions: return 5
    case .writingToolDensity: return 6
    case .contextPanelMenu: return 7
    case .localPreview: return 8
    case .exportMenu: return 9
    case .outline: return 10
    case .shortcutHelp: return 11
    case .copyRichText: return 12
    default: return 99
    }
  }

  var defaultCategory: MarkdownToolbarCategory {
    switch self {
    case .saveStatus, .writingToolDensity, .findReplace, .outline,
      .contextPanelMenu, .shortcutHelp, .exportMenu, .aiActions, .autoInlineAI,
      .aiChat, .localPreview, .preparePublish, .copyRichText:
      return .header
    default:
      return .formatting
    }
  }
}

enum MarkdownToolbarCategory: String, Codable {
  case header
  case formatting
}

struct MarkdownToolbarConfiguration: Codable, Equatable {
  static let currentSchemaVersion = 1

  /// A versioned, normalized representation of the user's toolbar choices.
  ///
  /// The property is intentionally encoded alongside the two item lists so a
  /// future migration can distinguish the legacy (unversioned) payload from a
  /// payload written by the current app.
  var schemaVersion: Int
  var headerItemIDs: [MarkdownToolbarItemID]
  var formattingItemIDs: [MarkdownToolbarItemID]

  static var defaultConfiguration: MarkdownToolbarConfiguration {
    MarkdownToolbarConfiguration(
      schemaVersion: currentSchemaVersion,
      headerItemIDs: [
        .saveStatus,
        .writingToolDensity,
        .findReplace,
        .contextPanelMenu,
        .shortcutHelp,
        .exportMenu,
        .aiActions,
        .autoInlineAI,
        .aiChat,
        .localPreview,
        .preparePublish,
      ],
      formattingItemIDs: [
        .headingMenu,
        .bold,
        .italic,
        .inlineCode,
        .blockquote,
        .codeBlock,
        .listMenu,
        .link,
        .image,
        .formatChineseTypography,
        .moreInsertions,
        .diagnostics,
      ]
    )
  }

  init(
    schemaVersion: Int = currentSchemaVersion,
    headerItemIDs: [MarkdownToolbarItemID],
    formattingItemIDs: [MarkdownToolbarItemID]
  ) {
    self.schemaVersion = schemaVersion
    self.headerItemIDs = headerItemIDs
    self.formattingItemIDs = formattingItemIDs
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case headerItemIDs
    case formattingItemIDs
  }

  /// Raw identifiers retired by the native editor migration. They are
  /// filtered explicitly so an old persisted toolbar remains decodable even
  /// though the corresponding enum case no longer exists.
  private static let removedLegacyItemRawValues: Set<String> = [
    "editorDisplayMode"
  ]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0

    // Decode item IDs as strings instead of [MarkdownToolbarItemID]. This
    // lets a newer app safely ignore an item added by a future version while
    // preserving all known optional items the user intentionally hid.
    let defaultConfiguration = Self.defaultConfiguration
    let headerRawValues =
      try container.decodeIfPresent([String].self, forKey: .headerItemIDs)
      ?? defaultConfiguration.headerItemIDs.map(\.rawValue)
    let formattingRawValues =
      try container.decodeIfPresent([String].self, forKey: .formattingItemIDs)
      ?? defaultConfiguration.formattingItemIDs.map(\.rawValue)

    let headerItems = headerRawValues
      .filter { !Self.removedLegacyItemRawValues.contains($0) }
      .compactMap(MarkdownToolbarItemID.init(rawValue:))
    let formattingItems = formattingRawValues
      .filter { !Self.removedLegacyItemRawValues.contains($0) }
      .compactMap(MarkdownToolbarItemID.init(rawValue:))

    self =
      MarkdownToolbarConfiguration(
        schemaVersion: version,
        headerItemIDs: headerItems,
        formattingItemIDs: formattingItems
      ).normalized
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let configuration = normalized
    try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    try container.encode(configuration.headerItemIDs.map(\.rawValue), forKey: .headerItemIDs)
    try container.encode(
      configuration.formattingItemIDs.map(\.rawValue), forKey: .formattingItemIDs)
  }

  /// Returns a canonical configuration while preserving the user's order.
  ///
  /// IDs belonging to the other category, duplicate IDs, and IDs that cannot
  /// be represented by this version are removed. Mandatory header controls are
  /// restored in their canonical category if a damaged or old payload omitted
  /// them.
  var normalized: MarkdownToolbarConfiguration {
    func normalize(
      _ items: [MarkdownToolbarItemID],
      category: MarkdownToolbarCategory
    ) -> [MarkdownToolbarItemID] {
      var seen = Set<MarkdownToolbarItemID>()
      var result: [MarkdownToolbarItemID] = []
      for item in items where item.defaultCategory == category {
        if item.isMandatory {
          continue
        }
        guard seen.insert(item).inserted else { continue }
        result.append(item)
      }

      let mandatoryItems = MarkdownToolbarItemID.allCases.filter {
        $0.isMandatory && $0.defaultCategory == category
      }
      guard !mandatoryItems.isEmpty else { return result }

      // Mandatory controls are stable anchors: save status stays first and
      // prepare-publish stays last, while optional controls retain their
      // persisted relative order between those anchors.
      return mandatoryItems.reduce(into: result) { normalized, mandatoryItem in
        if mandatoryItem == .saveStatus {
          normalized.insert(mandatoryItem, at: 0)
        } else if mandatoryItem == .preparePublish {
          normalized.append(mandatoryItem)
        } else if !normalized.contains(mandatoryItem) {
          normalized.append(mandatoryItem)
        }
      }
    }

    return MarkdownToolbarConfiguration(
      schemaVersion: Self.currentSchemaVersion,
      headerItemIDs: normalize(headerItemIDs, category: .header),
      formattingItemIDs: normalize(formattingItemIDs, category: .formatting)
    )
  }

  func encodeToJSON() -> String {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(normalized),
      let string = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return string
  }

  static func decodeFromJSON(_ jsonString: String) -> MarkdownToolbarConfiguration {
    guard !jsonString.isEmpty,
      let data = jsonString.data(using: .utf8),
      let config = try? JSONDecoder().decode(MarkdownToolbarConfiguration.self, from: data)
    else {
      return .defaultConfiguration
    }
    return config.normalized
  }
}
