import Foundation
import PublishingMarkdownCore

enum MarkdownFindScope: String, CaseIterable, Identifiable {
  case body
  case selection

  var id: String { rawValue }

  var title: String {
    switch self {
    case .body:
      return String(localized: "正文")
    case .selection:
      return String(localized: "仅选区")
    }
  }
}

/// The selection present when Find opened. Routine UI validation uses its
/// revision; explicit edit confirmation also checks the expected source text.
struct MarkdownFindScopeSnapshot: Equatable {
  let draftID: UUID
  let bodyRevision: UInt64
  let range: NSRange
  let selectedText: String

  func hasMatchingRevision(for draftID: UUID, bodyRevision: UInt64, body: String) -> Bool {
    guard self.draftID == draftID, self.bodyRevision == bodyRevision else { return false }
    let sourceLength = (body as NSString).length
    guard range.location >= 0, range.length > 0, NSMaxRange(range) <= sourceLength else {
      return false
    }
    return true
  }

  func isValid(for draftID: UUID, bodyRevision: UInt64, body: String) -> Bool {
    hasMatchingRevision(for: draftID, bodyRevision: bodyRevision, body: body)
      && (body as NSString).compare(selectedText, options: .literal, range: range) == .orderedSame
  }
}

struct MarkdownFindReplacePreview: Identifiable, Equatable {
  let id = UUID()
  let draftID: UUID
  let bodyRevision: UInt64
  let scope: MarkdownFindScope
  let scopeRange: NSRange
  let query: String
  let replacement: String
  let options: MarkdownFindOptions
  let expectedBody: String
  let originalScope: String
  let proposedScope: String
  let edit: MarkdownSmartEdit
  let replacementCount: Int

  func isValid(for draftID: UUID, bodyRevision: UInt64, body: String) -> Bool {
    self.draftID == draftID && self.bodyRevision == bodyRevision
      && (body as NSString).compare(expectedBody, options: .literal) == .orderedSame
  }
}

struct MarkdownFindReplaceScopedEdit: Equatable {
  let edit: MarkdownSmartEdit
  let selectedRange: NSRange
  let replacementCount: Int
}

enum MarkdownFindReplaceScopePlanner {
  static func scopeRange(
    scope: MarkdownFindScope,
    snapshot: MarkdownFindScopeSnapshot?,
    draftID: UUID,
    bodyRevision: UInt64,
    body: String
  ) -> NSRange? {
    switch scope {
    case .body:
      return NSRange(location: 0, length: (body as NSString).length)
    case .selection:
      guard let snapshot, snapshot.hasMatchingRevision(for: draftID, bodyRevision: bodyRevision, body: body) else {
        return nil
      }
      return snapshot.range
    }
  }

  static func matches(
    in body: String,
    scopeRange: NSRange,
    query: String,
    options: MarkdownFindOptions,
    service: MarkdownFindReplaceService
  ) throws -> [NSRange] {
    let source = body as NSString
    let scopedBody = source.substring(with: scopeRange)
    return try service.matches(in: scopedBody, query: query, options: options).map {
      NSRange(location: scopeRange.location + $0.location, length: $0.length)
    }
  }

  static func replaceCurrentOrNext(
    in body: String,
    scopeRange: NSRange,
    query: String,
    replacement: String,
    selectedRange: NSRange,
    options: MarkdownFindOptions,
    service: MarkdownFindReplaceService
  ) throws -> MarkdownFindReplaceScopedEdit? {
    let source = body as NSString
    let scopedBody = source.substring(with: scopeRange)
    let relativeSelection = NSRange(
      location: min(max(selectedRange.location - scopeRange.location, 0), (scopedBody as NSString).length),
      length: selectedRange.location >= scopeRange.location && NSMaxRange(selectedRange) <= NSMaxRange(scopeRange)
        ? selectedRange.length
        : 0
    )
    let scopedMutation = try service.replaceCurrentOrNext(
      in: scopedBody,
      query: query,
      replacement: replacement,
      selectedRange: relativeSelection,
      options: options
    )
    guard scopedMutation.replacementCount > 0, let scopedEdit = scopedMutation.edit else { return nil }
    let globalSelection = NSRange(
      location: scopeRange.location + scopedEdit.selectedRange.location,
      length: scopedEdit.selectedRange.length
    )
    return MarkdownFindReplaceScopedEdit(
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(
          location: scopeRange.location + scopedEdit.replacedRange.location,
          length: scopedEdit.replacedRange.length
        ),
        replacement: scopedEdit.replacement,
        selectedRange: globalSelection
      ),
      selectedRange: globalSelection,
      replacementCount: scopedMutation.replacementCount
    )
  }

  static func previewReplaceAll(
    in body: String,
    draftID: UUID,
    bodyRevision: UInt64,
    scope: MarkdownFindScope,
    scopeRange: NSRange,
    query: String,
    replacement: String,
    options: MarkdownFindOptions,
    service: MarkdownFindReplaceService
  ) throws -> MarkdownFindReplacePreview {
    let source = body as NSString
    let scopedBody = source.substring(with: scopeRange)
    let scopedMutation = try service.replaceAll(
      in: scopedBody,
      query: query,
      replacement: replacement,
      options: options
    )
    return MarkdownFindReplacePreview(
      draftID: draftID,
      bodyRevision: bodyRevision,
      scope: scope,
      scopeRange: scopeRange,
      query: query,
      replacement: replacement,
      options: options,
      expectedBody: body,
      originalScope: scopedBody,
      proposedScope: scopedMutation.edit?.replacement ?? scopedBody,
      edit: MarkdownSmartEdit(
        replacedRange: scopeRange,
        replacement: scopedMutation.edit?.replacement ?? scopedBody,
        selectedRange: NSRange(location: scopeRange.location, length: 0)
      ),
      replacementCount: scopedMutation.replacementCount
    )
  }
}
