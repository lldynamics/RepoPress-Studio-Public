import Foundation
import PublishingMarkdownCore

struct MarkdownTextEditRequest: Equatable {
  let id: UUID
  let expectedText: String
  let edit: MarkdownSmartEdit

  init(expectedText: String, edit: MarkdownSmartEdit) {
    id = UUID()
    self.expectedText = expectedText
    self.edit = edit
  }
}

struct MarkdownTextEditRequestOutcome: Equatable {
  let id: UUID
  let wasApplied: Bool
}

struct MarkdownTextFocusRequest: Equatable {
  let id: UUID
  let selectedRange: NSRange
}

/// Immutable, paint-only input for the editor's current structured-review
/// hunk. The text storage remains the source Markdown and is never decorated.
struct MarkdownEditorInlineAIReviewPresentation: Equatable {
  let hunkID: String
  let bodyRange: NSRange
  let replacementText: String
}

enum MarkdownGhostTextCommandPolicy {
  static func shouldAccept(
    ghostText: String,
    selectedRange: NSRange,
    bodyUTF16Offset: Int,
    hasMarkedText: Bool
  ) -> Bool {
    !hasMarkedText && !ghostText.isEmpty && selectedRange.length == 0
      && selectedRange.location >= bodyUTF16Offset
  }

  static func shouldDismiss(ghostText: String, hasMarkedText: Bool) -> Bool {
    !hasMarkedText && !ghostText.isEmpty
  }
}

struct MarkdownSyntaxHighlightComputation: Sendable {
  let text: String
  let revision: UInt64
  let plan: MarkdownSyntaxHighlightPlan
  let snapshot: MarkdownSyntaxHighlightSnapshot
  let runIndex: MarkdownSyntaxHighlightRunIndex
  let synchronizedTree: Bool
  let parserMetrics: MarkdownSyntaxHighlightParserMetrics
}

enum MarkdownSyntaxViewportRepaintReason: Equatable, Sendable {
  case content
  case viewport
  case selection
  case appearance

  var requiresFullRepaint: Bool {
    self == .appearance
  }

  var preservesInlineAttachmentDrawings: Bool {
    self == .viewport || self == .selection
  }
}
