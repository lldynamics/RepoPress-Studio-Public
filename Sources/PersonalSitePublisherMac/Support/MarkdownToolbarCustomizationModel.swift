import Foundation
import SwiftUI

enum MarkdownToolbarItemID: String, CaseIterable, Codable, Identifiable {
  // Header Items
  case saveStatus
  case editorDisplayMode
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

  var id: String { rawValue }

  var title: String {
    switch self {
    case .saveStatus: return "保存状态"
    case .editorDisplayMode: return "视图模式"
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
    }
  }

  var systemImage: String {
    switch self {
    case .saveStatus: return "checkmark.circle"
    case .editorDisplayMode: return "chevron.left.forwardslash.chevron.right"
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

  var defaultCategory: MarkdownToolbarCategory {
    switch self {
    case .saveStatus, .editorDisplayMode, .writingToolDensity, .findReplace, .outline,
      .contextPanelMenu, .shortcutHelp, .exportMenu, .aiActions, .autoInlineAI,
      .aiChat, .localPreview, .preparePublish:
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
  var headerItemIDs: [MarkdownToolbarItemID]
  var formattingItemIDs: [MarkdownToolbarItemID]

  static var defaultConfiguration: MarkdownToolbarConfiguration {
    MarkdownToolbarConfiguration(
      headerItemIDs: [
        .saveStatus,
        .editorDisplayMode,
        .writingToolDensity,
        .findReplace,
        .outline,
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
        .heading1,
        .heading2,
        .heading3,
        .bold,
        .italic,
        .inlineCode,
        .blockquote,
        .codeBlock,
        .unorderedList,
        .orderedList,
        .taskList,
        .link,
        .image,
        .moreInsertions,
        .diagnostics,
      ]
    )
  }

  func encodeToJSON() -> String {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(self),
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
    return config
  }
}
