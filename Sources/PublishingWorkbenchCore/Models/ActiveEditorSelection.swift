import Foundation

public struct ActiveEditorSelection: Equatable, Sendable {
  public var draftID: UUID
  /// The window that supplied this selection. `nil` preserves compatibility
  /// for pre-window-scoped callers, but new editor paths always set it.
  public var windowID: UUID?
  public var range: NSRange
  public var selectedText: String
  public var bodyUTF16Count: Int

  public init(
    draftID: UUID,
    windowID: UUID? = nil,
    range: NSRange,
    selectedText: String,
    bodyUTF16Count: Int
  ) {
    self.draftID = draftID
    self.windowID = windowID
    self.range = range
    self.selectedText = selectedText
    self.bodyUTF16Count = bodyUTF16Count
  }

  public var hasSelectedText: Bool {
    range.length > 0 && !selectedText.trimmedForPublishing.isEmpty
  }

  public func validatedRange(in draft: ArticleDraft) -> NSRange? {
    guard draft.id == draftID, hasSelectedText else { return nil }
    let source = draft.bodyMarkdown as NSString
    guard bodyUTF16Count == source.length,
      range.location >= 0,
      range.length > 0,
      range.location + range.length <= source.length,
      source.substring(with: range) == selectedText
    else { return nil }
    return range
  }
}
