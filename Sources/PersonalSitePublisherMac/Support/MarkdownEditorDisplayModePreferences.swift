import PublishingWorkbenchCore

enum MarkdownEditorDisplayModePreferenceScope: Equatable {
  case siteArticle
  case generalDraft

  init(isGeneralDraft: Bool) {
    self = isGeneralDraft ? .generalDraft : .siteArticle
  }
}

enum MarkdownEditorDisplayModePreferences {
  static let siteArticleKey = "markdownEditorDisplayMode.siteArticle"
  static let generalDraftKey = "markdownEditorDisplayMode.generalDraft"

  static func mode(
    for scope: MarkdownEditorDisplayModePreferenceScope,
    siteArticleRawValue: String,
    generalDraftRawValue: String
  ) -> EditorDisplayMode {
    let rawValue =
      switch scope {
      case .siteArticle:
        siteArticleRawValue
      case .generalDraft:
        generalDraftRawValue
      }
    return EditorDisplayMode(rawValue: rawValue) ?? .edit
  }
}
