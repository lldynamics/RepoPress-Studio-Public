import AppKit
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class WorkbenchLaunchCoordinator: ObservableObject {
  @Published private(set) var store: WorkbenchStore?
  @Published private(set) var browserBridge: KnowledgeBrowserBridge?

  private let persistence: WorkbenchPersistence
  private let knowledgeLibraryService: KnowledgeLibraryService
  private var didStart = false

  init(
    persistence: WorkbenchPersistence,
    knowledgeLibraryService: KnowledgeLibraryService
  ) {
    self.persistence = persistence
    self.knowledgeLibraryService = knowledgeLibraryService
  }

  func start() async {
    guard !didStart else { return }
    didStart = true

    let persistence = persistence
    let knowledgeLibraryService = knowledgeLibraryService
    let preparation = await Task.detached(priority: .utility) {
      let restoreOutcome = KnowledgeLibraryService.applyPendingRestoreIfNeeded(
        rootURL: knowledgeLibraryService.rootURL
      )
      let snapshotSource: WorkbenchInitialSnapshotSource
      do {
        snapshotSource = .preloaded(try persistence.loadWithRecovery())
      } catch {
        snapshotSource = .loadFailure(error.localizedDescription)
      }
      return WorkbenchLaunchPreparation(
        restoreOutcome: restoreOutcome,
        snapshotSource: snapshotSource
      )
    }.value

    guard !Task.isCancelled else { return }
    let workbenchStore = WorkbenchStore(
      persistence: persistence,
      initialSnapshotSource: preparation.snapshotSource,
      freshWorkspaceSeedPolicy: .softwareGuides,
      knowledgeLibraryService: knowledgeLibraryService
    )
    workbenchStore.knowledge.reportStartupRestoreOutcome(preparation.restoreOutcome)

    self.store = workbenchStore
    let browserBridge = KnowledgeBrowserBridge(
      knowledge: workbenchStore.knowledge,
      onOpenDocument: { [weak workbenchStore] _ in
        workbenchStore?.selectSection(.library)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }
    )
    self.browserBridge = browserBridge
  }
}

private struct WorkbenchLaunchPreparation: Sendable {
  let restoreOutcome: KnowledgeLibraryRestoreStartupOutcome
  let snapshotSource: WorkbenchInitialSnapshotSource
}

struct WorkbenchLaunchRootView: View {
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  @ObservedObject var storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  let onReady: (WorkbenchStore, KnowledgeBrowserBridge?) -> Void

  var body: some View {
    Group {
      if let store = coordinator.store {
        readyContent(store: store, browserBridge: coordinator.browserBridge)
      } else {
        VStack(spacing: 14) {
          ProgressView()
            .controlSize(.small)
          Text("正在准备工作台…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在准备工作台")
        .task {
          await coordinator.start()
        }
      }
    }
  }

  @ViewBuilder
  private func readyContent(
    store: WorkbenchStore,
    browserBridge: KnowledgeBrowserBridge?
  ) -> some View {
    if let browserBridge {
      ContentView(store: store)
        .environmentObject(browserBridge)
        .task {
          onReady(store, browserBridge)
          storeKitProEntitlementCoordinator.start(store: store)
          browserBridge.start()
        }
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
