import Foundation
import PublishingMarkdownCore

public extension MarkdownSnippetLibraryService {
  static func expandedMarkdown(
    for snippet: MarkdownSnippet,
    draft: ArticleDraft,
    date: Date = Date()
  ) -> String {
    expandedMarkdown(
      for: snippet,
      context: MarkdownSnippetExpansionContext(
        title: draft.title,
        slug: draft.slug
      ),
      date: date
    )
  }
}
