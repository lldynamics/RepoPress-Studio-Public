import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsContext {
  let store: WorkbenchStore
  let storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  let activeProfileBinding: Binding<SiteProfile>
  let defaultShowsInspector: Binding<Bool>
  let autoRunPreflightBinding: Binding<Bool>
  let scanRepositoryOnLaunch: Binding<Bool>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID

  var actions: SettingsStoreActions {
    SettingsStoreActions(
      store: store,
      storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
    )
  }
}

enum SettingsTab: Hashable, CaseIterable, Identifiable {
  case defaultRules
  case token
  case ai
  case privacy
  case pro

  var id: String {
    switch self {
    case .defaultRules:
      return "defaultRules"
    case .token:
      return "token"
    case .ai:
      return "ai"
    case .privacy:
      return "privacy"
    case .pro:
      return "pro"
    }
  }

  var title: String {
    switch self {
    case .defaultRules:
      return "默认规则"
    case .token:
      return "Token"
    case .ai:
      return "AI"
    case .privacy:
      return "隐私"
    case .pro:
      return "Pro"
    }
  }

  var systemImage: String {
    switch self {
    case .defaultRules:
      return "gearshape.2"
    case .token:
      return "key"
    case .ai:
      return "sparkles"
    case .privacy:
      return "hand.raised"
    case .pro:
      return "crown"
    }
  }

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
