import Foundation
import PublishingWorkbenchCore

/// Constant-size input snapshot for the editor toolbar's AI availability menu.
///
/// The editor body and selection are read once while the toolbar actions are
/// constructed. The snapshot keeps only the resulting context flags and the
/// bounded set of action presentations, so menu items never retain or rescan
/// the current document after construction.
struct MarkdownComposerAIAvailabilitySnapshot {
  let draftID: UUID
  let hasSelectedText: Bool
  let hasBodyText: Bool
  let hasArticleSeedText: Bool
  let isAIEnabled: Bool
  let activeAction: AIPublishingActionKind?
  let isAIActionRunning: Bool

  private let selectionPresentations: [String: AIPublishingActionAvailabilityPresentation]
  private let articlePresentations: [String: AIPublishingActionAvailabilityPresentation]

  init(
    draft: ArticleDraft,
    bodyMarkdown: String? = nil,
    selectedText: String,
    isAIEnabled: Bool,
    activeAction: AIPublishingActionKind?,
    isAIActionRunning: Bool
  ) {
    self.draftID = draft.id
    self.hasSelectedText = Self.hasPublishingText(selectedText)
    self.hasBodyText = Self.hasPublishingText(bodyMarkdown ?? draft.bodyMarkdown)
    let hasTitleText = Self.hasPublishingText(draft.title)
    let hasSummaryText = Self.hasPublishingText(draft.summary)
    self.hasArticleSeedText = hasBodyText || hasTitleText || hasSummaryText
    self.isAIEnabled = isAIEnabled
    self.activeAction = activeAction
    self.isAIActionRunning = isAIActionRunning

    // Use a tiny projection after measuring the live values once. The core
    // availability service still owns action requirements and localized
    // reasons, while its probes cannot rescan the 100k-character editor body.
    let availabilityDraft = ArticleDraft(
      id: draft.id,
      siteProfileID: draft.siteProfileID,
      title: hasTitleText ? Self.nonEmptyMarker : "",
      summary: hasSummaryText ? Self.nonEmptyMarker : "",
      bodyMarkdown: hasBodyText ? Self.nonEmptyMarker : ""
    )
    let availabilitySelectedText = hasSelectedText ? Self.nonEmptyMarker : ""

    var selectionPresentations = [
      String: AIPublishingActionAvailabilityPresentation
    ](minimumCapacity: AIPublishingActionKind.allCases.count)
    var articlePresentations = [
      String: AIPublishingActionAvailabilityPresentation
    ](minimumCapacity: AIPublishingActionKind.allCases.count)
    for kind in AIPublishingActionKind.allCases {
      let effectiveActiveAction = activeAction ?? (isAIActionRunning ? kind : nil)
      selectionPresentations[kind.rawValue] =
        AIPublishingActionAvailabilityService.presentation(
          for: kind,
          selectedText: availabilitySelectedText,
          draft: availabilityDraft,
          isAIEnabled: isAIEnabled,
          activeAction: effectiveActiveAction
        )
      articlePresentations[kind.rawValue] =
        AIPublishingActionAvailabilityService.presentation(
          for: kind,
          draft: availabilityDraft,
          isAIEnabled: isAIEnabled,
          activeAction: effectiveActiveAction
        )
    }
    self.selectionPresentations = selectionPresentations
    self.articlePresentations = articlePresentations
  }

  func selectionAvailability(
    for kind: AIPublishingActionKind
  ) -> AIPublishingActionAvailabilityPresentation {
    // Every action kind is populated from allCases during initialization.
    selectionPresentations[kind.rawValue]!
  }

  func articleAvailability(
    for kind: AIPublishingActionKind
  ) -> AIPublishingActionAvailabilityPresentation {
    // Every action kind is populated from allCases during initialization.
    articlePresentations[kind.rawValue]!
  }

  private static let nonEmptyMarker = "x"
  private static let publishingWhitespace = CharacterSet.whitespacesAndNewlines

  private static func hasPublishingText(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      !publishingWhitespace.contains(scalar)
    }
  }
}
