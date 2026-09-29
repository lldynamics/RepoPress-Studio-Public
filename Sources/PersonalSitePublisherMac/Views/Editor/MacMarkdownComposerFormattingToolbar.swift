import SwiftUI

extension MacMarkdownComposerView {
  func syncFocusToolbarVisibility() {
    zenModeController.setZenModeActive(isFocusModeActive)
  }

  var integratedFormattingToolbar: MacMarkdownFormattingToolbar {
    MacMarkdownFormattingToolbar(
      isFocusModeActive: $isFocusModeActive,
      onApplyMarkdownFormatting: applyMarkdownFormatting,
      onApplyAdvancedFormatting: applyAdvancedMarkdownFormatting,
      onInsertCodeBlock: insertCodeBlock,
      onInsertTable: insertTable,
      onInsertHorizontalRule: insertHorizontalRule,
      onInsertInternalLink: {
        guard requireBodyEditingContext() else { return }
        isInternalLinkPickerPresented = true
      },
      onShowSnippets: {
        guard requireBodyEditingContext() else { return }
        isSnippetLibraryPresented = true
      },
      onShowDiagnostics: {
        showDiagnostics()
      },
      diagnosticCount: inlineDiagnostics.count,
      onInsertImage: {
        guard requireBodyEditingContext() else { return }
        let requestedDraftID = draft.id
        Task {
          let urls = await ImageSelectionPanel.chooseImages()
          guard draft.id == requestedDraftID, !urls.isEmpty else { return }
          insertImageReferences(urls)
        }
      },
      onInsertVideo: {
        guard requireBodyEditingContext() else { return }
        let requestedDraftID = draft.id
        Task {
          let urls = await VideoSelectionPanel.chooseVideos()
          guard draft.id == requestedDraftID, !urls.isEmpty else { return }
          insertVideoReferences(urls)
        }
      },
      onFormatChineseTypography: formatChineseTypography,
      presentation: .integrated
    )
  }
}
