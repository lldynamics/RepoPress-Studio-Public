import SwiftUI

struct WorkspaceFocusModeCommandAction {
  let isActive: Bool
  let canToggle: Bool
  let toggle: () -> Void
}
