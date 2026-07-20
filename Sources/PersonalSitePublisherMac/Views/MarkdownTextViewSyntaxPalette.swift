import AppKit
import PublishingWorkbenchCore

@MainActor
struct MarkdownTextViewSyntaxPalette {
  let fontSize: Double
  let lineSpacing: Double
  let baseFont: NSFont
  let defaultAttributes: [NSAttributedString.Key: Any]
  let styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]

  init(configuration: MarkdownEditorComfortConfiguration) {
    fontSize = configuration.fontSize
    lineSpacing = configuration.lineSpacing
    let baseFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(configuration.fontSize),
      weight: .regular
    )
    let codeFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(configuration.fontSize),
      weight: .medium
    )
    let emphasizedFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(configuration.fontSize),
      weight: .semibold
    )
    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = CGFloat(configuration.lineSpacing)

    self.baseFont = baseFont
    defaultAttributes = [
      .font: baseFont,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]
    styleAttributes = [
      .heading: [
        .foregroundColor: WorkbenchThemeNSColor.primary,
        .font: emphasizedFont
      ],
      .codeBlock: [
        .font: codeFont,
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.18)
      ],
      .link: [
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.linkColor
      ],
      .list: [
        .foregroundColor: WorkbenchThemeNSColor.success
      ],
      .quote: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.08)
      ],
      .bold: [
        .font: emphasizedFont
      ],
      .italic: [
        .font: italicFont
      ],
      .inlineCode: [
        .font: codeFont,
        .foregroundColor: WorkbenchThemeNSColor.warning
      ]
    ]
  }

  func matches(_ configuration: MarkdownEditorComfortConfiguration) -> Bool {
    fontSize == configuration.fontSize && lineSpacing == configuration.lineSpacing
  }
}
