import AppKit
import Foundation
import PublishingWorkbenchCore

/// Builds the derived, read-only TextKit 2 document used while an editor is
/// not focused.
///
/// The editable Markdown string remains authoritative. This factory parses
/// only `bodyMarkdown`, resolves its ranges back into `fullSource` using
/// UTF-16 offsets, and returns native attachment entries for a derived
/// presentation document. It never edits the source and it never decodes an
/// image synchronously.
@MainActor
enum MarkdownTextKit2ReadOnlyPresentationFactory {
  struct ImageLoadRequest {
    let sourceURL: URL
    let sourceRange: NSRange
    let attachment: MarkdownNativeTextAttachment

    init(
      sourceURL: URL,
      sourceRange: NSRange,
      attachment: MarkdownNativeTextAttachment
    ) {
      self.sourceURL = sourceURL
      self.sourceRange = sourceRange
      self.attachment = attachment
    }
  }

  struct Output {
    /// The exact full Markdown source used to create `document`.
    let source: String

    /// Only parser items that have a native presentation are included here.
    /// In particular, an image without a matching local `sourceFilePath` is
    /// left as ordinary Markdown source.
    let entries: [MarkdownTextKit2PresentationDocument.Entry]

    /// Image decoding belongs to the caller's asynchronous loading task. The
    /// request carries the stable native attachment identity that task must
    /// update after decoding.
    let imageLoads: [ImageLoadRequest]

    /// A complete derived TextKit 2 document, retained so callers do not
    /// accidentally rebuild the projection while installing the read-only
    /// presentation.
    let document: MarkdownTextKit2PresentationDocument
  }

  /// Builds a source-preserving presentation from a full document and its
  /// body slice. `bodyUTF16Offset` is an AppKit/NSString offset in `fullSource`.
  /// Front Matter is excluded because the attachment plan is computed only
  /// from `bodyMarkdown`.
  static func make(
    fullSource: String,
    bodyMarkdown: String,
    bodyUTF16Offset: Int,
    attachments: [DraftAttachment],
    availableWidth: CGFloat,
    baseFontSize: CGFloat
  ) -> Output {
    let safeSourceRange = Self.validatedBodyRange(
      fullSource: fullSource,
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset
    )

    guard let safeSourceRange else {
      return Output(
        source: fullSource,
        entries: [],
        imageLoads: [],
        document: MarkdownTextKit2PresentationDocument(source: fullSource)
      )
    }

    // The plan is intentionally computed exactly once. It scans body Markdown
    // (and therefore cannot mistake a Front Matter image for an inline one).
    let plan = MarkdownInlineAttachmentPlanService.plan(in: bodyMarkdown)
    let attachmentLookup = Self.makeAttachmentLookup(from: attachments)
    let width = Self.safeWidth(availableWidth)
    let fontSize = Self.safeFontSize(baseFontSize)

    var entries: [MarkdownTextKit2PresentationDocument.Entry] = []
    var imageLoads: [ImageLoadRequest] = []
    entries.reserveCapacity(plan.items.count)
    imageLoads.reserveCapacity(plan.items.count)

    let bodyLength = (bodyMarkdown as NSString).length
    let fullLength = (fullSource as NSString).length
    for item in plan.items {
      guard Self.isSafeBodyRange(
        item.range,
        bodyLength: bodyLength
      ) else {
        continue
      }

      let fullRange = NSRange(
        location: bodyUTF16Offset + item.range.location,
        length: item.range.length
      )
      guard Self.isSafeRange(fullRange, length: fullLength) else {
        continue
      }

      switch item.kind {
      case .image(let reference, let altText):
        guard
          let draftAttachment = Self.matchingAttachment(
            for: reference,
            in: attachmentLookup
          ),
          let sourcePath = Self.nonEmptyPath(draftAttachment.sourceFilePath)
        else {
          // Keep unmatched images as ordinary source text. A native image
          // attachment without a local source path cannot be loaded safely.
          continue
        }

        let accessibilityText =
          Self.nonEmptyPath(altText)
          ?? Self.nonEmptyPath(draftAttachment.altText)
          ?? Self.nonEmptyPath(draftAttachment.originalFilename)
          ?? "图片"
        let bounds = Self.imageBounds(width: width)
        let nativeAttachment = MarkdownNativeTextAttachment(
          content: .image(accessibilityText: accessibilityText),
          bounds: bounds
        )
        entries.append(
          .init(
            sourceRange: fullRange,
            kind: item.kind,
            attachment: nativeAttachment
          )
        )
        imageLoads.append(
          ImageLoadRequest(
            sourceURL: URL(fileURLWithPath: sourcePath).standardizedFileURL,
            sourceRange: fullRange,
            attachment: nativeAttachment
          )
        )

      case .formula(let source, let displayMode):
        let nativeAttachment = Self.makeFormulaAttachment(
          source: source,
          displayMode: displayMode,
          availableWidth: width,
          baseFontSize: fontSize
        )
        entries.append(
          .init(
            sourceRange: fullRange,
            kind: item.kind,
            attachment: nativeAttachment
          )
        )
      }
    }

    let document = MarkdownTextKit2PresentationDocument(
      source: fullSource,
      entries: entries
    )
    // `safeSourceRange` is intentionally retained above as a validated body
    // boundary. Keeping the local binding also makes it explicit that all
    // output ranges were checked against the same full-source slice.
    _ = safeSourceRange
    return Output(
      source: fullSource,
      entries: entries,
      imageLoads: imageLoads,
      document: document
    )
  }

