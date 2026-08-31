import SwiftUI

struct WorkspaceInspectorCommandAction {
  let isPresented: Bool
  let canToggle: Bool
  let toggle: () -> Void
}
