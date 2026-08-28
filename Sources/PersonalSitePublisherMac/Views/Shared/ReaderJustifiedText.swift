import AppKit
import SwiftUI

/// A narrow TextKit bridge used only for justified reader paragraphs. SwiftUI
/// `Text` remains the default path; AppKit supplies the missing paragraph
/// alignment while SwiftUI continues to own all preference state.
struct ReaderJustifiedText: NSViewRepresentable {
  let markdown: String
  let fontFamily: ReaderFontFamily
  let fontSize: Double
  let fontWeight: NSFont.Weight
  let lineHeightMultiple: Double
  let foregroundColor: NSColor
  let highlightTerms: [String]

  func makeNSView(context: Context) -> ReaderIntrinsicTextView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    textContainer.widthTracksTextView = true
    textContainer.lineFragmentPadding = 0
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    let textView = ReaderIntrinsicTextView(frame: .zero, textContainer: textContainer)
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.textContainerInset = NSSize.zero
    textView.setContentCompressionResistancePriority(
      NSLayoutConstraint.Priority.defaultLow,
      for: NSLayoutConstraint.Orientation.horizontal
    )
    textView.setContentHuggingPriority(
      NSLayoutConstraint.Priority.defaultLow,
      for: NSLayoutConstraint.Orientation.horizontal
    )
    return textView
  }

  func updateNSView(_ textView: ReaderIntrinsicTextView, context: Context) {
    let token = configurationToken
    guard textView.configurationToken != token else { return }
    textView.configurationToken = token
    textView.textStorage?.setAttributedString(makeAttributedString())
    textView.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView textView: ReaderIntrinsicTextView,
    context: Context
  ) -> CGSize? {
    guard let proposedWidth = proposal.width, proposedWidth.isFinite else { return nil }
    let width = max(1, proposedWidth)
    guard let textContainer = textView.textContainer,
      let layoutManager = textView.layoutManager
    else {
      return CGSize(width: width, height: fontSize * lineHeightMultiple)
    }
    textContainer.containerSize = NSSize(
      width: width,
      height: CGFloat.greatestFiniteMagnitude
    )
    layoutManager.ensureLayout(for: textContainer)
    let usedHeight = layoutManager.usedRect(for: textContainer).height
    return CGSize(width: width, height: max(ceil(usedHeight), fontSize * lineHeightMultiple))
  }

  private var configurationToken: String {
    [
      markdown,
      fontFamily.rawValue,
      String(fontSize.bitPattern),
      String(describing: fontWeight.rawValue),
      String(lineHeightMultiple.bitPattern),
      foregroundColor.description,
      highlightTerms.joined(separator: "\u{001F}"),
    ].joined(separator: "\u{001E}")
  }

  func makeAttributedString() -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let parsed =
      (try? AttributedString(markdown: markdown, options: options))
      ?? AttributedString(markdown)
    let output = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    let fullRange = NSRange(location: 0, length: output.length)
    let baseFont = fontFamily.nsFont(size: fontSize, weight: fontWeight)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .justified
    paragraphStyle.baseWritingDirection = .natural
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.lineBreakStrategy = [.standard, .pushOut]
    paragraphStyle.lineHeightMultiple = max(
      ReaderTypographyConfiguration.lineSpacingRange.lowerBound,
      min(lineHeightMultiple, ReaderTypographyConfiguration.lineSpacingRange.upperBound)
    )
    paragraphStyle.hyphenationFactor = 0
    paragraphStyle.allowsDefaultTighteningForTruncation = false

    output.addAttributes(
      [
        .font: baseFont,
        .foregroundColor: foregroundColor,
        .paragraphStyle: paragraphStyle,
      ],
      range: fullRange
    )
    applyInlineTraits(to: output, baseFont: baseFont)
    applyHighlights(to: output)
    return output
  }

  private func applyInlineTraits(
    to output: NSMutableAttributedString,
    baseFont: NSFont
  ) {
    let fullRange = NSRange(location: 0, length: output.length)
    output.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
      let intent: InlinePresentationIntent?
      if let typedIntent = value as? InlinePresentationIntent {
        intent = typedIntent
      } else if let rawValue = value as? NSNumber {
        intent = InlinePresentationIntent(rawValue: rawValue.uintValue)
      } else {
        intent = nil
      }
      guard let intent else { return }
      if intent.contains(.code) {
        output.addAttributes(
          [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular),
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.10),
          ],
          range: range
        )
        return
      }
      var traits: NSFontDescriptor.SymbolicTraits = []
      if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
      if intent.contains(.emphasized) { traits.insert(.italic) }
      guard !traits.isEmpty else { return }
      let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
      output.addAttribute(
        .font,
        value: NSFont(descriptor: descriptor, size: fontSize) ?? baseFont,
        range: range
      )
    }
  }

  private func applyHighlights(to output: NSMutableAttributedString) {
    let source = output.string as NSString
    for rawTerm in highlightTerms {
      let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty else { continue }
      var searchRange = NSRange(location: 0, length: source.length)
      while searchRange.length > 0 {
        let match = source.range(
          of: term,
          options: [.caseInsensitive, .diacriticInsensitive],
          range: searchRange
        )
        guard match.location != NSNotFound else { break }
        output.addAttribute(
          .backgroundColor,
          value: NSColor.systemYellow.withAlphaComponent(0.26),
          range: match
        )
        let nextLocation = NSMaxRange(match)
        searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
      }
    }
  }
}

final class ReaderIntrinsicTextView: NSTextView {
  var configurationToken: String?

  override var intrinsicContentSize: NSSize {
    guard let textContainer, let layoutManager else { return super.intrinsicContentSize }
    layoutManager.ensureLayout(for: textContainer)
    return NSSize(
      width: NSView.noIntrinsicMetric,
      height: ceil(layoutManager.usedRect(for: textContainer).height)
    )
  }
}

extension ReaderFontFamily {
  func nsFont(size: Double, weight: NSFont.Weight = .regular) -> NSFont {
    let fallback = NSFont.systemFont(ofSize: size, weight: weight)
    let regularFont: NSFont
    switch self {
    case .system:
      return fallback
    case .newYork:
      regularFont =
        NSFont(name: "NewYork-Regular", size: size)
        ?? NSFont(name: "New York", size: size)
        ?? fallback
    case .songti:
      regularFont =
        NSFont(name: "Songti SC", size: size)
        ?? NSFont(name: "STSong", size: size)
        ?? fallback
    }
    guard weight >= .semibold else { return regularFont }
    return NSFontManager.shared.convert(regularFont, toHaveTrait: .boldFontMask)
  }
}
