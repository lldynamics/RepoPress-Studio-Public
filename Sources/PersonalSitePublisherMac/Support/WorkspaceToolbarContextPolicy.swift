import PublishingWorkbenchCore

/// Resolves the primary toolbar by the task currently on screen. Keeping this
/// policy value-only prevents RSS reading controls from borrowing publishing
/// state or starting a second reader store.
enum WorkspaceToolbarContextPolicy {
  enum PrimaryActionContext: Equatable {
    case publishing
    case rssReading
    case knowledgeLibrary
    case images
  }

  static func primaryActionContext(for section: WorkspaceSection) -> PrimaryActionContext {
    switch section {
    case .rss: .rssReading
    case .library: .knowledgeLibrary
    case .images: .images
    case .writing, .sync, .contentHealth: .publishing
    }
  }
}
