import PublishingWorkbenchCore
import SwiftUI

struct SettingsConfigurationHealthCard: View {
  let profile: SiteProfile
  let aiProviderConfig: AIProviderConfig
  let repositoryTokenAvailability: KeychainTokenAvailability
  let aiTokenAvailability: KeychainTokenAvailability
  let selectDestination: (SettingsConfigurationHealthDestination) -> Void
  let isEmbedded: Bool

  init(
    profile: SiteProfile,
    aiProviderConfig: AIProviderConfig,
    repositoryTokenAvailability: KeychainTokenAvailability,
    aiTokenAvailability: KeychainTokenAvailability,
    selectDestination: @escaping (SettingsConfigurationHealthDestination) -> Void,
    isEmbedded: Bool = false
  ) {
    self.profile = profile
    self.aiProviderConfig = aiProviderConfig
    self.repositoryTokenAvailability = repositoryTokenAvailability
    self.aiTokenAvailability = aiTokenAvailability
    self.selectDestination = selectDestination
    self.isEmbedded = isEmbedded
  }

  private var requiredItems: [SettingsConfigurationHealthItem] {
    [
      repositoryItem,
      defaultRulesItem
    ]
  }

  private var unresolvedItems: [SettingsConfigurationHealthItem] {
    requiredItems.filter { !$0.isReady }
  }

  private var readyRequiredCount: Int {
    requiredItems.filter(\.isReady).count
  }

  var body: some View {
    Group {
      if isEmbedded {
        configurationContent
      } else {
        ScrollView {
          configurationContent
            .padding(WorkbenchSpacing.content)
        }
        .background(Color(nsColor: .windowBackgroundColor))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("配置状态")
    .accessibilityValue(
      String(localized: "\(readyRequiredCount)/\(requiredItems.count) 项基础配置已就绪")
    )
    .accessibilityIdentifier("configuration-health-settings")
  }

  private var configurationContent: some View {
    VStack(alignment: .leading, spacing: 20) {
      statusSummary
      configurationSection(
        title: String(localized: "本地发布（必需）"),
        items: requiredItems
      )
      configurationSection(
        title: String(localized: "线上发布（按需）"),
        items: [repositoryTokenItem]
      )
      configurationSection(
        title: String(localized: "AI 助手（按需）"),
        items: [aiKeyItem]
      )
    }
  }

  private var statusSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
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

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 6)
          Capsule()
            .fill(overallStatusColor)
            .frame(width: geo.size.width * CGFloat(readyRequiredCount) / CGFloat(max(1, requiredItems.count)), height: 6)
        }
      }
      .frame(height: 6)

      if let nextItem = unresolvedItems.first {
        HStack(alignment: .center, spacing: 10) {
          Text("下一步")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Text(LocalizedStringKey(nextItem.title))
            .font(.callout.weight(.medium))

          Spacer(minLength: 8)

          Button(nextItem.actionTitle) {
            selectDestination(nextItem.destination)
          }
          .workbenchProminentActionStyle()
          .accessibilityHint(nextItem.detail)
        }
      } else {
        Label("本地发布基础已经就绪，可按需继续配置线上发布与 AI。", systemImage: "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.success)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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
      title: "本地仓库",
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
      title: "线上仓库凭据",
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
      title: "AI 连接凭据",
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
      title: "内容与路径",
      detail: hasPublishingPaths
        ? Text("\(profile.siteKind.localizedDisplayName) · 路径规则已配置")
        : Text("路径或日期规则缺失"),
      systemImage: "gearshape.2",
      state: hasPublishingPaths ? .ready : .warning,
      destination: .defaultRules,
      actionTitle: String(localized: "打开发布规则")
    )
  }

  private var overallStatusText: String {
    readyRequiredCount == requiredItems.count
      ? String(localized: "可本地发布")
      : String(localized: "继续设置")
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
