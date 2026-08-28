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

  mutating func applyAutoConfigurationProposal(
    _ proposal: RepositoryAutoConfigurationProposal,
    repositoryURL: URL
  ) {
    profile = proposal.applying(to: profile, repositoryURL: repositoryURL)
  }

  mutating func selectFrontMatterStyle(_ style: FrontMatterStyle) {
    profile.frontMatterStyle = style
  }

  mutating func setContentRoot(_ contentRoot: String) {
    profile.contentRoot = contentRoot.trimmedForPublishing
  }

  mutating func setMarkdownPathPattern(_ markdownPathPattern: String) {
    profile.markdownPathPattern = markdownPathPattern.trimmedForPublishing
  }

  mutating func selectAIConnection(_ connection: AIConnectionProfile) {
    profile.aiConnectionProfileID = connection.id
    profile.aiProviderConfig = connection.config
  }

  mutating func restoreAIConnection(from persistedProfile: SiteProfile) {
    profile.aiConnectionProfileID = persistedProfile.aiConnectionProfileID
    profile.aiProviderConfig = persistedProfile.aiProviderConfig
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
  @State private var step: Step = .repository
  @State private var stagedProfile: FirstRunSetupProfileStaging?
  @State private var autoConfigurationProposal: RepositoryAutoConfigurationProposal?
  @State private var selectedAIConnectionID: UUID?
  @State private var repositoryDetectionID: UUID?
  @State private var isPreparingRepository = false
  @State private var repositoryMessage: String?
  @State private var completionMessage: String?
  @State private var requiresSamePathRetry = false
  @State private var isCommitConfirmationPresented = false

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      ScrollView {
        Group {
          if !isRepositorySetupActive {
            pathSelectionStep
          } else {
            switch step {
            case .repository:
              repositoryStep
            case .rules:
              publishingRulesStep
            case .ai:
              aiAssistanceStep
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(WorkbenchSpacing.spacious)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
      Button(String(localized: "应用并开始写作")) {
        finishRepositorySetup()
      }
      Button(String(localized: "返回修改"), role: .cancel) {}
    } message: {
      Text("这会应用上方预览的站点、发布和可选 AI 关联规则，并保存你选择的本地仓库。返回或取消不会保存这些改动。")
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
              Image(
                systemName: candidate.rawValue < step.rawValue
                  ? "checkmark.circle.fill" : "\(candidate.rawValue + 1).circle.fill")
              Text(candidate.titleKey)
                .workbenchTruncatedIdentity(candidate.accessibilityTitle)
            }
            .font(.caption.weight(candidate == step ? .semibold : .regular))
            .foregroundStyle(
              candidate.rawValue <= step.rawValue ? WorkbenchTheme.primary : Color.secondary)

            if candidate != Step.allCases.last {
              Rectangle()
                .fill(
                  candidate.rawValue < step.rawValue
                    ? WorkbenchTheme.primary : Color.secondary.opacity(0.25)
                )
                .frame(height: 1)
            }
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("设置进度")
        .accessibilityValue(
          String(
            localized:
              "第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步：\(step.accessibilityTitle)")
        )
      }
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var pathSelectionStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle(
        String(localized: "选择开始方式"),
        detail: String(localized: "不需要先理解仓库结构；选择后只会看到这条路径需要的下一步。")
      )

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

  private var repositoryStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle(
        String(localized: "绑定你的博客仓库"),
        detail: String(localized: "选择仓库后会立即读取站点特征，在下一步给出可修改的发布规则。")
      )

      setupSummary(
        systemImage: hasRepository
          ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.questionmark",
        title: hasRepository ? String(localized: "本地仓库已连接") : String(localized: "尚未选择本地仓库"),
        detail: hasRepository
          ? setupProfile.localRepositoryRootPath
          : String(localized: "选择包含站点配置和内容目录的仓库根目录。")
      )

      if hasRepository {
        Text("仓库路径和检测结果仅暂存，完成前不会写入工作台配置。")
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
        ProgressView(String(localized: "正在读取仓库配置…"))
          .controlSize(.small)
      } else if let repositoryMessage {
        AccessibleStatusMessage(message: repositoryMessage, severity: .error)
      }
    }
  }

  private var publishingRulesStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      stepTitle(
        String(localized: "确认自动探测的发布规则"),
        detail: String(localized: "30 秒内完成：检查自动识别结果，必要时只改这四项。")
      )

      if let autoConfigurationProposal {
        setupSummary(
          systemImage: autoConfigurationProposal.detectedKind == nil
            ? "questionmark.folder" : "checkmark.seal.fill",
          title: autoConfigurationProposal.detectedKind?.localizedDisplayName
            ?? String(localized: "未识别站点类型"),
          detail: detectedRulesSummary(for: autoConfigurationProposal)
        )

        if !autoConfigurationProposal.isGitRepository {
          AccessibleStatusMessage(
            message: String(localized: "未在所选文件夹中发现 Git 仓库；可以先确认规则，但发布前需要初始化 Git。"),
            severity: .warning
          )
        }
      }

      GroupBox("内容规则") {
        VStack(alignment: .leading, spacing: 12) {
          Picker("SSG", selection: siteKindBinding) {
            ForEach(SiteKind.allCases) { kind in
              Text(kind.localizedDisplayName).tag(kind)
            }
          }
          .accessibilityHint("选择当前网站使用的静态站点生成器")

          Picker("Front Matter", selection: frontMatterStyleBinding) {
            ForEach(FrontMatterStyle.allCases) { style in
              Text(style == .toml ? "TOML" : "YAML").tag(style)
            }
          }

          TextField("内容目录", text: contentRootBinding)
            .accessibilityLabel("内容目录")
          TextField("文章路径", text: markdownPathPatternBinding)
            .accessibilityLabel("文章路径")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      }

      GroupBox("发布方式") {
        VStack(alignment: .leading, spacing: 12) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      }

      if !hasValidPublishingRules {
        AccessibleStatusMessage(
          message: String(
            localized: "内容目录和文章路径必须是仓库内的相对路径，且文章路径必须位于内容目录内并包含 {slug}。"
          ),
          severity: .error,
          movesAccessibilityFocusForUrgentStatus: false
        )
      }
    }
  }

  private var aiAssistanceStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle(
        String(localized: "开启 AI 辅助（可选）"),
        detail: String(localized: "可以直接开始写作；只有选择已有连接时，才会把它关联到这个站点。")
      )

      if store.aiConnectionProfiles.isEmpty {
        setupSummary(
          systemImage: "sparkles",
          title: String(localized: "稍后配置 AI"),
          detail: String(localized: "当前没有可复用的 AI 连接。完成后可在设置中添加；这里不会创建或保存 API Key。")
        )
      } else {
        Picker("AI 连接", selection: aiConnectionBinding) {
          Text("跳过此步骤（不更改）").tag(UUID?.none)
          ForEach(store.aiConnectionProfiles) { connection in
            Text(connection.name).tag(Optional(connection.id))
          }
        }
        .pickerStyle(.radioGroup)

        if let connection = selectedAIConnection {
          setupSummary(
            systemImage: "sparkles",
            title: connection.name,
            detail: connection.summary.isEmpty
              ? String(localized: "将仅关联现有连接；凭据仍由它原有的安全存储管理。")
              : connection.summary
          )
        } else {
          setupSummary(
            systemImage: "clock",
            title: String(localized: "跳过 AI 设置"),
            detail: String(localized: "本步骤不会修改已有连接或凭据，之后仍可在设置中调整。")
          )
        }
      }

      setupSummary(
        systemImage: "checkmark.seal",
        title: String(localized: "准备开始写作"),
        detail: String(localized: "完成后会进入同步工作区并扫描仓库；发布前仍会要求检查和差异确认。")
      )
    }
  }

  private var footer: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Button(String(localized: "稍后再选")) {
          repositoryDetectionID = nil
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
        if step == .repository {
          Button("返回") {
            isRepositorySetupActive = false
            stagedProfile = nil
            autoConfigurationProposal = nil
            selectedAIConnectionID = nil
            repositoryDetectionID = nil
            isPreparingRepository = false
            repositoryMessage = nil
          }
        } else {
          Button("上一步") {
            step = Step(rawValue: step.rawValue - 1) ?? .repository
          }
        }

        Button(
          step == .ai
            ? String(localized: "完成并开始写作")
            : String(localized: "下一步")
        ) {
          if step == .ai {
            isCommitConfirmationPresented = true
          } else {
            step = Step(rawValue: step.rawValue + 1) ?? .ai
          }
        }
        .workbenchProminentActionStyle()
        .disabled(
          (step == .repository && (!hasRepository || isPreparingRepository))
            || (step == .rules && !hasValidPublishingRules)
        )
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
      autoConfigurationProposal = nil
      selectedAIConnectionID = nil
      repositoryDetectionID = nil
      isRepositorySetupActive = true
      step = .repository
    case .siteStarter, .localDrafts:
      complete(FirstRunSetupCompletion(path: selectedPath, stagedProfile: nil))
    }
  }

  private func stepTitle(_ title: String, detail: String) -> some View {
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
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func detectedRulesSummary(
    for proposal: RepositoryAutoConfigurationProposal
  ) -> String {
    let evidence =
      proposal.evidence.isEmpty
      ? String(localized: "未发现明确特征；已使用安全默认值。")
      : proposal.evidence.joined(separator: " · ")
    let frontMatter = proposal.frontMatterStyle == .toml ? "TOML" : "YAML"
    return [
      evidence,
      String(format: String(localized: "Front Matter：%@"), frontMatter),
      String(format: String(localized: "内容目录：%@"), proposal.contentRoot),
      String(format: String(localized: "文章路径：%@"), proposal.markdownPathPattern),
    ].joined(separator: "\n")
  }

  private var hasRepository: Bool {
    !setupProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  private var hasValidPublishingRules: Bool {
    RepositoryPublishingRuleValidation.isValid(
      contentRoot: setupProfile.contentRoot,
      markdownPathPattern: setupProfile.markdownPathPattern
    )
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

  private var frontMatterStyleBinding: Binding<FrontMatterStyle> {
    Binding(
      get: { setupProfile.frontMatterStyle },
      set: { style in
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        staging.selectFrontMatterStyle(style)
        stagedProfile = staging
      }
    )
  }

  private var contentRootBinding: Binding<String> {
    Binding(
      get: { setupProfile.contentRoot },
      set: { contentRoot in
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        staging.setContentRoot(contentRoot)
        stagedProfile = staging
      }
    )
  }

  private var markdownPathPatternBinding: Binding<String> {
    Binding(
      get: { setupProfile.markdownPathPattern },
      set: { markdownPathPattern in
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        staging.setMarkdownPathPattern(markdownPathPattern)
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

  private var selectedAIConnection: AIConnectionProfile? {
    guard let connectionID = selectedAIConnectionID else { return nil }
    return store.aiConnectionProfiles.first { $0.id == connectionID }
  }

  private var aiConnectionBinding: Binding<UUID?> {
    Binding(
      get: { selectedAIConnectionID },
      set: { connectionID in
        selectedAIConnectionID = connectionID
        var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
        guard let connectionID,
          let connection = store.aiConnectionProfiles.first(where: { $0.id == connectionID })
        else {
          staging.restoreAIConnection(from: store.activeProfile)
          stagedProfile = staging
          return
        }
        staging.selectAIConnection(connection)
        stagedProfile = staging
      }
    )
  }

  private func chooseRepository() {
    guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
    let detectionID = UUID()
    let fallbackProfile = setupProfile
    repositoryDetectionID = detectionID
    isPreparingRepository = true
    repositoryMessage = nil
    Task { @MainActor in
      let proposal = await Task.detached(priority: .userInitiated) {
        LocalRepositoryService().autoConfigurationProposal(
          for: url,
          fallbackProfile: fallbackProfile
        )
      }.value
      guard repositoryDetectionID == detectionID, isRepositorySetupActive else { return }

      var staging = stagedProfile ?? FirstRunSetupProfileStaging(profile: store.activeProfile)
      staging.applyAutoConfigurationProposal(proposal, repositoryURL: url)
      stagedProfile = staging
      autoConfigurationProposal = proposal
      repositoryDetectionID = nil
      isPreparingRepository = false
      if hasRepository {
        step = .rules
      } else {
        repositoryMessage = String(localized: "未能暂存仓库路径，请重新选择或检查文件夹是否存在。")
      }
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
    case repository
    case rules
    case ai

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
      switch self {
      case .repository: "仓库"
      case .rules: "规则"
      case .ai: "AI"
      }
    }

    var accessibilityTitle: String {
      switch self {
      case .repository: String(localized: "仓库")
      case .rules: String(localized: "发布规则")
      case .ai: String(localized: "AI 辅助")
      }
    }
  }
}
