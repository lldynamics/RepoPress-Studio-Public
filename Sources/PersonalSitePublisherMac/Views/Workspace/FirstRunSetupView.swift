import PublishingWorkbenchCore
import SwiftUI

enum FirstRunSetupPath: String, CaseIterable, Identifiable {
  case connectExistingRepository
  case createNewSite
  case localDrafts

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connectExistingRepository:
      return String(localized: "连接已有仓库")
    case .createNewSite:
      return String(localized: "创建新站点")
    case .localDrafts:
      return String(localized: "暂不配置站点")
    }
  }

  var detail: String {
    switch self {
    case .connectExistingRepository:
      return String(localized: "选择已有的本地站点仓库，应用会按你选择的绝对路径读取配置并导入文章。")
    case .createNewSite:
      return String(localized: "从模板开始创建站点，目录、Git 和部署可以在建站向导中逐步完成。")
    case .localDrafts:
      return String(localized: "先写本地 Markdown 草稿，不要求仓库、站点类型或发布配置。")
    }
  }

  var systemImage: String {
    switch self {
    case .connectExistingRepository:
      return "externaldrive.badge.checkmark"
    case .createNewSite:
      return "sparkles.rectangle.stack"
    case .localDrafts:
      return "square.and.pencil"
    }
  }

  var accessibilityTitle: String { title }

  var destination: FirstRunSetupDestination {
    switch self {
    case .connectExistingRepository:
      return .repositoryWizard
    case .createNewSite:
      return .siteStarter
    case .localDrafts:
      return .localDrafts
    }
  }
}

enum FirstRunSetupDestination: Equatable {
  case repositoryWizard
  case siteStarter
  case localDrafts
}

struct FirstRunSetupCompletion {
  let path: FirstRunSetupPath
  let stagedProfile: SiteProfile?
}

enum FirstRunSetupCommitResult: Equatable {
  case completed
  case failed(message: String, requiresSamePathRetry: Bool = false)
}

@MainActor
enum FirstRunSetupPersistenceCommit {
  static func apply(
    _ completion: FirstRunSetupCompletion,
    to store: WorkbenchStore
  ) -> FirstRunSetupCommitResult {
    switch completion.path.destination {
    case .repositoryWizard:
      guard let stagedProfile = completion.stagedProfile else {
        return .failed(
          message: String(localized: "首次设置数据不完整，请返回重新选择仓库。")
        )
      }
      guard store.commitActiveProfileSynchronously(stagedProfile) else {
        return .failed(message: persistenceFailureMessage(from: store))
      }
      return .completed
    case .siteStarter:
      return .completed
    case .localDrafts:
      store.prepareLocalDraftWorkspace()
    }

    let didFlush = store.saveCurrentStateSynchronously()
    guard
      didFlush,
      !store.isPersistenceRecoveryWriteProtected,
      !store.hasUnsavedChanges
    else {
      return .failed(
        message: persistenceFailureMessage(from: store),
        requiresSamePathRetry: true
      )
    }
    return .completed
  }

  private static func persistenceFailureMessage(from store: WorkbenchStore) -> String {
    let detail = store.lastSaveError?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let detail, !detail.isEmpty {
      return String(
        format: String(
          localized: "首次设置未能保存：%@。设置尚未标记为完成，请检查数据文件夹后重试。"
        ),
        detail
      )
    }
    return String(localized: "首次设置未能保存。设置尚未标记为完成，请检查数据文件夹后重试。")
  }
}

struct FirstRunSetupProfileStaging {
  private(set) var profile: SiteProfile

  init(profile: SiteProfile) {
    self.profile = profile
  }

  mutating func selectSiteKind(_ siteKind: SiteKind) {
    // Keep the same defaulting semantics as the Settings change preview, but
    // apply them to this value-only draft until the final confirmation.
    profile.applyPublishingDefaults(for: siteKind)
  }

  mutating func selectRepositoryProvider(_ provider: RepositoryProvider) {
    profile.repositoryProvider = provider
    profile.repositoryBaseURL = provider.defaultBaseURL
  }

