import SwiftUI

/// The two ways to change where data lives: copy the current folder to a new
/// location, or switch to another existing data folder. Either one quits the
/// app; the chosen folder opens on the next launch.
struct DataRootLocationActions: View {
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  @Binding var isBusy: Bool
  let onCopy: () -> Void
  @State private var pendingRootURL: URL?

  var body: some View {
    Button(String(localized: "复制到新位置并切换…"), systemImage: "externaldrive.badge.timemachine") {
      onCopy()
    }
    .disabled(isBusy || coordinator.dataRootPath == nil)
    Button(String(localized: "打开已有数据文件夹…"), systemImage: "folder") {
      Task {
        guard let url = await WorkbenchDataRootSelectionPanel.chooseExistingDataRoot() else {
          return
        }
        pendingRootURL = url
      }
    }
    .disabled(isBusy || coordinator.dataRootPath == nil)
    .accessibilityIdentifier("storage-open-existing-data-root")
    .alert(
      String(localized: "切换到已有数据文件夹？"),
      isPresented: Binding(
        get: { pendingRootURL != nil },
        set: { if !$0 { pendingRootURL = nil } }
      )
    ) {
      Button(String(localized: "保存并切换")) { switchRoot() }
      Button(String(localized: "取消"), role: .cancel) { pendingRootURL = nil }
    } message: {
      Text(
        String(
          format: String(localized: "将保存当前工作区并退出应用，下次打开时使用 %@。两个文件夹的内容都不会被复制或合并。"),
          pendingRootURL?.path ?? ""
        ))
    }
  }

  private func switchRoot() {
    guard let url = pendingRootURL else { return }
    pendingRootURL = nil
    isBusy = true
    Task {
      guard await coordinator.switchToExistingDataRoot(at: url) != nil else {
        isBusy = false
        return
      }
      NSApp.terminate(nil)
    }
  }
}
