import Foundation

/// Converts a before/after Markdown value into one minimal TextKit edit.
///
/// Keeping programmatic mutations on the same `NSTextView.insertText` path as
/// keyboard edits means AppKit can register one coherent undo operation.
public enum MarkdownTextMutationService {
  public static func edit(
    from original: String,
    to updated: String,
    selectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    guard original != updated else { return nil }

    var originalStart = original.startIndex
    var updatedStart = updated.startIndex
    while originalStart < original.endIndex,
      updatedStart < updated.endIndex,
      original[originalStart] == updated[updatedStart]
    {
      original.formIndex(after: &originalStart)
      updated.formIndex(after: &updatedStart)
    }

    var originalEnd = original.endIndex
    var updatedEnd = updated.endIndex
    while originalEnd > originalStart, updatedEnd > updatedStart {
      let previousOriginal = original.index(before: originalEnd)
      let previousUpdated = updated.index(before: updatedEnd)
      guard original[previousOriginal] == updated[previousUpdated] else { break }
      originalEnd = previousOriginal
      updatedEnd = previousUpdated
    }

    // A pure insertion can have several equally minimal representations when
    // adjacent lines share characters. Rotate an equivalent insertion left
    // only when doing so produces complete line boundaries.
    if originalStart == originalEnd {
      var candidateOriginalStart = originalStart
      var candidateUpdatedStart = updatedStart
      var candidateUpdatedEnd = updatedEnd

      while candidateOriginalStart > original.startIndex,
        candidateUpdatedStart > updated.startIndex,
        candidateUpdatedEnd > candidateUpdatedStart
      {
        let previousOriginal = original.index(before: candidateOriginalStart)
        let previousUpdatedStart = updated.index(before: candidateUpdatedStart)
        let previousUpdatedEnd = updated.index(before: candidateUpdatedEnd)
        guard original[previousOriginal] == updated[previousUpdatedEnd] else {
          break
        }

        candidateOriginalStart = previousOriginal
        candidateUpdatedStart = previousUpdatedStart
        candidateUpdatedEnd = previousUpdatedEnd

        if isLineBoundary(in: original, at: candidateOriginalStart),
          isLineBoundary(in: updated, at: candidateUpdatedEnd)
        {
          originalStart = candidateOriginalStart
          originalEnd = candidateOriginalStart
          updatedStart = candidateUpdatedStart
          updatedEnd = candidateUpdatedEnd
          break
        }
      }
    }

    let location = original[..<originalStart].utf16.count
    let replacedLength = original[originalStart..<originalEnd].utf16.count
    let replacement = String(updated[updatedStart..<updatedEnd])
    let updatedLength = updated.utf16.count
    let clampedLocation = min(max(selectedRange.location, 0), updatedLength)
    let clampedLength = min(
      max(selectedRange.length, 0),
      updatedLength - clampedLocation
    )

    return MarkdownSmartEdit(
      replacedRange: NSRange(location: location, length: replacedLength),
      replacement: replacement,
      selectedRange: NSRange(
        location: clampedLocation,
        length: clampedLength
      )
    )
  }

  private static func isLineBoundary(in text: String, at index: String.Index) -> Bool {
    index == text.startIndex || text[text.index(before: index)].isNewline
  }
}
