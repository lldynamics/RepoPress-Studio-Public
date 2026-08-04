import Foundation
import Testing
@testable import PublishingWorkbenchCore

struct GeneralDraftExportServiceTests {
  @Test
  func exportsGeneralDraftAsMarkdownWithoutChangingItsStorageScope() throws {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft.emptyGeneralDraft(editingProfile: profile)
    draft.title = "可复用草稿"
    draft.slug = "Reusable Draft"
    draft.bodyMarkdown = "# 正文\n\n保留在软件中。"

    let document = try GeneralDraftExportService().document(
      for: draft,
      profile: profile
    )

    #expect(document.suggestedFilename == "reusable-draft.md")
    #expect(document.markdown.contains("title = \"可复用草稿\""))
    #expect(document.markdown.contains("# 正文"))
    #expect(draft.isGeneralDraft)
    #expect(draft.repositoryPath == nil)
  }

  @Test
  func rejectsSiteDraftExport() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft.empty(profile: profile)

    #expect(throws: GeneralDraftExportError.requiresGeneralDraft) {
      try GeneralDraftExportService().document(for: draft, profile: profile)
    }
  }
}
