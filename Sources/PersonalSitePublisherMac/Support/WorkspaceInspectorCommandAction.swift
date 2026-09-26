import SwiftUI

struct WorkspaceInspectorCommandAction {
  let isPresented: Bool
  let canToggle: Bool
  var exitsFocusMode = false
  let toggle: () -> Void

  var title: String {
    if exitsFocusMode {
      return String(localized: "显示详情栏并退出专注")
    }
    return isPresented ? String(localized: "隐藏详情栏") : String(localized: "显示详情栏")
  }
}
