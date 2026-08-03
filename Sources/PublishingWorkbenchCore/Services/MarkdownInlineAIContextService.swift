import Foundation

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

    let start = max(0, cursorUTF16Location - maximumUTF16Length)
    let candidate = source.substring(
      with: NSRange(
        location: start,
        length: cursorUTF16Location - start
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
    let length = min(source.length, maximumUTF16Length)
    guard length > 0 else { return nil }
    return source.substring(to: length)
  }
}
