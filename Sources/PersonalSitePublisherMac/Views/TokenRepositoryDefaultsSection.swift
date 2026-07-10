import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryDefaultsSection: View {
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

  var body: some View {
    Section("仓库默认") {
      Picker("平台", selection: repositoryProviderBinding) {
        ForEach(RepositoryProvider.allCases) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      .accessibilityLabel("仓库平台")
      .accessibilityValue(repositoryProviderDisplayName)

      TextField("Base URL", text: repositoryBaseURL)
        .accessibilityLabel("仓库 Base URL")
        .accessibilityValue(repositoryBaseURL.wrappedValue)

      TextField("Owner / Namespace", text: ownerOrNamespace)
        .accessibilityLabel("仓库 Owner 或 Namespace")
        .accessibilityValue(ownerOrNamespaceDisplayValue)

      TextField("Repo / Project", text: repositoryRepoOrProject)
        .accessibilityLabel("仓库 Repo 或 Project")
        .accessibilityValue(repositoryRepoOrProjectDisplayValue)

      TextField("Branch", text: branch)
        .accessibilityLabel("仓库分支")
        .accessibilityValue(branchDisplayValue)

      Picker("发布策略", selection: publishStrategyBinding) {
        ForEach(RepositoryPublishStrategy.allCases) { strategy in
          Text(strategy.displayName).tag(strategy)
        }
      }
      .accessibilityLabel("仓库发布策略")
      .accessibilityValue(publishStrategyDisplayValue)

      Text(publishStrategyDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
