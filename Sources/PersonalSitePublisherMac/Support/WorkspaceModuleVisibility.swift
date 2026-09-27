import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceModuleVisibility: Equatable, Sendable {
  var rssEnabled = true
  var libraryEnabled = true
  var imagesEnabled = true

  static let rssEnabledKey = "workspaceModule.rssEnabledV1"
  static let libraryEnabledKey = "workspaceModule.libraryEnabledV1"
  static let imagesEnabledKey = "workspaceModule.imagesEnabledV1"

  func allows(_ section: WorkspaceSection) -> Bool {
    switch section {
    case .rss: return rssEnabled
    case .library: return libraryEnabled
    case .images: return imagesEnabled
    default: return true
    }
  }

  var primarySections: [WorkspaceSection] {
    WorkspaceNavigationRouteDescriptor.primarySections.filter(allows)
  }

  func resolvedSection(_ section: WorkspaceSection) -> WorkspaceSection {
    allows(section) ? section : .writing
  }

  func allowsSettingsTab(_ tab: SettingsTab) -> Bool {
    tab != .rss || rssEnabled
  }

  func resolvedSettingsRoute(_ route: SettingsRoute) -> SettingsRoute {
    allowsSettingsTab(route.tab) ? route : .subsection(.appearanceModules)
  }

  static func load(defaults: UserDefaults = .standard) -> Self {
    Self(
      rssEnabled: defaults.object(forKey: rssEnabledKey) as? Bool ?? true,
      libraryEnabled: defaults.object(forKey: libraryEnabledKey) as? Bool ?? true,
      imagesEnabled: defaults.object(forKey: imagesEnabledKey) as? Bool ?? true
    )
  }
}

@propertyWrapper
struct WorkspaceModuleVisibilityStorage: DynamicProperty {
  @AppStorage(WorkspaceModuleVisibility.rssEnabledKey)
  private var rssEnabled = true
  @AppStorage(WorkspaceModuleVisibility.libraryEnabledKey)
  private var libraryEnabled = true
  @AppStorage(WorkspaceModuleVisibility.imagesEnabledKey)
  private var imagesEnabled = true

  init(defaults: UserDefaults? = nil) {
    _rssEnabled = AppStorage(
      wrappedValue: true, WorkspaceModuleVisibility.rssEnabledKey, store: defaults)
    _libraryEnabled = AppStorage(
      wrappedValue: true, WorkspaceModuleVisibility.libraryEnabledKey, store: defaults)
    _imagesEnabled = AppStorage(
      wrappedValue: true, WorkspaceModuleVisibility.imagesEnabledKey, store: defaults)
  }

  var wrappedValue: WorkspaceModuleVisibility {
    get {
      WorkspaceModuleVisibility(
        rssEnabled: rssEnabled,
        libraryEnabled: libraryEnabled,
        imagesEnabled: imagesEnabled
      )
    }
    nonmutating set {
      rssEnabled = newValue.rssEnabled
      libraryEnabled = newValue.libraryEnabled
      imagesEnabled = newValue.imagesEnabled
    }
  }

  var projectedValue: Binding<WorkspaceModuleVisibility> {
    Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
  }
}
