import Foundation

public struct MarkdownEditorAnalysisSnapshot: Hashable, Sendable {
  public var diagnostics: [MarkdownInlineDiagnostic]
  public var outlineItems: [MarkdownOutlineItem]

  public init(
    diagnostics: [MarkdownInlineDiagnostic],
    outlineItems: [MarkdownOutlineItem]
  ) {
    self.diagnostics = diagnostics
    self.outlineItems = outlineItems
  }

  public static let empty = MarkdownEditorAnalysisSnapshot(
    diagnostics: [],
    outlineItems: []
  )
}

/// Builds the editor's derived Markdown data once per source revision. The
/// background entry point keeps regular-expression and public-risk scanning
/// away from the main actor.
public struct MarkdownEditorAnalysisService: Sendable {
  public init() {}

  public func analyze(
    _ markdown: String,
    includeOutline: Bool = true
  ) -> MarkdownEditorAnalysisSnapshot {
    Self.makeSnapshot(markdown, includeOutline: includeOutline)
  }

  public func analyzeInBackground(
    _ markdown: String,
    includeOutline: Bool = true
  ) async -> MarkdownEditorAnalysisSnapshot {
    await Task.detached(priority: .userInitiated) {
      Self.makeSnapshot(markdown, includeOutline: includeOutline)
    }.value
  }

  private static func makeSnapshot(
    _ markdown: String,
    includeOutline: Bool
  ) -> MarkdownEditorAnalysisSnapshot {
    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)
    guard !Task.isCancelled else {
      return MarkdownEditorAnalysisSnapshot(diagnostics: diagnostics, outlineItems: [])
    }
    let outlineItems = includeOutline
      ? MarkdownOutlineService().outline(in: markdown)
      : []
    return MarkdownEditorAnalysisSnapshot(
      diagnostics: diagnostics,
      outlineItems: outlineItems
    )
  }
}
