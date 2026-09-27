enum MarkdownToolbarFormattingItem: String, CaseIterable, Identifiable {
  case headingMenu
  case bold
  case italic
  case listMenu
  case link
  case image
  case moreFormatting
  case inlineCode
  case blockquote
  case codeBlock
  case strikethrough
  case table
  case horizontalRule
  case internalLink
  case snippets
  case video
  case chineseTypography
  case diagnostics

  var id: String { rawValue }
}

enum MarkdownToolbarLayout {
  /// Common commands remain directly available when the full row does not fit.
  static let primaryFormattingItems: [MarkdownToolbarFormattingItem] = [
    .headingMenu,
    .bold,
    .italic,
    .listMenu,
    .link,
    .image,
    .moreFormatting,
  ]

  /// These commands are inline when space allows and move into overflow together.
  static let moreFormattingItems: [MarkdownToolbarFormattingItem] = [
    .inlineCode,
    .blockquote,
    .codeBlock,
    .strikethrough,
    .table,
    .horizontalRule,
    .internalLink,
    .snippets,
    .video,
    .chineseTypography,
    .diagnostics,
  ]

  static let expandedFormattingItems =
    primaryFormattingItems.filter { $0 != .moreFormatting } + moreFormattingItems
}

enum MarkdownFormattingToolbarLayout {
  case automatic
  case expanded
  case compact
  case scrollable
}
