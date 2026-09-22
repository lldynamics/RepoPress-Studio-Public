import Foundation
import PublishingKnowledgeCore

/// A search hit is delivered only after its presenting window regains control.
struct WorkspaceDeferredContentSearchRequest {
  enum Destination {
    case knowledge(KnowledgeSearchResult, query: String)
    case rss(articleID: String, query: String)
  }

  private var destination: Destination?
  private var didDismissSheet = false

  mutating func enqueue(_ destination: Destination) {
    self.destination = destination
    didDismissSheet = false
  }

  mutating func sheetDidDismiss() {
    didDismissSheet = true
  }

  mutating func cancel() {
    destination = nil
    didDismissSheet = false
  }

  mutating func consume(isKeyWindow: Bool) -> Destination? {
    guard didDismissSheet, isKeyWindow, let destination else { return nil }
    cancel()
    return destination
  }
}
