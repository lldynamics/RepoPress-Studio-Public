import PublishingWorkbenchCore
import SwiftUI

struct SettingsConfigurationHealthCard: View {
  let profile: SiteProfile
  let repositoryTokenAvailability: KeychainTokenAvailability
  let aiTokenAvailability: KeychainTokenAvailability
  let privacySettings: PrivacyProtectionSettings
  let isProUnlocked: Bool
  let proSource: String
  let selectDestination: (SettingsConfigurationHealthDestination) -> Void
  @State private var isExpanded = false

  private var requiredItems: [SettingsConfigurationHealthItem] {
    [
      repositoryItem,
      defaultRulesItem
    ]
  }

  private var allItems: [SettingsConfigurationHealthItem] {
    requiredItems + [repositoryTokenItem, aiKeyItem, privacyItem, proItem]
  }

  private var unresolvedItems: [SettingsConfigurationHealthItem] {
    requiredItems.filter { !$0.isReady }
  }

  private var readyRequiredCount: Int {
    requiredItems.filter(\.isReady).count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("发布基础配置")
            .font(.headline)
          summaryText
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Label(LocalizedStringKey(overallStatusText), systemImage: overallStatusImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(overallStatusColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(overallStatusColor.opacity(0.12), in: Capsule())

        if isComplete {
          Button {
            isExpanded.toggle()
          } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(isExpanded ? "收起配置详情" : "展开配置详情")
        }
      }

      if !isComplete || isExpanded {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
          ForEach(isComplete ? allItems : unresolvedItems) { item in
            Button {
              selectDestination(item.destination)
            } label: {
              SettingsConfigurationHealthTile(item: item, showsActionIndicator: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.actionTitle)
          }
        }
      }
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("发布基础配置")
    .accessibilityValue("\(readyRequiredCount)/\(requiredItems.count) 项基础配置已就绪")
  }

  private var repositoryItem: SettingsConfigurationHealthItem {
    let path = profile.localRepositoryRootPath.trimmedForPublishing
    let isReady = profile.localRepositoryRootURL != nil
    return SettingsConfigurationHealthItem(
      title: "仓库路径",
      detail: isReady ? Text(verbatim: path) : Text("未选择本地仓库"),
      systemImage: "folder",
      state: isReady ? .ready : .warning,
      destination: .repository,
      actionTitle: String(localized: "选择本地仓库")
    )
  }

  private var repositoryTokenItem: SettingsConfigurationHealthItem {
    SettingsConfigurationHealthItem(
      title: "仓库 Token",
      detail: repositoryTokenAvailability.hasToken ? Text("已保存，可用于线上发布") : Text("未保存，线上发布会受限"),
      systemImage: "key",
      state: repositoryTokenAvailability.hasToken ? .ready : .info,
      destination: .repositoryToken,
      actionTitle: String(localized: "打开 Token 设置")
    )
  }

  private var aiKeyItem: SettingsConfigurationHealthItem {
    let requiresKey = profile.aiProviderConfig.requiresAPIKey
    let isReady = !requiresKey || aiTokenAvailability.hasToken
    return SettingsConfigurationHealthItem(
      title: "AI Key",
      detail: isReady
        ? (requiresKey ? Text("已保存，可生成建议") : Text("当前配置无需 API Key"))
        : Text("未保存，AI 功能会受限"),
      systemImage: "sparkles",
      state: isReady ? .ready : .info,
      destination: .aiKey,
      actionTitle: String(localized: "打开 AI 设置")
    )
  }

  private var defaultRulesItem: SettingsConfigurationHealthItem {
    let hasPublishingPaths = !profile.markdownPathPattern.trimmedForPublishing.isEmpty
      && !profile.imagePathPattern.trimmedForPublishing.isEmpty
      && !profile.publicImagePathPattern.trimmedForPublishing.isEmpty
      && !profile.dateFormat.trimmedForPublishing.isEmpty
    return SettingsConfigurationHealthItem(
      title: "默认规则",
      detail: hasPublishingPaths
        ? Text("\(profile.siteKind.localizedDisplayName) · 路径规则已配置")
        : Text("路径或日期规则缺失"),
      systemImage: "gearshape.2",
      state: hasPublishingPaths ? .ready : .warning,
      destination: .defaultRules,
      actionTitle: String(localized: "打开默认规则")
    )
  }

  private var privacyItem: SettingsConfigurationHealthItem {
    return SettingsConfigurationHealthItem(
      title: "内容遮挡",
      detail: privacySettings.masksPrivateContent ? Text("私密内容遮挡已开启") : Text("私密内容遮挡未开启"),
      systemImage: "hand.raised",
      state: privacySettings.masksPrivateContent ? .ready : .info,
      destination: .privacy,
      actionTitle: String(localized: "打开隐私设置")
    )
  }

  private var proItem: SettingsConfigurationHealthItem {
    SettingsConfigurationHealthItem(
      title: "Pro 状态",
      detail: isProUnlocked ? Text("\(proSource) 权益已生效") : Text("免费版，可按需升级"),
      systemImage: isProUnlocked ? "crown.fill" : "crown",
      state: isProUnlocked ? .ready : .info,
      destination: .pro,
      actionTitle: String(localized: "打开 Pro 设置")
    )
  }

  private var overallStatusText: String {
    readyRequiredCount == requiredItems.count
      ? String(localized: "基础就绪")
      : String(localized: "需补配置")
  }

  private var overallStatusImage: String {
    readyRequiredCount == requiredItems.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
  }

  private var overallStatusColor: Color {
    readyRequiredCount == requiredItems.count ? .green : .orange
  }

  private var isComplete: Bool {
    readyRequiredCount == requiredItems.count
  }

  private var summaryText: Text {
    isComplete
      ? Text("\(profile.name) · 路径与规则可用于本地发布")
      : Text("\(profile.name) · \(unresolvedItems.count) 项基础配置需要处理")
  }
}

private struct SettingsConfigurationHealthTile: View {
  let item: SettingsConfigurationHealthItem
  let showsActionIndicator: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: item.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey(item.title))
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        item.detail
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 0)

      Image(systemName: item.state.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(item.state.color)
        .padding(5)
        .background(item.state.color.opacity(0.12), in: Circle())
        .accessibilityHidden(true)

      if showsActionIndicator {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(LocalizedStringKey(item.title)))
    .accessibilityValue(item.detail)
  }
}

private struct SettingsConfigurationHealthItem: Identifiable {
  let id: String
  let title: String
  let detail: Text
  let systemImage: String
  let state: SettingsConfigurationHealthState
  let destination: SettingsConfigurationHealthDestination
  let actionTitle: String

  init(
    title: String,
    detail: Text,
    systemImage: String,
    state: SettingsConfigurationHealthState,
    destination: SettingsConfigurationHealthDestination,
    actionTitle: String
  ) {
    id = title
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.state = state
    self.destination = destination
    self.actionTitle = actionTitle
  }

  var isReady: Bool {
    state == .ready
  }
}

enum SettingsConfigurationHealthDestination: Hashable {
  case repository
  case repositoryToken
  case aiKey
  case defaultRules
  case privacy
  case pro
}

private enum SettingsConfigurationHealthState {
  case ready
  case warning
  case info

  var color: Color {
    switch self {
    case .ready:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return .secondary
    }
  }

  var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .info:
      return "info.circle"
    }
  }
}
