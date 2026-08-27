import Foundation
import PublishingCoreSupport

public enum SelectionActionBarPresentation {
  public static func shouldShow(
    hasSelectedText: Bool,
    isSelectionAIActionRunning: Bool,
    selectionActionMessage: String
  ) -> Bool {
    hasSelectedText
      || isSelectionAIActionRunning
      || !selectionActionMessage.trimmedForPublishing.isEmpty
  }
}
