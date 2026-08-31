import PublishingWorkbenchCore

struct RemoteConflictDraftSelection: Equatable {
  private(set) var choices: [String: RemoteRepositoryConflictResolutionChoice] = [:]
  private(set) var mergeDrafts: [String: String] = [:]

  mutating func select(
    path: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    local: String?,
    remote: String?
  ) {
    choices[path] = choice
    guard choice == .merge, mergeDrafts[path] == nil else { return }
    mergeDrafts[path] = local ?? ""
  }

  func choice(for path: String) -> RemoteRepositoryConflictResolutionChoice? {
    choices[path]
  }

  func mergeDraft(for path: String) -> String {
    mergeDrafts[path] ?? ""
  }

  func displayedDocument(for path: String, local: String?, remote: String?) -> String {
    switch choices[path] {
    case .useRemote: return remote ?? ""
    case .merge: return mergeDraft(for: path)
    case .keepLocal, nil: return local ?? ""
    }
  }

  mutating func updateMergeDraft(_ text: String, for path: String) {
    guard choices[path] == .merge else { return }
    mergeDrafts[path] = text
  }
}
