import SwiftUI

struct WorkspaceInspectorCommandAction {
  let isPresented: Bool
  let canToggle: Bool
  var exitsFocusMode = false
  let toggle: () -> Void

  var title: String {
    if exitsFocusMode {
      return String(localized: "显示 Inspector 并退出专注")
    }
    return isPresented ? String(localized: "隐藏 Inspector") : String(localized: "显示 Inspector")
  }
}
