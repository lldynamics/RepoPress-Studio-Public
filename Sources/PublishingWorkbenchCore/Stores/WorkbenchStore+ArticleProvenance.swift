import Foundation

public enum ArticleProvenanceUpdateResult: Equatable, Sendable {
  case applied
  case unchanged
  case draftNotFound
  case malformedManagedDisclosure
  case bodyConflict
}

extension WorkbenchStore {
  /// Updates provenance against the live editor buffer so an Inspector action
  /// cannot replace text that is still waiting for the body autosave debounce.
  @discardableResult
  public func applyArticleProvenance(
    _ provenance: ArticleProvenance,
    to draftID: UUID
  ) -> ArticleProvenanceUpdateResult {
    guard var current = draft(for: draftID) else {
      setPublishActionMessage(
        CoreL10n.text("这篇文章已被删除，创作来源未修改。"),
        status: .warning
      )
      return .draftNotFound
    }

    let buffer = draftBodyEditorBuffer(for: draftID)
    current.bodyMarkdown = buffer.bodyMarkdown
    let edit = ArticleProvenanceService().applying(provenance, to: current)
    guard edit.isValid else {
      setPublishActionMessage(
        CoreL10n.text("创作说明的 RepoPress 标记不完整，已停止修改以保护正文。"),
        status: .warning
      )
      return .malformedManagedDisclosure
    }

    let bodyChanged = edit.draft.bodyMarkdown != buffer.bodyMarkdown
    let tagsChanged = edit.draft.tags != current.tags
    guard bodyChanged || tagsChanged else { return .unchanged }

    if bodyChanged {
      guard
        let staged = stageDraftBody(
          edit.draft.bodyMarkdown,
          for: draftID,
          baseRevision: buffer.revision
        ),
        staged.wasAccepted
      else {
        setPublishActionMessage(
          CoreL10n.text("另一窗口已更新正文，创作来源未修改；编辑器已同步到最新版本。"),
          status: .warning
        )
        return .bodyConflict
      }
    }

    if tagsChanged {
      current.tags = edit.draft.tags
      updateDraft(current)
    }
    return .applied
  }
}