  /// Convenience overload for callers resolving one attachment at a time.
  static func make(
    fullSource: String,
    bodyMarkdown: String,
    bodyUTF16Offset: Int,
    attachment: DraftAttachment,
    availableWidth: CGFloat,
    baseFontSize: CGFloat
  ) -> Output {
    make(
      fullSource: fullSource,
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      attachments: [attachment],
      availableWidth: availableWidth,
      baseFontSize: baseFontSize
    )
  }

  private static func validatedBodyRange(
    fullSource: String,
    bodyMarkdown: String,
    bodyUTF16Offset: Int
  ) -> NSRange? {
    let fullLength = (fullSource as NSString).length
    let bodyLength = (bodyMarkdown as NSString).length
    guard bodyUTF16Offset >= 0,
      bodyUTF16Offset <= fullLength,
      bodyLength <= fullLength - bodyUTF16Offset
    else {
      return nil
    }

    let range = NSRange(location: bodyUTF16Offset, length: bodyLength)
    guard (fullSource as NSString).substring(with: range) == bodyMarkdown else {
      return nil
    }
    return range
  }

  private static func isSafeBodyRange(
    _ range: NSRange,
    bodyLength: Int
  ) -> Bool {
    isSafeRange(range, length: bodyLength)
      && range.length > 0
  }

  private static func isSafeRange(_ range: NSRange, length: Int) -> Bool {
    guard range.location != NSNotFound,
      range.location >= 0,
      range.length >= 0,
      range.location <= length
    else {
      return false
    }
    return range.length <= length - range.location
  }

  private static func safeWidth(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 1_024 }
    return max(1, value)
  }

  private static func safeFontSize(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 16 }
    return max(1, value)
  }

  private static func nonEmptyPath(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func makeAttachmentLookup(
    from attachments: [DraftAttachment]
  ) -> [String: DraftAttachment] {
    var result: [String: DraftAttachment] = [:]
    result.reserveCapacity(attachments.count * 2)
    for attachment in attachments {
      guard nonEmptyPath(attachment.sourceFilePath) != nil else { continue }
      for reference in [attachment.relativePublishPath, attachment.repositoryPath]
        .flatMap(referenceVariants)
      where result[reference] == nil {
        result[reference] = attachment
      }
    }
    return result
  }

  private static func matchingAttachment(
    for reference: String,
    in lookup: [String: DraftAttachment]
  ) -> DraftAttachment? {
    referenceVariants(reference).compactMap { lookup[$0] }.first
  }

  private static func referenceVariants(_ value: String) -> [String] {
    var normalized =
      value.removingPercentEncoding?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count > 2 {
      normalized.removeFirst()
      normalized.removeLast()
      normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while normalized.hasPrefix("./") {
      normalized.removeFirst(2)
    }
    guard !normalized.isEmpty else { return [] }
    if normalized.hasPrefix("/") {
      return [normalized, String(normalized.dropFirst())]
    }
    return [normalized, "/" + normalized]
  }

  private static func imageBounds(width: CGFloat) -> NSRect {
    let height: CGFloat = 164
    return NSRect(
      x: 0,
      y: -height * 0.15,
      width: width,
      height: height
    )
  }

  private static func makeFormulaAttachment(
    source: String,
    displayMode: MarkdownFormulaDisplayMode,
    availableWidth: CGFloat,
    baseFontSize: CGFloat
  ) -> MarkdownNativeTextAttachment {
    let fontSize =
      displayMode == .inline
      ? baseFontSize
      : max(19, baseFontSize)
    let rendered = MarkdownInlineFormulaPresentation.attributedString(
      for: source,
      fontSize: fontSize
    )
    let renderedSize = rendered.size()
    let isInline = displayMode == .inline
    let width = isInline
      ? min(
        availableWidth,
        max(24, ceil(max(1, renderedSize.width)) + 24)
      )
      : availableWidth
    let height = isInline
      ? max(28, ceil(max(1, renderedSize.height)) + 8)
      : max(52, ceil(max(1, renderedSize.height)) + 12)
    let bounds = NSRect(
      x: 0,
      y: -height * (isInline ? 0.20 : 0.15),
      width: max(1, width),
      height: height
    )
    return MarkdownNativeTextAttachment(
      content: .formula(
        source: source,
        displayMode: displayMode,
        fontSize: fontSize
      ),
      bounds: bounds
    )
  }
}
