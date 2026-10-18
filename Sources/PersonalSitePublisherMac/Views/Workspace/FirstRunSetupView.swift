import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum FirstRunSetupPath: String, CaseIterable, Identifiable {
  case connectExistingRepository
  case cloneRemoteRepository
  case localDrafts

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connectExistingRepository:
      return String(localized: "连接已有仓库")
    case .cloneRemoteRepository:
      return String(localized: "从 GitHub/GitLab 克隆")
    case .localDrafts:
      return String(localized: "暂不配置站点")
    }
  }

  var detail: String {
    switch self {
    case .connectExistingRepository:
      return String(localized: "选择已有的本地站点仓库，应用会按你选择的绝对路径读取配置并导入文章。")
    case .cloneRemoteRepository:
      return String(localized: "输入 HTTPS 仓库地址，选择保存位置，克隆完成后再确认站点规则。")
    case .localDrafts:
      return String(localized: "先写本地 Markdown 草稿，不要求仓库、站点类型或发布配置。")
    }
  }

  var systemImage: String {
    switch self {
    case .connectExistingRepository:
      return "externaldrive.badge.checkmark"
    case .cloneRemoteRepository:
      return "square.and.arrow.down"
    case .localDrafts:
      return "square.and.pencil"
    }
  }

  var accessibilityTitle: String { title }

  var destination: FirstRunSetupDestination {
    switch self {
    case .connectExistingRepository, .cloneRemoteRepository:
      return .repositoryWizard
    case .localDrafts:
      return .localDrafts
    }
  }
}

enum FirstRunSetupDestination: Equatable {
  case repositoryWizard
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

enum FirstRunRepositoryHandoffPresentation {
  static func profileForPreparation(
    original: SiteProfile, current: SiteProfile, isRetry: Bool
  ) -> SiteProfile? {
    guard original.id == current.id, isRetry || original == current else { return nil }
    return current
  }

  static func state(
    result: LocalContentImportOperationResult,
    drafts: [ArticleDraft],
    profileID: UUID
  ) -> FirstRunRepositoryHandoffState {
    switch result.outcome {
    case .succeeded, .partial:
      let availableDrafts = drafts.filter {
        !$0.isGeneralDraft && $0.belongs(toSiteProfileID: profileID)
      }.sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id.uuidString < $1.id.uuidString
      }
      return .ready(
        insertedCount: result.summary.insertedCount,
        availableCount: availableDrafts.count,
        latestDraftID: availableDrafts.first?.id,
        hasWarnings: result.outcome == .partial
      )
    case .cancelled:
      return .cancelled
    case .failed, .recorded, .observed:
      return .failed
    }
  }
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

}
private struct FirstRunSetupPathCard: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let path: FirstRunSetupPath
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: path.systemImage)
          .font(.workbenchTitle3)
          .foregroundStyle(isSelected ? workbenchAccentColor : Color.secondary)

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(workbenchAccentColor)
            .accessibilityHidden(true)
        }
      }

      Text(path.title)
        .font(.workbenchBody.weight(.semibold))
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)

      Text(path.detail)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
    .padding(WorkbenchSpacing.content)
    .background {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .fill(
          isSelected
            ? workbenchAccentColor.opacity(0.10)
            : Color.secondary.opacity(0.08)
        )
    }
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(
          isSelected
            ? workbenchAccentColor.opacity(0.60)
            : Color.secondary.opacity(0.18),
          lineWidth: isSelected ? 1.5 : 1
        )
    }
  }
}

