import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryDefaultsSection: View {
  let localRepositoryPath: String
  let chooseLocalRepository: () -> Void
  let repositoryProviderBinding: Binding<RepositoryProvider>
  let repositoryProviderDisplayName: String
  let repositoryBaseURL: Binding<String>
  let ownerOrNamespace: Binding<String>
  let ownerOrNamespaceDisplayValue: String
  let repositoryRepoOrProject: Binding<String>
  let repositoryRepoOrProjectDisplayValue: String
  let branch: Binding<String>
  let branchDisplayValue: String
  let publishStrategyBinding: Binding<RepositoryPublishStrategy>
  let publishStrategyDisplayValue: String
  let publishStrategyDetail: String
  @State private var showsAdvancedConnectionSettings = false

  var body: some View {
    Section("连接必填") {
      LabeledContent("本地仓库") {
        HStack(spacing: 8) {
          Text(localRepositoryDisplayValue)
            .foregroundStyle(
              localRepositoryPath.trimmedForPublishing.isEmpty
                ? Color.secondary
                : Color.primary
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .help(localRepositoryDisplayValue)

          Button(
            localRepositoryPath.trimmedForPublishing.isEmpty
              ? String(localized: "选择…")
              : String(localized: "更改…")
          ) {
            chooseLocalRepository()
          }
          .controlSize(.small)
          .accessibilityLabel(
            localRepositoryPath.trimmedForPublishing.isEmpty
              ? String(localized: "选择本地仓库")
              : String(localized: "更改本地仓库")
          )
        }
      }
      .accessibilityValue(localRepositoryDisplayValue)

      Picker("平台", selection: repositoryProviderBinding) {
        ForEach(RepositoryProvider.allCases) { provider in
          Text(provider.localizedDisplayName).tag(provider)
        }
      }
      .accessibilityLabel("仓库平台")
      .accessibilityValue(repositoryProviderDisplayName)

      DisclosureGroup(String(localized: "高级连接设置"), isExpanded: $showsAdvancedConnectionSettings) {
        TextField(String(localized: "API 基础地址"), text: repositoryBaseURL)
          .accessibilityLabel("仓库 Base URL")
          .accessibilityValue(repositoryBaseURL.wrappedValue)

        Text("仓库 API 基础地址必须使用 HTTPS，且不能包含用户名、密码、查询参数（Query）或片段（Fragment）；不安全配置不会发送访问令牌。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      TextField(String(localized: "所有者 / 命名空间"), text: ownerOrNamespace)
        .accessibilityLabel("仓库 Owner 或 Namespace")
        .accessibilityValue(ownerOrNamespaceDisplayValue)

      TextField(String(localized: "仓库 / 项目"), text: repositoryRepoOrProject)
        .accessibilityLabel("仓库 Repo 或 Project")
        .accessibilityValue(repositoryRepoOrProjectDisplayValue)

      TextField(String(localized: "分支"), text: branch)
        .accessibilityLabel("仓库分支")
        .accessibilityValue(branchDisplayValue)

      Picker("发布策略", selection: publishStrategyBinding) {
        ForEach(RepositoryPublishStrategy.allCases) { strategy in
          Text(strategy.localizedDisplayName).tag(strategy)
        }
      }
      .accessibilityLabel("仓库发布策略")
      .accessibilityValue(publishStrategyDisplayValue)

      Text(publishStrategyDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var localRepositoryDisplayValue: String {
    localRepositoryPath.trimmedForPublishing.nilIfEmpty ?? String(localized: "未选择")
  }
}
