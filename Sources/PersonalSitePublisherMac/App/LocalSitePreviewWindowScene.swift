import PublishingWorkbenchCore
import SwiftUI

/// A single shared preview window leaves every workspace window interactive.
struct LocalSitePreviewWindowScene: Scene {
  static let id = "local-site-preview"

  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  let accentPalette: WorkbenchAccentPalette
  let appearanceMode: WorkbenchAppearanceMode
  let interfaceDensity: WorkbenchInterfaceDensity

  var body: some Scene {
    Window("本地站点预览", id: Self.id) {
      Group {
        if let store = coordinator.store {
          LocalSitePreviewWindowContent(store: store)
        } else {
          ProgressView()
        }
      }
      .frame(minWidth: 700, minHeight: 460)
      .tint(accentPalette.color)
      .environment(\.workbenchAccentColor, accentPalette.color)
      .preferredColorScheme(appearanceMode.colorScheme)
      .controlSize(interfaceDensity.controlSize)
      .task { await coordinator.start() }
    }
    .defaultSize(width: 900, height: 680)
    .windowResizability(.contentMinSize)
  }
}

private struct LocalSitePreviewWindowContent: View {
  let store: WorkbenchStore
  @StateObject private var state: WorkbenchLocalSitePreviewFeatureFacade

  init(store: WorkbenchStore) {
    self.store = store
    _state = StateObject(wrappedValue: WorkbenchLocalSitePreviewFeatureFacade(store: store))
  }

  var body: some View {
    // Closing this window releases its presentation, not the store's server.
    LocalSitePreviewPanelView(store: store, state: state)
  }
}
