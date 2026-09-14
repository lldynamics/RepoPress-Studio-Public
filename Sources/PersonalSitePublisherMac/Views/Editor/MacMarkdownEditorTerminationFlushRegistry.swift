/// Holds weak references to mounted native Markdown editors so the AppKit
/// termination delegate can synchronously drain their coalesced document
/// bindings before WorkbenchStore establishes its safe-exit snapshot.
@MainActor
enum MacMarkdownEditorTerminationFlushRegistry {
  private final class WeakCoordinator {
    weak var value: MacMarkdownTextView.Coordinator?

    init(_ value: MacMarkdownTextView.Coordinator) {
      self.value = value
    }
  }

  private static var coordinators: [ObjectIdentifier: WeakCoordinator] = [:]

  static func register(_ coordinator: MacMarkdownTextView.Coordinator) {
    coordinators = coordinators.filter { $0.value.value != nil }
    coordinators[ObjectIdentifier(coordinator)] = WeakCoordinator(coordinator)
  }

  static func unregister(_ coordinator: MacMarkdownTextView.Coordinator) {
    coordinators.removeValue(forKey: ObjectIdentifier(coordinator))
  }

  static func flushPendingWritesForTermination() {
    let activeCoordinators = coordinators.values.compactMap(\.value)
    coordinators = Dictionary(
      uniqueKeysWithValues: activeCoordinators.map { (ObjectIdentifier($0), WeakCoordinator($0)) }
    )

    for coordinator in activeCoordinators {
      coordinator.flushPendingBindingWrites(notifyingDocumentCommit: true)
    }
  }
}
