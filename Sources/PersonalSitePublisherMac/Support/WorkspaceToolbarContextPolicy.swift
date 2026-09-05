import PublishingWorkbenchCore

/// Resolves the primary toolbar by the task currently on screen. Keeping this
/// policy value-only prevents RSS reading controls from borrowing publishing
/// state or starting a second reader store.
enum WorkspaceToolbarContextPolicy {
  enum PrimaryActionContext: Equatable {
    case publishing
    case rssReading
  }

  static func primaryActionContext(for section: WorkspaceSection) -> PrimaryActionContext {
    section == .rss ? .rssReading : .publishing
  }
}
