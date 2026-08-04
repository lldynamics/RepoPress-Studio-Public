import PublishingWorkbenchCore
import SwiftUI

struct SettingsConfigurationHealthCard: View {
  let profile: SiteProfile
  let aiProviderConfig: AIProviderConfig
  let repositoryTokenAvailability: KeychainTokenAvailability
  let aiTokenAvailability: KeychainTokenAvailability
  let privacySettings: PrivacyProtectionSettings
  let selectDestination: (SettingsConfigurationHealthDestination) -> Void

  private var requiredItems: [SettingsConfigurationHealthItem] {
    [
      repositoryItem,
      defaultRulesItem
    ]
  }

  private var allItems: [SettingsConfigurationHealthItem] {
    requiredItems + [repositoryTokenItem, aiKeyItem, privacyItem]
  }

  private var supportingItems: [SettingsConfigurationHealthItem] {
    Array(allItems.dropFirst(requiredItems.count))
  }

  private var unresolvedItems: [SettingsConfigurationHealthItem] {
    requiredItems.filter { !$0.isReady }
  }

  private var readyRequiredCount: Int {
    requiredItems.filter(\.isReady).count
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        statusSummary
        configurationSection(title: String(localized: "发布基础"), items: requiredItems)
        configurationSection(title: String(localized: "功能与权限"), items: supportingItems)
      }
      .padding(WorkbenchSpacing.content)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("配置状态")
    .accessibilityValue(
      String(localized: "\(readyRequiredCount)/\(requiredItems.count) 项基础配置已就绪")
    )
    .accessibilityIdentifier("configuration-health-settings")
  }

  private var statusSummary: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("当前站点")
          .font(.workbenchSectionTitle)
        summaryText
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Label(LocalizedStringKey(overallStatusText), systemImage: overallStatusImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(overallStatusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(overallStatusColor.opacity(0.12), in: Capsule())
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
  }

  private func configurationSection(
    title: String,
    items: [SettingsConfigurationHealthItem]
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.workbenchSectionTitle)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
        ForEach(items) { item in
          Button {
            selectDestination(item.destination)
          } label: {
            SettingsConfigurationHealthTile(item: item, showsActionIndicator: true)
          }
          .buttonStyle(
            WorkbenchFocusRingButtonStyle(cornerRadius: WorkbenchCornerRadius.card)
          )
          .accessibilityHint(item.actionTitle)
        }
      }
    }
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
      actionTitle: String(localized: "选择本地仓库"),
      identityValue: isReady ? path : nil
    )
  }

  private var repositoryTokenItem: SettingsConfigurationHealthItem {
    let detail: Text
    let state: SettingsConfigurationHealthState
    switch repositoryTokenAvailability.accessState {
    case .available:
      detail = Text("已保存，可用于线上发布")
      state = .ready
    case .missing:
      detail = Text("未保存，线上发布会受限")
      state = .info
    case .accessFailed:
      detail = Text(
        "操作失败：\(credentialAccessFailureMessage(repositoryTokenAvailability))"
      )
      state = .warning
    }
    return SettingsConfigurationHealthItem(
      title: "仓库访问令牌",
      detail: detail,
      systemImage: "key",
      state: state,
      destination: .repositoryToken,
      actionTitle: String(localized: "打开访问令牌设置")
    )
  }

  private var aiKeyItem: SettingsConfigurationHealthItem {
    let requiresKey = aiProviderConfig.requiresAPIKey
    let isReady = !requiresKey || aiTokenAvailability.hasToken
    let hasAccessFailure = requiresKey && aiTokenAvailability.accessState == .accessFailed
    return SettingsConfigurationHealthItem(
      title: "AI Key",
      detail: hasAccessFailure
        ? Text(
          "操作失败：\(credentialAccessFailureMessage(aiTokenAvailability))"
        )
        : (
          isReady
            ? (requiresKey ? Text("已保存，可生成建议") : Text("当前配置无需 API Key"))
            : Text("未保存，AI 功能会受限")
        ),
      systemImage: "sparkles",
      state: hasAccessFailure ? .warning : (isReady ? .ready : .info),
      destination: .aiKey,
      actionTitle: String(localized: "打开 AI 设置")
    )
  }

  private func credentialAccessFailureMessage(
    _ availability: KeychainTokenAvailability
  ) -> String {
    availability.accessFailureMessage ?? "Keychain"
  }

  private var defaultRulesItem: SettingsConfigurationHealthItem {
    let hasPublishingPaths = !profile.markdownPathPattern.trimmedForPublishing.isEmpty
      && !profile.imagePathPattern.trimmedForPublishing.isEmpty
      && !profile.publicImagePathPattern.trimmedForPublishing.isEmpty
      && !profile.dateFormat.trimmedForPublishing.isEmpty
    return SettingsConfigurationHealthItem(
      title: "发布规则",
      detail: hasPublishingPaths
        ? Text("\(profile.siteKind.localizedDisplayName) · 路径规则已配置")
        : Text("路径或日期规则缺失"),
      systemImage: "gearshape.2",
      state: hasPublishingPaths ? .ready : .warning,
      destination: .defaultRules,
      actionTitle: String(localized: "打开发布规则")
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

  private var overallStatusText: String {
    readyRequiredCount == requiredItems.count
      ? String(localized: "基础就绪")
      : String(localized: "需补配置")
  }

  private var overallStatusImage: String {
    readyRequiredCount == requiredItems.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
  }

  private var overallStatusColor: Color {
    readyRequiredCount == requiredItems.count ? WorkbenchTheme.success : WorkbenchTheme.warning
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
    let localizedTitle = Bundle.main.localizedString(forKey: item.title, value: item.title, table: nil)
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: item.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey(item.title))
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(localizedTitle)
        if let identityValue = item.identityValue {
          item.detail
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(identityValue, lineLimit: 2)
        } else {
          item.detail
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
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
    .padding(10)
    .frame(minHeight: 68)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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
  let identityValue: String?

  init(
    title: String,
    detail: Text,
    systemImage: String,
    state: SettingsConfigurationHealthState,
    destination: SettingsConfigurationHealthDestination,
    actionTitle: String,
    identityValue: String? = nil
  ) {
    id = title
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.state = state
    self.destination = destination
    self.actionTitle = actionTitle
    self.identityValue = identityValue
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
