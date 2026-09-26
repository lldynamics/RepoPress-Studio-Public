import Combine
import Foundation
import SwiftUI

/// Gives each open workbench window a small, stable ordinal so titles can tell
/// windows apart ("· 2", "· 3") without exposing internal identifiers.
@MainActor
final class WorkspaceWindowOrdinalRegistry: ObservableObject {
  static let shared = WorkspaceWindowOrdinalRegistry()

  @Published private(set) var ordinals: [UUID: Int] = [:]

  func register(_ windowID: UUID) {
    guard ordinals[windowID] == nil else { return }
    let used = Set(ordinals.values)
    var ordinal = 1
    while used.contains(ordinal) { ordinal += 1 }
    ordinals[windowID] = ordinal
  }

  func unregister(_ windowID: UUID) {
    ordinals[windowID] = nil
  }

  /// The first window keeps a clean title; later windows get their number.
  func titleSuffix(for windowID: UUID) -> String {
    guard let ordinal = ordinals[windowID], ordinal > 1 else { return "" }
    return " · \(ordinal)"
  }
}

struct WorkspaceWindowOrdinalModifier: ViewModifier {
  let windowID: UUID

  func body(content: Content) -> some View {
    content
      .onAppear { WorkspaceWindowOrdinalRegistry.shared.register(windowID) }
      .onDisappear { WorkspaceWindowOrdinalRegistry.shared.unregister(windowID) }
      .onChange(of: windowID) { oldValue, newValue in
        WorkspaceWindowOrdinalRegistry.shared.unregister(oldValue)
        WorkspaceWindowOrdinalRegistry.shared.register(newValue)
      }
  }
}
