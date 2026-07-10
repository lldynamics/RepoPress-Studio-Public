import Foundation

public enum WorkbenchSettingsHealthState: String, Codable, Hashable, Sendable {
  case ready
  case warning
  case missing

  public var isBlocking: Bool {
    self == .missing
  }
}

public struct WorkbenchSettingsHealthItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var detail: String
  public var state: WorkbenchSettingsHealthState
  public var systemImage: String

  public init(
    id: String,
    title: String,
    detail: String,
    state: WorkbenchSettingsHealthState,
    systemImage: String
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.state = state
    self.systemImage = systemImage
  }
}

@MainActor
public final class WorkbenchSettingsHealthFeatureFacade {
  private unowned let store: WorkbenchStore

  init(store: WorkbenchStore) {
    self.store = store
  }

  public var items: [WorkbenchSettingsHealthItem] {
    let profile = store.activeProfile
    let repositoryConfigured = !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty
    let repositoryTokenReady = store.repositoryTokenAvailability.hasToken
    let aiRequiresKey = profile.aiProviderConfig.requiresAPIKey
    let aiReady = !aiRequiresKey || store.aiTokenAvailability.hasToken

    return [
      WorkbenchSettingsHealthItem(
        id: "repository",
        title: "仓库路径",
        detail: repositoryConfigured ? profile.localRepositoryRootPath : "尚未配置本地仓库",
        state: repositoryConfigured ? .ready : .missing,
        systemImage: "folder"
      ),
      WorkbenchSettingsHealthItem(
        id: "repository-token",
        title: "仓库 Token",
        detail: repositoryTokenReady ? "Token 已保存到 Keychain" : "远端发布、PR/MR 和部署检查需要 Token",
        state: repositoryTokenReady ? .ready : .warning,
        systemImage: "key"
      ),
      WorkbenchSettingsHealthItem(
        id: "ai-key",
        title: "AI Key",
        detail: aiReady ? "AI 文案和对话可用" : "当前 AI Provider 需要 API Key",
        state: aiReady ? .ready : .warning,
        systemImage: "sparkles"
      ),
      WorkbenchSettingsHealthItem(
        id: "defaults",
        title: "默认规则",
        detail: "\(profile.siteKind.displayName) 默认发布规则已载入",
        state: .ready,
        systemImage: "gearshape.2"
      ),
      WorkbenchSettingsHealthItem(
        id: "privacy",
        title: "隐私锁",
        detail: store.isPrivacyLocked ? "当前已锁定私密内容" : "私密内容遮挡规则已配置",
        state: .ready,
        systemImage: "hand.raised"
      ),
      WorkbenchSettingsHealthItem(
        id: "pro",
        title: "Pro 状态",
        detail: store.proStatusSummary.title,
        state: .ready,
        systemImage: "crown"
      )
    ]
  }

  public var blockingItems: [WorkbenchSettingsHealthItem] {
    items.filter { $0.state.isBlocking }
  }

  public var isReadyForDailyPublishing: Bool {
    blockingItems.isEmpty
  }
}
