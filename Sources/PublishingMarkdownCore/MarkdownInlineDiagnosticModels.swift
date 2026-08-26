import Foundation

public enum MarkdownInlineDiagnosticSeverity: String, Codable, Hashable, Sendable {
  case warning
  case error
}

public struct MarkdownInlineDiagnostic: Identifiable, Hashable, Sendable {
  public var id: String
  public var severity: MarkdownInlineDiagnosticSeverity
  public var title: String
  public var message: String
  public var range: NSRange
  public var replacement: String?

  public init(
    id: String,
    severity: MarkdownInlineDiagnosticSeverity,
    title: String,
    message: String,
    range: NSRange,
    replacement: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.range = range
    self.replacement = replacement
  }

  public var quickFixTitle: String? {
    replacement == nil ? nil : "应用快速修复"
  }
}

public struct MarkdownInlineDiagnosticContext: Hashable, Sendable {
  public var knownArticleTitles: Set<String>
  public var attachmentPaths: Set<String>

  public init(
    knownArticleTitles: Set<String> = [],
    attachmentPaths: Set<String> = []
  ) {
    self.knownArticleTitles = knownArticleTitles
    self.attachmentPaths = attachmentPaths
  }

  public static let empty = MarkdownInlineDiagnosticContext()
}
