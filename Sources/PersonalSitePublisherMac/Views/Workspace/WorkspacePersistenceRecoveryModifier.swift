import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension View {
  func workspacePersistenceRecovery(store: WorkbenchStore) -> some View {
    modifier(WorkspacePersistenceRecoveryModifier(store: store))
  }
}

/// Owns the recovery dialogs for one window, independently of navigation and layout.
private struct WorkspacePersistenceRecoveryModifier: ViewModifier {
  let store: WorkbenchStore
  @ObservedObject private var shellState: WorkbenchRootPresentationFeatureFacade
  @State private var isPersistenceResetConfirmationPresented = false
  @State private var persistenceResetFeedback: PersistenceRecoveryResetFeedback?

  init(store: WorkbenchStore) {
    self.store = store
    _shellState = ObservedObject(wrappedValue: store.rootPresentation)
  }

  func body(content: Content) -> some View {
    content
      .alert(
        String(localized: "工作台数据恢复"),
        isPresented: persistenceRecoveryAlertPresented,
        actions: persistenceRecoveryAlertActions,
        message: persistenceRecoveryAlertMessage
      )
      .confirmationDialog(
        String(localized: "重置为空白工作台？"),
        isPresented: $isPersistenceResetConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button(String(localized: "归档后重置"), role: .destructive) {
          resetPersistenceAfterConfirmation()
        }
        Button(String(localized: "取消"), role: .cancel) {}
      } message: {
        Text("这会归档当前无法读取的数据文件，然后保存一个空白工作台。请先导出故障文件或恢复其他备份；此操作不能自动还原旧工作台。")
      }
      .alert(item: $persistenceResetFeedback) { feedback in
        Alert(
          title: Text(feedback.title),
          message: Text(feedback.message),
          dismissButton: .default(Text("好"))
        )
      }
  }

  private var persistenceRecoveryAlertPresented: Binding<Bool> {
    Binding(
      get: { shellState.persistenceRecoveryMessage != nil },
      set: {
        if !$0 && !shellState.isPersistenceRecoveryWriteProtected {
          store.dismissPersistenceRecoveryMessage()
        }
      }
    )
  }

  @ViewBuilder
  private func persistenceRecoveryAlertActions() -> some View {
    if shellState.isPersistenceRecoveryWriteProtected {
      Button(String(localized: "恢复其他备份…")) {
        guard let sourceURL = WorkbenchRecoverySelectionPanel.chooseSnapshot() else { return }
        if store.installPersistenceRecoverySnapshot(from: sourceURL) {
          NSApp.terminate(nil)
        }
      }
      Button(String(localized: "导出故障文件…")) {
        guard let directoryURL = WorkbenchRecoverySelectionPanel.chooseExportDirectory() else {
          return
        }
        _ = store.exportPersistenceRecoveryFiles(to: directoryURL)
      }
      Button(String(localized: "重置为空白工作台"), role: .destructive) {
        isPersistenceResetConfirmationPresented = true
      }
    } else {
      Button(String(localized: "继续")) {
        store.dismissPersistenceRecoveryMessage()
      }
    }
  }

  private func persistenceRecoveryAlertMessage() -> some View {
    Text(persistenceRecoveryMessage)
  }

  private func resetPersistenceAfterConfirmation() {
    switch store.resetPersistenceAfterUnrecoverableSnapshotResult() {
    case .reset(let archiveURL):
      persistenceResetFeedback = .success(archiveURL: archiveURL)
    case .failed(let archiveURL, let message):
      let archiveDetail =
        archiveURL.map {
          String(format: String(localized: "故障数据已归档到：%@\n\n"), $0.path)
        } ?? ""
      persistenceResetFeedback = .failure(
        message: archiveDetail + message
      )
    }
  }

  private var persistenceRecoveryMessage: String {
    shellState.persistenceRecoveryMessage ?? ""
  }

}

struct PersistenceRecoveryResetFeedback: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  static func success(archiveURL: URL) -> Self {
    Self(
      title: String(localized: "已重置为空白工作台"),
      message: String(
        format: String(localized: "故障数据已归档到：%@"),
        archiveURL.path
      )
    )
  }

  static func failure(message: String) -> Self {
    Self(
      title: String(localized: "未能重置工作台"),
      message: message
    )
  }
}
