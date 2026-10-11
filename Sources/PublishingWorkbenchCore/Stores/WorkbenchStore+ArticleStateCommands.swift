import Foundation

extension WorkbenchStore {
  public func setArticleState(_ state: ArticleState, for draftID: UUID) {
    guard var draft = draft(for: draftID), draft.setArticleState(state) else { return }
    updateDraftFromEditor(draft)
  }
}
