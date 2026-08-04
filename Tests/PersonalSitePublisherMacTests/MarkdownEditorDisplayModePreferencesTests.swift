import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownEditorDisplayModePreferencesTests: XCTestCase {
  func testRestoresIndependentModesForSiteAndGeneralDrafts() {
    XCTAssertEqual(
      MarkdownEditorDisplayModePreferences.mode(
        for: .siteArticle,
        siteArticleRawValue: EditorDisplayMode.split.rawValue,
        generalDraftRawValue: EditorDisplayMode.preview.rawValue
      ),
      .split
    )
    XCTAssertEqual(
      MarkdownEditorDisplayModePreferences.mode(
        for: .generalDraft,
        siteArticleRawValue: EditorDisplayMode.split.rawValue,
        generalDraftRawValue: EditorDisplayMode.preview.rawValue
      ),
      .preview
    )
  }

  func testUnknownStoredModeFallsBackToEdit() {
    XCTAssertEqual(
      MarkdownEditorDisplayModePreferences.mode(
        for: .siteArticle,
        siteArticleRawValue: "future-mode",
        generalDraftRawValue: EditorDisplayMode.preview.rawValue
      ),
      .edit
    )
  }

  func testScopeFollowsDraftKind() {
    XCTAssertEqual(
      MarkdownEditorDisplayModePreferenceScope(isGeneralDraft: false),
      .siteArticle
    )
    XCTAssertEqual(
      MarkdownEditorDisplayModePreferenceScope(isGeneralDraft: true),
      .generalDraft
    )
  }

  func testDraftKindChangeSelectsTheOtherStoredPreference() {
    let siteScope = MarkdownEditorDisplayModePreferenceScope(isGeneralDraft: false)
    let generalScope = MarkdownEditorDisplayModePreferenceScope(isGeneralDraft: true)

    XCTAssertEqual(
      MarkdownEditorDisplayModePreferences.mode(
        for: siteScope,
        siteArticleRawValue: EditorDisplayMode.split.rawValue,
        generalDraftRawValue: EditorDisplayMode.preview.rawValue
      ),
      .split
    )
    XCTAssertEqual(
      MarkdownEditorDisplayModePreferences.mode(
        for: generalScope,
        siteArticleRawValue: EditorDisplayMode.split.rawValue,
        generalDraftRawValue: EditorDisplayMode.preview.rawValue
      ),
      .preview
    )
  }
}
