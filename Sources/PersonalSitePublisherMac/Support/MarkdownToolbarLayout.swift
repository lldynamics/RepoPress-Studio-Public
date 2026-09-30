enum MarkdownToolbarFormattingItem: String, CaseIterable, Identifiable {
  case headingMenu
  case bold
  case italic
  case listMenu
  case link
  case image
  case insertMenu
  case formatMenu
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

  var id: String { rawValue }
}

enum MarkdownToolbarLayout {
  /// The one row shown at every width that fits it; narrower windows scroll
  /// the same items instead of switching to a different set.
  static let primaryFormattingItems: [MarkdownToolbarFormattingItem] = [
    .headingMenu,
    .bold,
    .italic,
    .listMenu,
    .link,
    .image,
    .insertMenu,
    .formatMenu,
  ]

  /// Block and media insertions, grouped behind “插入”.
  static let insertMenuItems: [MarkdownToolbarFormattingItem] = [
    .codeBlock,
    .table,
    .horizontalRule,
    .video,
    .internalLink,
    .snippets,
  ]

  /// Less common inline and paragraph formatting, grouped behind “格式”.
  static let formatMenuItems: [MarkdownToolbarFormattingItem] = [
    .inlineCode,
    .blockquote,
    .strikethrough,
    .chineseTypography,
  ]
}

enum MarkdownFormattingToolbarLayout {
  case automatic
  case compact
  case scrollable
}