struct FirstRunSetupView: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let store: WorkbenchStore
  let finish: (FirstRunSetupCompletion) -> FirstRunSetupCommitResult
  let skip: () -> Void

  @State private var selectedPath: FirstRunSetupPath?
  @State private var isRepositorySetupActive = false
  @State private var step: Step = .repository
  @State private var stagedProfile: FirstRunSetupProfileStaging?
  @State private var autoConfigurationProposal: RepositoryAutoConfigurationProposal?
  @State private var repositoryDetectionID: UUID?
  @State private var isPreparingRepository = false
  @State private var repositoryMessage: String?
  @State private var remoteRepositoryURL = ""
  @State private var cloneParentURL: URL?
  @State private var isCloningRepository = false
  @State private var cloneTask: Task<Void, Never>?
  @State private var completionMessage: String?
  @State private var requiresSamePathRetry = false
  @State private var isCommitConfirmationPresented = false
  @State private var showsAdvancedPublishingRules = false
  @State private var showsContentRules = false

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
          .padding(.bottom, WorkbenchSpacing.content)
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
      Text("这会应用上方预览的站点与发布规则，并保存你选择的本地仓库。返回或取消不会保存这些改动。")
    }
    .onDisappear { cloneTask?.cancel() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "leaf.fill")
          .font(.workbenchTitle2)
          .foregroundStyle(.workbenchSecondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(
            !isRepositorySetupActive
              ? String(localized: "开始使用")
              : String(localized: "设置个人网站发布流程")
          )
          .font(.workbenchTitle3.weight(.semibold))
          Text(
            !isRepositorySetupActive
              ? String(localized: "先选择你现在要做的事，站点配置可以稍后补充。")
              : String(localized: "只配置当前路径需要的信息，之后可以随时在设置中修改。")
          )
          .font(.workbenchBody)
          .foregroundStyle(.workbenchSecondary)
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
                .workbenchTruncatedTitle(candidate.accessibilityTitle)
            }
            .font(.workbenchMetadata.weight(candidate == step ? .semibold : .regular))
            .foregroundStyle(
              candidate.rawValue <= step.rawValue ? WorkbenchTheme.progress : Color.secondary)

            if candidate != Step.allCases.last {
              Rectangle()
                .fill(
                  candidate.rawValue < step.rawValue
                    ? WorkbenchTheme.progress : Color.secondary.opacity(0.25)
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

      // One column per path, so removing or adding a path never leaves an
      // empty slot in the grid.
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: 12),
          count: FirstRunSetupPath.allCases.count
        ),
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
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }

      if selectedPath == .cloneRemoteRepository {
        cloneRepositoryControls
      } else {
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
      }

      if isPreparingRepository || isCloningRepository {
        ProgressView(
          isCloningRepository
            ? String(localized: "正在克隆仓库…")
            : String(localized: "正在读取仓库配置…")
        )
        .controlSize(.small)
      } else if let repositoryMessage {
        AccessibleStatusMessage(message: repositoryMessage, severity: .error)
      }
    }
  }

  private var cloneRepositoryControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("GitHub/GitLab HTTPS 仓库地址", text: $remoteRepositoryURL)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .accessibilityLabel("GitHub/GitLab HTTPS 仓库地址")
        .accessibilityIdentifier("first-run-clone-url")

      HStack {
        Button("选择保存位置…") {
          chooseCloneParent()
        }
        .disabled(isCloningRepository || isPreparingRepository)
        if let cloneParentURL {
          Text(cloneParentURL.path)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      Button("克隆仓库") {
        cloneRepository()
      }
      .workbenchProminentActionStyle()
      .disabled(
        FirstRunRepositoryCloneSource(text: remoteRepositoryURL) == nil
          || cloneParentURL == nil || isCloningRepository || isPreparingRepository
      )
      .accessibilityIdentifier("first-run-clone-repository")

      Text("克隆仅写入你选择位置中的新文件夹；完成前不会保存站点配置。私有仓库需由系统 Git 凭据支持。")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
    }
  }

  private var publishingRulesStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      if isRuleDetectionComplete {
        stepTitle(
          String(localized: "确认发布规则"),
          detail: String(localized: "已识别网站生成器、文章头信息和保存路径；确认无误即可完成，需要时再展开调整。")
        )
      } else {
        stepTitle(
          String(localized: "确认自动探测的发布规则"),
          detail: String(localized: "检查网站生成器、文章头信息和保存路径；远端发布方式可在进阶设置中调整。")
        )
      }

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

      DisclosureGroup(
        String(localized: "调整内容规则"),
        isExpanded: Binding(
          get: { !isRuleDetectionComplete || showsContentRules },
          set: { showsContentRules = $0 }
        )
      ) {
        GroupBox("内容规则") {
          VStack(alignment: .leading, spacing: 12) {
            Picker("网站生成器", selection: siteKindBinding) {
              ForEach(SiteKind.allCases) { kind in
                Text(kind.localizedDisplayName).tag(kind)
              }
            }
            .accessibilityHint("选择当前网站使用的静态站点生成器")

            Picker("文章头信息格式", selection: frontMatterStyleBinding) {
              ForEach(FrontMatterStyle.allCases) { style in
                Text(style == .toml ? "TOML" : "YAML").tag(style)
              }
            }

            TextField("内容目录", text: contentRootBinding)
              .accessibilityLabel("内容目录")
            TextField("文章路径", text: markdownPathPatternBinding)
              .accessibilityLabel("文章路径")

            if let path = FirstRunRulePreviewPresentation.markdownPath(profile: setupProfile) {
              VStack(alignment: .leading, spacing: 4) {
                Text("示例文件：\(path)")
                  .font(.workbenchMetadata.monospaced())
                  .textSelection(.enabled)
                  .accessibilityIdentifier("first-run-article-path-example")
                Text("以今天的日期和 my-first-post 为示例，仅预览路径，不创建文件。")
                  .font(.workbenchMetadata)
                  .foregroundStyle(.workbenchSecondary)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, WorkbenchSpacing.tight)
        }
      }
      .accessibilityIdentifier("first-run-content-rules")

      DisclosureGroup(String(localized: "进阶：远端发布方式"), isExpanded: $showsAdvancedPublishingRules) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("远端平台", selection: repositoryProviderBinding) {
            ForEach(RepositoryProvider.allCases) { provider in
              Text(provider.localizedDisplayName).tag(provider)
            }
          }
          .pickerStyle(.segmented)
          .tint(workbenchAccentColor)

          Picker("发布策略", selection: publishStrategyBinding) {
            ForEach(RepositoryPublishStrategy.allCases) { strategy in
              Text(strategy.localizedDisplayName).tag(strategy)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, WorkbenchSpacing.tight)
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

  private var footer: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Button(String(localized: "稍后再选")) {
          repositoryDetectionID = nil
          skip()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .foregroundStyle(.workbenchSecondary)
        .disabled(requiresSamePathRetry)

        Text(
          !isRepositorySetupActive
            ? String(localized: "下次启动仍可从这里选择开始方式。")
            : String(localized: "退出后，本次向导中未完成的设置不会保存；已有工作台配置保持不变。之后可重新设置。")
        )
        .font(.workbenchSupporting)
        .foregroundStyle(.workbenchSecondary)
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
            cloneTask?.cancel()
            cloneTask = nil
            isRepositorySetupActive = false
            stagedProfile = nil
            autoConfigurationProposal = nil
            repositoryDetectionID = nil
            isPreparingRepository = false
            isCloningRepository = false
            repositoryMessage = nil
          }
        } else {
          Button("上一步") {
            step = Step(rawValue: step.rawValue - 1) ?? .repository
          }
        }

        Button(
          step == .rules
            ? String(localized: "完成并开始写作")
            : String(localized: "下一步")
        ) {
          if step == .rules {
            isCommitConfirmationPresented = true
          } else {
            step = Step(rawValue: step.rawValue + 1) ?? .rules
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
    .padding(WorkbenchSpacing.content)
  }

  private func continueFromPathSelection() {
    guard let selectedPath else { return }
    switch selectedPath.destination {
    case .repositoryWizard:
      stagedProfile = FirstRunSetupProfileStaging(profile: store.activeProfile)
      autoConfigurationProposal = nil
      repositoryDetectionID = nil
      repositoryMessage = nil
      isCloningRepository = false
      isRepositorySetupActive = true
      step = .repository
    case .localDrafts:
      complete(FirstRunSetupCompletion(path: selectedPath, stagedProfile: nil))
    }
  }

  private func stepTitle(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.workbenchHeadline)
      Text(detail)
        .font(.workbenchBody)
        .foregroundStyle(.workbenchSecondary)
    }
  }

  private func setupSummary(systemImage: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.workbenchTitle3)
        .foregroundStyle(.workbenchSecondary)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.workbenchBody.weight(.semibold))
        Text(detail)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .textSelection(.enabled)
      }
    }
    .padding(WorkbenchSpacing.content)
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
      String(format: String(localized: "文章头信息格式：%@"), frontMatter),
      String(format: String(localized: "内容目录：%@"), proposal.contentRoot),
      String(format: String(localized: "文章路径：%@"), proposal.markdownPathPattern),
    ].joined(separator: "\n")
  }

  private var hasRepository: Bool {
    !setupProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  /// Detected rules need only a glance; the fields stay one click away.
  private var isRuleDetectionComplete: Bool {
    autoConfigurationProposal?.detectedKind != nil
      && autoConfigurationProposal?.isGitRepository == true
      && hasValidPublishingRules
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

  private func chooseRepository() {
    Task { @MainActor in
      guard let url = await RepositorySelectionPanel.chooseDirectory() else { return }
      stageRepository(url)
    }
  }

  private func chooseCloneParent() {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择克隆仓库的保存位置")
    panel.prompt = String(localized: "选择此位置")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    Task { @MainActor in
      if await WindowSheetPresenter.response(to: panel) == .OK {
        cloneParentURL = panel.url
      }
    }
  }

  private func cloneRepository() {
    guard let source = FirstRunRepositoryCloneSource(text: remoteRepositoryURL),
      let cloneParentURL, !isCloningRepository
    else { return }
    isCloningRepository = true
    repositoryMessage = nil
    cloneTask = Task { @MainActor in
      do {
        let url = try await FirstRunRepositoryCloneService.clone(source, in: cloneParentURL)
        guard !Task.isCancelled, isRepositorySetupActive,
          selectedPath == .cloneRemoteRepository
        else { return }
        isCloningRepository = false
        stageRepository(url, securityScopeURL: cloneParentURL)
      } catch {
        guard !Task.isCancelled else { return }
        repositoryMessage = error.localizedDescription
        isCloningRepository = false
      }
      cloneTask = nil
    }
  }

  private func stageRepository(_ url: URL, securityScopeURL: URL? = nil) {
    let detectionID = UUID()
    let fallbackProfile = setupProfile
    repositoryDetectionID = detectionID
    showsContentRules = false
    isPreparingRepository = true
    repositoryMessage = nil
    Task { @MainActor in
      let scopeURL = securityScopeURL ?? url
      let hasAccess = scopeURL.startAccessingSecurityScopedResource()
      defer { if hasAccess { scopeURL.stopAccessingSecurityScopedResource() } }
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
        path: selectedPath == .cloneRemoteRepository
          ? .cloneRemoteRepository : .connectExistingRepository,
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

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
      switch self {
      case .repository: "仓库"
      case .rules: "规则"
      }
    }

    var accessibilityTitle: String {
      switch self {
      case .repository: String(localized: "仓库")
      case .rules: String(localized: "发布规则")
      }
    }
  }
}
