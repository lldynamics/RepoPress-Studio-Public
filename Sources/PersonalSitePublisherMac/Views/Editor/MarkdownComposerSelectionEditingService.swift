import Foundation
import PublishingWorkbenchCore

struct MarkdownComposerSelectionMutation {
  var draft: ArticleDraft
  var selectedRange: NSRange
}

/// The body, selection and optimistic revisions that an asynchronous media
/// import must still match before it can insert its Markdown. Keeping this
/// value immutable prevents a later caret move from redirecting the import.
struct MarkdownComposerAttachmentInsertionSnapshot: Equatable {
  let bodyMarkdown: String
  let selectedRange: NSRange
  let bodyRevision: UInt64
  let editorMetadataRevision: UInt64

  init(
    bodyMarkdown: String,
    selectedRange: NSRange,
    bodyRevision: UInt64,
    editorMetadataRevision: UInt64,
    selectionEditingService: MarkdownComposerSelectionEditingService =
      MarkdownComposerSelectionEditingService()
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.selectedRange = selectionEditingService.clamped(
      selectedRange,
      length: (bodyMarkdown as NSString).length
    )
    self.bodyRevision = bodyRevision
    self.editorMetadataRevision = editorMetadataRevision
  }

  func matches(
    bodyMarkdown: String,
    bodyRevision: UInt64,
    editorMetadataRevision: UInt64
  ) -> Bool {
    self.bodyMarkdown == bodyMarkdown
      && self.bodyRevision == bodyRevision
      && self.editorMetadataRevision == editorMetadataRevision
  }

  func replacingSelection(
    in draft: ArticleDraft,
    with markdown: String,
    selectionEditingService: MarkdownComposerSelectionEditingService =
      MarkdownComposerSelectionEditingService()
  ) -> MarkdownComposerSelectionMutation {
    var sourceDraft = draft
    sourceDraft.bodyMarkdown = bodyMarkdown
    return selectionEditingService.replacingSelection(
      in: sourceDraft,
      selectedRange: selectedRange,
      with: markdown
    )
  }
}

struct MarkdownComposerSelectionEditingService {
  func replacingSelection(
    in draft: ArticleDraft,
    selectedRange: NSRange,
    with markdown: String
  ) -> MarkdownComposerSelectionMutation {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source, selectedRange: selectedRange)
    let needsLeadingBreak =
      range.location > 0 && !source.substring(to: range.location).hasSuffix("\n")
    let needsTrailingBreak =
      range.location + range.length < source.length
      && !source.substring(from: range.location + range.length).hasPrefix("\n")
    let insertion = "\(needsLeadingBreak ? "\n" : "")\(markdown)\(needsTrailingBreak ? "\n" : "")"
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: insertion)
    return MarkdownComposerSelectionMutation(
      draft: updated,
      selectedRange: NSRange(
        location: range.location + (insertion as NSString).length,
        length: 0
      )
    )
  }

  func replacingRawSelection(
    in draft: ArticleDraft,
    selectedRange: NSRange,
    with text: String
  ) -> MarkdownComposerSelectionMutation {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source, selectedRange: selectedRange)
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: text)
    return MarkdownComposerSelectionMutation(
      draft: updated,
      selectedRange: NSRange(
        location: range.location + (text as NSString).length,
        length: 0
      )
    )
  }

  func wrappingSelection(
    in draft: ArticleDraft,
    selectedRange: NSRange,
    prefix: String,
    suffix: String,
    placeholder: String
  ) -> MarkdownComposerSelectionMutation {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source, selectedRange: selectedRange)
    let selected = range.length > 0 ? source.substring(with: range) : placeholder
    let replacement = prefix + selected + suffix
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    return MarkdownComposerSelectionMutation(
      draft: updated,
      selectedRange: NSRange(
        location: range.location + (prefix as NSString).length,
        length: (selected as NSString).length
      )
    )
  }

  func replacingCurrentLines(
    in draft: ArticleDraft,
    selectedRange: NSRange,
    transform: (String) -> String
  ) -> MarkdownComposerSelectionMutation {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source, selectedRange: selectedRange)
    let effectiveRange = NSRange(location: range.location, length: max(range.length, 0))
    let lineRange = source.lineRange(for: effectiveRange)
    let lineText = source.substring(with: lineRange)
    let lines = lineText.components(separatedBy: "\n")
    let transformed = lines.enumerated().map { index, line in
      if index == lines.count - 1, line.isEmpty {
        return line
      }
      return transform(line)
    }
    .joined(separator: "\n")

    updated.bodyMarkdown = source.replacingCharacters(in: lineRange, with: transformed)
    return MarkdownComposerSelectionMutation(
      draft: updated,
      selectedRange: NSRange(
        location: min(range.location, (updated.bodyMarkdown as NSString).length),
        length: range.length
      )
    )
  }

  func selectedText(in text: String, selectedRange: NSRange) -> String {
    let source = text as NSString
    let range = clamped(selectedRange, length: source.length)
    guard range.length > 0 else { return "" }
    return source.substring(with: range)
  }

  func editingRange(in source: NSString, selectedRange: NSRange) -> NSRange {
    clamped(selectedRange, length: source.length)
  }

  func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(max(range.length, 0), maxLength))
  }
}
