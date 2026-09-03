import SwiftUI

struct StructuralDraftRepairCommandAction: Sendable {
  var isScanning = false
  let open: @MainActor @Sendable () -> Void
}

enum StructuralRepairFollowUp {
  case showDrafts([UUID])
  case recheck
  case preparePublishing
}

private struct StructuralDraftRepairCommandActionKey: EnvironmentKey {
  static let defaultValue: StructuralDraftRepairCommandAction? = nil
}

extension EnvironmentValues {
  var structuralDraftRepairCommandAction: StructuralDraftRepairCommandAction? {
    get { self[StructuralDraftRepairCommandActionKey.self] }
    set { self[StructuralDraftRepairCommandActionKey.self] = newValue }
  }
}