  mutating func selectPublishStrategy(_ strategy: RepositoryPublishStrategy) {
    profile.repositoryPublishStrategy = strategy
  }

  mutating func selectRepositoryRoot(_ url: URL) {
    _ = profile.rememberLocalRepositoryRoot(url)
  }
}

private struct FirstRunSetupPathCard: View {
  let path: FirstRunSetupPath
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: path.systemImage)
          .font(.title3)
          .foregroundStyle(WorkbenchTheme.primary)

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(WorkbenchTheme.primary)
            .accessibilityHidden(true)
        }
      }

      Text(path.title)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)

      Text(path.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
    .padding(WorkbenchSpacing.section)
    .background {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .fill(
          isSelected
            ? WorkbenchTheme.primary.opacity(0.10)
            : Color.secondary.opacity(0.08)
        )
    }
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(
          isSelected
            ? WorkbenchTheme.primary.opacity(0.60)
            : Color.secondary.opacity(0.18),
          lineWidth: isSelected ? 1.5 : 1
        )
    }
  }
}

struct FirstRunSetupView: View {
  let store: WorkbenchStore
  let finish: (FirstRunSetupCompletion) -> FirstRunSetupCommitResult
  let skip: () -> Void

  @State private var selectedPath: FirstRunSetupPath?
  @State private var isRepositorySetupActive = false
  @State private var step: Step = .siteType
  @State private var stagedProfile: FirstRunSetupProfileStaging?
  @State private var isPreparingRepository = false
  @State private var repositoryMessage: String?
  @State private var completionMessage: String?
  @State private var requiresSamePathRetry = false
  @State private var isCommitConfirmationPresented = false

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      Group {
        if !isRepositorySetupActive {
          pathSelectionStep
        } else {
          switch step {
          case .siteType:
            siteTypeStep
          case .repository:
            repositoryStep
          case .publishing:
            publishingStep
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(WorkbenchSpacing.spacious)

      if let completionMessage {
        AccessibleStatusMessage(message: completionMessage, severity: .error)
          .padding(.horizontal, WorkbenchSpacing.spacious)
          .padding(.bottom, WorkbenchSpacing.section)
      }

      Divider()

      footer
    }
    .frame(width: 720, height: 600)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("首次设置")
    .confirmationDialog(
      String(localized: "应用设置并连接仓库？"),
      isPresented: $isCommitConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(String(localized: "应用并检查仓库")) {
        finishRepositorySetup()
      }
      Button(String(localized: "返回修改"), role: .cancel) {}
    } message: {
      Text("这会应用上方预览的站点与发布规则，并保存你选择的本地仓库。返回或取消不会保存这些改动。")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "leaf.fill")
          .font(.title2)
          .foregroundStyle(WorkbenchTheme.primary)

        VStack(alignment: .leading, spacing: 2) {
          Text(
            !isRepositorySetupActive
              ? String(localized: "开始使用")
              : String(localized: "设置个人网站发布流程")
          )
            .font(.title3.weight(.semibold))
          Text(
            !isRepositorySetupActive
              ? String(localized: "先选择你现在要做的事，站点配置可以稍后补充。")
              : String(localized: "只配置当前路径需要的信息，之后可以随时在设置中修改。")
          )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      if isRepositorySetupActive {
        HStack(spacing: 8) {
          ForEach(Step.allCases) { candidate in
            HStack(spacing: 6) {
              Image(systemName: candidate.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(candidate.rawValue + 1).circle.fill")
              Text(candidate.titleKey)
                .workbenchTruncatedIdentity(candidate.accessibilityTitle)
            }
            .font(.caption.weight(candidate == step ? .semibold : .regular))
            .foregroundStyle(candidate.rawValue <= step.rawValue ? WorkbenchTheme.primary : Color.secondary)

            if candidate != Step.allCases.last {
              Rectangle()
                .fill(candidate.rawValue < step.rawValue ? WorkbenchTheme.primary : Color.secondary.opacity(0.25))
                .frame(height: 1)
            }
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("设置进度")
        .accessibilityValue(
          String(localized: "第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步：\(step.accessibilityTitle)")
        )
      }
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var pathSelectionStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("选择开始方式", detail: "不需要先理解仓库结构；选择后只会看到这条路径需要的下一步。")

      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 12),
          GridItem(.flexible(), spacing: 12),
          GridItem(.flexible(), spacing: 12),
        ],
        spacing: 12
      ) {
        ForEach(FirstRunSetupPath.allCases) { path in
          Button {
            selectedPath = path
          } label: {
            FirstRunSetupPathCard(path: path, isSelected: selectedPath == path)
          }
          .buttonStyle(.plain)
          .disabled(requiresSamePathRetry)
          .accessibilityLabel(path.accessibilityTitle)
          .accessibilityValue(
            selectedPath == path
              ? String(localized: "已选择")
              : String(localized: "未选择")
          )
          .accessibilityHint(String(localized: "按空格或 Return 选择，再按 Return 继续"))
        }
      }

      if let selectedPath {
        setupSummary(
          systemImage: selectedPath.systemImage,
          title: selectedPath.title,
          detail: selectedPath.detail
        )
      }
    }
  }

  private var siteTypeStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("选择站点类型", detail: "应用会据此设置文章头信息（Front Matter）、文章目录和图片路径默认值。")

      Picker("站点生成器", selection: siteKindBinding) {
        ForEach(SiteKind.allCases) { kind in
          Text(kind.localizedDisplayName).tag(kind)
        }
      }
      .pickerStyle(.radioGroup)
      .accessibilityHint("选择当前网站使用的静态站点生成器")

      setupSummary(
        systemImage: "doc.text",
        title: setupProfile.siteKind.localizedDisplayName,
        detail: String(
          format: String(localized: "内容目录：%@"),
          setupProfile.contentRoot
        )
      )
      Text("这里只预览发布规则；点击最后的“完成并检查仓库”并再次确认后才会保存。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var repositoryStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("连接本地仓库", detail: "只会访问你主动选择的文件夹，并直接使用该仓库的绝对路径；主应用不启用 App Sandbox。")

      setupSummary(
        systemImage: hasRepository ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.questionmark",
        title: hasRepository ? String(localized: "本地仓库已连接") : String(localized: "尚未选择本地仓库"),
        detail: hasRepository
          ? setupProfile.localRepositoryRootPath
          : String(localized: "选择包含站点配置和内容目录的仓库根目录。")
      )

      if hasRepository {
        Text("仓库路径已暂存，将在最后确认后保存并扫描。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button {
        chooseRepository()
      } label: {
        Label(
          hasRepository
            ? String(localized: "更换本地仓库")
            : String(localized: "选择本地仓库"),
          systemImage: "folder.badge.plus"
        )
      }
      .workbenchProminentActionStyle()
      .disabled(isPreparingRepository)

      if isPreparingRepository {
        ProgressView("正在读取仓库配置…")
          .controlSize(.small)
      } else if let repositoryMessage {
        AccessibleStatusMessage(message: repositoryMessage, severity: .error)
      }
    }
  }

  private var publishingStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("选择发布方式", detail: "重要文章建议使用分支和 PR/MR，日常更新可以直接提交。")

      Picker("远端平台", selection: repositoryProviderBinding) {
        ForEach(RepositoryProvider.allCases) { provider in
          Text(provider.localizedDisplayName).tag(provider)
        }
      }
      .pickerStyle(.segmented)
      .tint(WorkbenchTheme.navigationSelection)

      Picker("发布策略", selection: publishStrategyBinding) {
        ForEach(RepositoryPublishStrategy.allCases) { strategy in
          Text(strategy.localizedDisplayName).tag(strategy)
        }
      }
      .pickerStyle(.radioGroup)

      setupSummary(
        systemImage: "checkmark.seal",
        title: String(localized: "准备完成"),
        detail: String(localized: "完成后会进入同步工作区并扫描仓库；发布前仍会要求检查和差异确认。")
      )
    }
  }

  private var footer: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Button(String(localized: "稍后再选")) {
          skip()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .foregroundStyle(.secondary)
        .disabled(requiresSamePathRetry)

        Text(
          !isRepositorySetupActive
            ? String(localized: "下次启动仍可从这三个入口开始。")
            : String(localized: "当前路径的设置会保留，可稍后在设置中继续修改。")
        )
          .font(.workbenchSupporting)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: 300, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      if !isRepositorySetupActive {
        Button("继续") {
          continueFromPathSelection()
        }
        .workbenchProminentActionStyle()
        .disabled(selectedPath == nil)
        .keyboardShortcut(.defaultAction)
      } else {
        if step == .siteType {
          Button("返回") {
            isRepositorySetupActive = false
            stagedProfile = nil
            repositoryMessage = nil
          }
        } else {
          Button("上一步") {
            step = Step(rawValue: step.rawValue - 1) ?? .siteType
          }
        }

        Button(
          step == .publishing
            ? String(localized: "完成并检查仓库")
            : String(localized: "下一步")
        ) {
          if step == .publishing {
            isCommitConfirmationPresented = true
          } else {
            step = Step(rawValue: step.rawValue + 1) ?? .publishing
          }
        }
        .workbenchProminentActionStyle()
        .disabled(step == .repository && !hasRepository)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
  }

  private func continueFromPathSelection() {
    guard let selectedPath else { return }
    switch selectedPath.destination {
    case .repositoryWizard:
      stagedProfile = FirstRunSetupProfileStaging(profile: store.activeProfile)
      isRepositorySetupActive = true
      step = .siteType
    case .siteStarter, .localDrafts:
      complete(FirstRunSetupCompletion(path: selectedPath, stagedProfile: nil))
    }
  }

  private func stepTitle(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func setupSummary(systemImage: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(WorkbenchTheme.primary)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(WorkbenchSpacing.section)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var hasRepository: Bool {
    !setupProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  private var setupProfile: SiteProfile {
    stagedProfile?.profile ?? store.activeProfile
  }

  private var siteKindBinding: Binding<SiteKind> {
    Binding(
      get: { setupProfile.siteKind },
      set: { siteKind in
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        staging.selectSiteKind(siteKind)
        stagedProfile = staging
      }
    )
  }

  private var repositoryProviderBinding: Binding<RepositoryProvider> {
    Binding(
      get: { setupProfile.repositoryProvider },
      set: { provider in
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        staging.selectRepositoryProvider(provider)
        stagedProfile = staging
      }
    )
  }

  private var publishStrategyBinding: Binding<RepositoryPublishStrategy> {
    Binding(
      get: { setupProfile.repositoryPublishStrategy },
      set: { strategy in
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        staging.selectPublishStrategy(strategy)
        stagedProfile = staging
      }
    )
  }

  private func chooseRepository() {
    guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
    isPreparingRepository = true
    repositoryMessage = nil
    var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
    staging.selectRepositoryRoot(url)
    stagedProfile = staging
    isPreparingRepository = false
    if hasRepository {
      step = .publishing
    } else {
      repositoryMessage = String(localized: "未能暂存仓库路径，请重新选择或检查文件夹是否存在。")
    }
  }

  private func finishRepositorySetup() {
    guard let stagedProfile else { return }
    complete(
      FirstRunSetupCompletion(
        path: .connectExistingRepository,
        stagedProfile: stagedProfile.profile
      )
    )
  }

  private func complete(_ completion: FirstRunSetupCompletion) {
    switch finish(completion) {
    case .completed:
      completionMessage = nil
      requiresSamePathRetry = false
    case .failed(let message, let requiresSamePathRetry):
      completionMessage = message
      self.requiresSamePathRetry = requiresSamePathRetry
    }
  }

  private enum Step: Int, CaseIterable, Identifiable {
    case siteType
    case repository
    case publishing

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
      switch self {
      case .siteType: "站点"
      case .repository: "仓库"
      case .publishing: "发布"
      }
    }

    var accessibilityTitle: String {
      switch self {
      case .siteType: String(localized: "站点")
      case .repository: String(localized: "仓库")
      case .publishing: String(localized: "发布")
      }
    }
  }
}
