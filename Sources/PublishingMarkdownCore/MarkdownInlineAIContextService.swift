import Foundation
import PublishingCoreSupport

/// Builds the small, cursor-scoped context used by inline AI writing.
///
/// The editor passes body Markdown only, so this service deliberately stays
/// independent from Front Matter and does not send the whole document by
/// default. The caller can still use the normal AI consent and provider
/// boundary before transmitting the returned context.
public struct MarkdownInlineAIContextService: Sendable {
  public static let defaultMaximumUTF16Length = 3_200
  public static let defaultMaximumContinuationUTF16Length = 480

  public init() {}

  public func context(
    in markdown: String,
    cursorUTF16Location: Int,
    maximumUTF16Length: Int = Self.defaultMaximumUTF16Length
  ) -> String? {
    let source = markdown as NSString
    guard cursorUTF16Location >= 0,
          cursorUTF16Location <= source.length,
          maximumUTF16Length > 0 else {
      return nil
    }

    let safeCursorLocation = composedCharacterBoundary(
      atOrBefore: cursorUTF16Location,
      in: source
    )
    let start = composedCharacterBoundary(
      atOrAfter: max(0, safeCursorLocation - maximumUTF16Length),
      in: source
    )
    let candidate = source.substring(
      with: NSRange(
        location: start,
        length: safeCursorLocation - start
      )
    )
    guard !candidate.trimmedForPublishing.isEmpty else { return nil }
    return candidate
  }

  public func normalizedContinuation(
    _ content: String,
    maximumUTF16Length: Int = Self.defaultMaximumContinuationUTF16Length
  ) -> String? {
    guard maximumUTF16Length > 0 else { return nil }
    let normalized = content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .newlines)
    guard !normalized.trimmedForPublishing.isEmpty else { return nil }

    let source = normalized as NSString
    let length = composedCharacterBoundary(
      atOrBefore: min(source.length, maximumUTF16Length),
      in: source
    )
    guard length > 0 else { return nil }
    return source.substring(to: length)
  }

  private func composedCharacterBoundary(
    atOrBefore proposedLocation: Int,
    in source: NSString
  ) -> Int {
    guard proposedLocation > 0, proposedLocation < source.length else {
      return min(max(0, proposedLocation), source.length)
    }

    let precedingSequence = source.rangeOfComposedCharacterSequence(at: proposedLocation - 1)
    return NSMaxRange(precedingSequence) > proposedLocation
      ? precedingSequence.location
      : proposedLocation
  }

  private func composedCharacterBoundary(
    atOrAfter proposedLocation: Int,
    in source: NSString
  ) -> Int {
    guard proposedLocation > 0, proposedLocation < source.length else {
      return min(max(0, proposedLocation), source.length)
    }

    let sequence = source.rangeOfComposedCharacterSequence(at: proposedLocation)
    return sequence.location < proposedLocation
      ? NSMaxRange(sequence)
      : proposedLocation
  }
}
