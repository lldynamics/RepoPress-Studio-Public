import PublishingCoreSupport

/// One user-facing state, projected from existing storage without a migration.
/// Visibility remains independent: private articles can be backed up remotely.
public enum ArticleState: String, CaseIterable, Identifiable, Sendable {
  case draft
  case ready
  case published
  case localOnly

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .draft: return CoreL10n.text("草稿")
    case .ready: return CoreL10n.text("待发布")
    case .published: return CoreL10n.text("已发布")
    case .localOnly: return CoreL10n.text("仅本地")
    }
  }

  public var systemImage: String {
    switch self {
    case .draft: return "square.and.pencil"
    case .ready: return "paperplane"
    case .published: return "checkmark.seal"
    case .localOnly: return "internaldrive"
    }
  }
}

extension ArticleDraft {
  public var articleState: ArticleState {
    if isGeneralDraft { return .localOnly }
    if draft { return .draft }
    if status == .published { return .published }
    return .ready
  }

  /// Editing intent must neither manufacture publication evidence nor change
  /// privacy or repository ownership. Local-only transitions use transfer plans.
  @discardableResult
  public mutating func setArticleState(_ state: ArticleState) -> Bool {
    guard !isGeneralDraft, state == .draft || state == .ready else { return false }
    let nextStatus: DraftStatus = state == .draft ? .draft : .ready
    guard draft != (state == .draft) || status != nextStatus else { return false }
    draft = state == .draft
    status = nextStatus
    return true
  }
}

extension DraftRepositorySyncState {
  public var hasSyncProblem: Bool {
    self == .diverged || self == .failed
  }
}
