import AppKit
import PublishingWorkbenchCore

@MainActor
struct MarkdownTextViewSyntaxPalette {
  let fontSize: Double
  let lineSpacing: Double
  let baseFont: NSFont
  let defaultAttributes: [NSAttributedString.Key: Any]
  let styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  let inactiveMarkerAttributes: [NSAttributedString.Key: Any]
  let inactiveMarkerLayoutFont: NSFont
  let inactiveTaskMarkerLayoutFont: NSFont

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
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = CGFloat(configuration.lineSpacing)

    func headingAttributes(
      scale: CGFloat,
      weight: NSFont.Weight,
      spacingBefore: CGFloat,
      spacingAfter: CGFloat
    ) -> [NSAttributedString.Key: Any] {
      let headingParagraphStyle: NSMutableParagraphStyle
      if let mutableCopy = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle {
        headingParagraphStyle = mutableCopy
      } else {
        headingParagraphStyle = NSMutableParagraphStyle()
        headingParagraphStyle.setParagraphStyle(paragraphStyle)
      }
      headingParagraphStyle.paragraphSpacingBefore = spacingBefore
      headingParagraphStyle.paragraphSpacing = spacingAfter
      return [
        .foregroundColor: WorkbenchThemeNSColor.primary,
        .font: NSFont.systemFont(
          ofSize: CGFloat(configuration.fontSize) * scale,
          weight: weight
        ),
        .paragraphStyle: headingParagraphStyle,
      ]
    }

    self.baseFont = baseFont
    defaultAttributes = [
      .font: baseFont,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle,
    ]
    inactiveMarkerAttributes = [
      .foregroundColor: NSColor.clear,
      .underlineColor: NSColor.clear,
    ]
    inactiveMarkerLayoutFont = NSFont.systemFont(ofSize: 0.01)
    inactiveTaskMarkerLayoutFont = NSFont.systemFont(ofSize: 3.5)
    styleAttributes = [
      .heading: [
        .foregroundColor: WorkbenchThemeNSColor.primary,
        .font: emphasizedFont,
      ],
      .heading1: headingAttributes(
        scale: 1.70, weight: .bold, spacingBefore: 14, spacingAfter: 7),
      .heading2: headingAttributes(
        scale: 1.45, weight: .bold, spacingBefore: 12, spacingAfter: 6),
      .heading3: headingAttributes(
        scale: 1.25, weight: .semibold, spacingBefore: 10, spacingAfter: 5),
      .heading4: headingAttributes(
        scale: 1.12, weight: .semibold, spacingBefore: 8, spacingAfter: 4),
      .heading5: headingAttributes(
        scale: 1.04, weight: .semibold, spacingBefore: 6, spacingAfter: 3),
      .heading6: headingAttributes(
        scale: 1.0, weight: .semibold, spacingBefore: 5, spacingAfter: 3),
      .codeBlock: [
        .font: codeFont,
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.18),
      ],
      .link: [
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.linkColor,
      ],
      .list: [
        .foregroundColor: WorkbenchThemeNSColor.success
      ],
      .quote: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.08),
      ],
      // Font traits are composed by MarkdownTextViewSemanticAttributeApplier
      // so nested emphasis preserves heading and code font sizes.
      .bold: [:],
      .italic: [:],
      .strikethrough: [
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .strikethroughColor: NSColor.secondaryLabelColor,
      ],
      .inlineCode: [
        .font: codeFont,
        .foregroundColor: WorkbenchThemeNSColor.warning,
      ],
      .html: [
        .font: codeFont,
        .foregroundColor: NSColor.systemPurple,
      ],
    ]
  }

  func matches(_ configuration: MarkdownEditorComfortConfiguration) -> Bool {
    fontSize == configuration.fontSize && lineSpacing == configuration.lineSpacing
  }
}
