import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct SiteStarterWorkspaceView: View {
  @ObservedObject var store: WorkbenchStore
  @SceneStorage("siteStarterSelectedStep") private var selectedStepRaw = SiteStarterWizardStep.template.rawValue
  @SceneStorage("siteStarterMode") private var modeRaw = SiteStarterMode.create.rawValue
  @State private var templateID: SiteStarterTemplateID = .zolaPersonalBlog
  @State private var rootPath = ""
  @State private var siteName = ""
  @State private var siteDescription = ""
  @State private var author = ""
  @State private var baseURL = ""
  @State private var branch = "main"
  @State private var githubOwner = ""
  @State private var githubRepo = ""
  @State private var deploymentTarget: SiteStarterDeploymentTarget = .githubPages
  @State private var deploymentProjectID = ""
  @State private var deploymentAccountID = ""
  @State private var initializesGit = true
  @State private var configuresOrigin = true
  @State private var createsPrivateRepository = false

  private var mode: SiteStarterMode {
    get { SiteStarterMode(rawValue: modeRaw) ?? .create }
    nonmutating set { modeRaw = newValue.rawValue }
  }

  private var selectedStep: SiteStarterWizardStep {
    get { SiteStarterWizardStep(rawValue: selectedStepRaw) ?? .template }
    nonmutating set { selectedStepRaw = newValue.rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      HSplitView {
        stepRail
          .frame(minWidth: 240, idealWidth: 270, maxWidth: 320, maxHeight: .infinity)

        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            selectedStepHeader
            selectedStepContent
            navigationBar
          }
          .padding(20)
          .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .disabled(store.isSiteStarterOperationRunning)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .onAppear {
      hydrateDefaults()
      selectedStep = SiteStarterWizardStep(rawValue: selectedStepRaw) ?? .template
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("建站向导")
          .font(.title2.weight(.semibold))
        Text("内置 \(SiteStarterTemplate.builtIn.count) 个模板，支持新建站点或导入已有仓库。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if store.isSiteStarterOperationRunning {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("建站操作正在后台运行")
      }

      if let message = store.publishActionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(.bar)
  }

  private var stepRail: some View {
    List(selection: Binding(
      get: { selectedStep },
      set: { step in
        if let step {
          selectedStep = step
        }
      }
    )) {
      Section("建站步骤") {
        ForEach(SiteStarterWizardStep.allCases) { step in
          SiteStarterWizardStepRow(
            step: step,
            status: status(for: step),
            detail: detail(for: step)
          )
          .tag(step)
        }
      }
    }
    .listStyle(.sidebar)
  }

  private var selectedStepHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(selectedStep.title, systemImage: selectedStep.systemImage)
        .font(.title3.weight(.semibold))

      Text(selectedStep.summary)
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        SiteStarterWizardStatusBadge(status: status(for: selectedStep))
        Text(detail(for: selectedStep))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  @ViewBuilder
  private var selectedStepContent: some View {
    switch selectedStep {
    case .template:
      SiteStarterTemplateStep(
        mode: Binding(
          get: { mode },
          set: { mode = $0 }
        ),
        templateID: $templateID,
        selectedTemplate: selectedTemplate,
        siteName: $siteName,
        siteDescription: $siteDescription,
        author: $author,
        baseURL: $baseURL,
        templateIndexDescription: templateIndexDescription
      )
    case .localDirectory:
      SiteStarterLocalDirectoryStep(
        mode: mode,
        rootPath: $rootPath,
        initializesGit: $initializesGit,
        configuresOrigin: $configuresOrigin,
        siteStarterResultProfilePath: store.siteStarterResult?.profile.localRepositoryRootPath,
        siteStarterImportProfilePath: store.siteStarterImportResult?.profile.localRepositoryRootPath,
        importedDraftCount: store.siteStarterImportResult?.importedDraftCount
      ) {
        if let url = RepositorySelectionPanel.chooseDirectory() {
          rootPath = url.path
        }
      }
    case .github:
      SiteStarterGitHubStep(
        githubOwner: $githubOwner,
        githubRepo: $githubRepo,
        branch: $branch,
        deploymentTarget: $deploymentTarget,
        deploymentProjectID: $deploymentProjectID,
        deploymentAccountID: $deploymentAccountID,
        createsPrivateRepository: $createsPrivateRepository,
        canCreateGitHubRepository: canCreateGitHubRepository,
        isRemoteRepositoryPublishing: store.isRemoteRepositoryPublishing,
        remoteRepositoryURL: store.remoteRepositoryCreationResult?.cloneURL,
        remoteRepositoryHTMLURL: store.remoteRepositoryCreationResult?.htmlURL,
        remoteRepositoryName: store.remoteRepositoryCreationResult?.repositoryName,
        createAction: createGitHubRepositoryFromWizard
      )
    case .generate:
      SiteStarterGenerateStep(
        isCreateMode: mode == .create,
        createAction: {
          if mode == .create {
            createStarterSite()
          } else {
            importExistingSite()
          }
        },
        disabled: !canCreateStarterSite,
        isRunning: store.isSiteStarterOperationRunning,
        createdFileCount: store.siteStarterResult?.createdFilePaths.count,
        createdProfileText: store.siteStarterResult?.profile.name,
        createdProfileKindText: store.siteStarterResult?.profile.siteKind.localizedDisplayName,
        guideText: store.siteStarterResult?.deploymentGuidePath,
        importedArticleCount: store.siteStarterImportResult?.importedDraftCount,
        skippedPathCount: store.siteStarterImportResult?.skippedPathCount
      )
    case .firstPush:
      SiteStarterFirstPushStep(
        canPushStarterSite: canPushStarterSite,
        pushAction: {
          Task {
            if await store.commitAndPushStarterSite() != nil {
              selectedStep = .deployment
            }
          }
        },
        pushBranch: store.siteStarterPushResult?.branch,
        pushSHA: store.siteStarterPushResult?.commitSHA,
        committedPathCount: store.siteStarterPushResult?.committedPaths.count,
        remoteURL: store.siteStarterPushResult?.remoteURL
      )
    case .deployment:
      SiteStarterDeploymentStep(
        deploymentTarget: deploymentTarget,
        deploymentGuidePath: store.siteStarterResult?.deploymentGuidePath,
        deploymentCommands: store.siteStarterResult?.nextCommands ?? [],
        deploymentStatusMessage: store.deploymentStatusMessage,
        copyCommands: copyStarterCommands
      )
    }
  }

  private var navigationBar: some View {
    HStack {
      Button {
        selectedStep = selectedStep.previous ?? selectedStep
      } label: {
        Label("上一步", systemImage: "chevron.left")
      }
      .disabled(selectedStep.previous == nil)

      Button {
        selectedStep = selectedStep.next ?? selectedStep
      } label: {
        Label("下一步", systemImage: "chevron.right")
      }
      .disabled(selectedStep.next == nil)

      Spacer()

      if let result = store.siteStarterResult {
        Button {
          copyStarterCommands(result.nextCommands)
        } label: {
          Label("复制命令", systemImage: "doc.on.doc")
        }
      }
    }
  }

  private var selectedTemplate: SiteStarterTemplate? {
    SiteStarterTemplate.builtIn.first { $0.id == templateID }
  }

  private var canCreateStarterSite: Bool {
    !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !siteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canCreateGitHubRepository: Bool {
    !githubOwner.trimmedForPublishing.isEmpty
      && !githubRepo.trimmedForPublishing.isEmpty
      && !branch.trimmedForPublishing.isEmpty
  }

  private var canPushStarterSite: Bool {
    store.siteStarterResult?.initializedGit == true
      && store.siteStarterResult?.configuredRemoteURL != nil
      && !store.isLocalRepositoryMutationRunning
  }

  private func status(for step: SiteStarterWizardStep) -> SiteStarterWizardStepStatus {
    if isStepComplete(step) {
      return .done
    }
    if selectedStep == step {
      return .active
    }
    if firstIncompleteStep == step {
      return .active
    }
    return .pending
  }

  private var firstIncompleteStep: SiteStarterWizardStep {
    SiteStarterWizardStep.allCases.first { !isStepComplete($0) } ?? .deployment
  }

  private func isStepComplete(_ step: SiteStarterWizardStep) -> Bool {
    switch step {
    case .template:
      return selectedTemplate != nil && !siteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .localDirectory:
      return store.siteStarterResult != nil || !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .github:
      if deploymentTarget == .none {
        return true
      }
      return store.siteStarterResult?.configuredRemoteURL != nil || store.remoteRepositoryCreationResult != nil
    case .generate:
      return mode == .create ? store.siteStarterResult != nil : store.siteStarterImportResult != nil
    case .firstPush:
      return deploymentTarget == .none || store.siteStarterPushResult != nil
    case .deployment:
      return deploymentTarget == .none || store.siteStarterPushResult != nil || store.siteStarterImportResult != nil
    }
  }

  private func detail(for step: SiteStarterWizardStep) -> String {
    switch step {
    case .template:
      return selectedTemplate.map { "\($0.name) · \($0.siteKind.localizedDisplayName)" } ?? "选择 Starter 模板"
    case .localDirectory:
      return store.siteStarterResult?.profile.localRepositoryRootPath.nilIfEmpty
        ?? rootPath.nilIfEmpty
        ?? "选择空文件夹"
    case .github:
      if let remote = store.siteStarterResult?.configuredRemoteURL {
        return remote
      }
      if let creation = store.remoteRepositoryCreationResult {
        return creation.repositoryName
      }
      if githubOwner.isEmpty && githubRepo.isEmpty {
        return deploymentTarget == .none ? "暂不部署" : "填写 owner/repo"
      }
      return "\(githubOwner)/\(githubRepo)"
    case .generate:
      if mode == .create {
        return store.siteStarterResult.map { "\($0.createdFilePaths.count) 个文件" } ?? "生成模板和首篇文章"
      }
      return store.siteStarterImportResult.map { "\($0.importedDraftCount) 篇文章" } ?? "导入已有仓库"
    case .firstPush:
      return store.siteStarterPushResult.map { "\($0.branch) · \($0.commitSHA.prefix(8))" } ?? "提交并推送 Starter"
    case .deployment:
      return deploymentTarget == .none ? "未启用部署" : deploymentTarget.localizedDisplayName
    }
  }

  private func hydrateDefaults() {
    if siteName.isEmpty {
      siteName = store.activeProfile.name
    }
    if author.isEmpty {
      author = store.activeProfile.defaultAuthor
    }
    if githubOwner.isEmpty {
      githubOwner = store.activeProfile.repoOwner
    }
    if githubRepo.isEmpty {
      githubRepo = store.activeProfile.repoName
    }
    if branch.isEmpty {
      branch = store.activeProfile.branch
    }
    if rootPath.isEmpty, let path = store.siteStarterResult?.profile.localRepositoryRootPath.nilIfEmpty {
      rootPath = path
    }
  }

  private func createStarterSite() {
    let request = SiteStarterRequest(
      templateID: templateID,
      rootPath: rootPath,
      siteName: siteName,
      siteDescription: siteDescription,
      author: author,
      baseURL: baseURL,
      branch: branch,
      githubOwner: githubOwner,
      githubRepositoryName: githubRepo,
      deploymentTarget: deploymentTarget,
      deploymentSiteURL: baseURL,
      deploymentProjectID: deploymentProjectID,
      deploymentAccountID: deploymentAccountID,
      initializeGit: initializesGit,
      configureOriginRemote: configuresOrigin
    )
    Task { @MainActor in
      if await store.createSiteFromStarter(request) != nil {
        store.selectSection(.siteStarter)
        selectedStep = deploymentTarget == .none ? .deployment : .github
      }
    }
  }

  private func importExistingSite() {
    let request = SiteStarterImportRequest(
      rootPath: rootPath,
      siteName: siteName,
      siteKind: selectedTemplate?.siteKind ?? .zola,
      author: author,
      branch: branch,
      githubOwner: githubOwner,
      githubRepositoryName: githubRepo,
      deploymentTarget: deploymentTarget,
      deploymentSiteURL: baseURL,
      deploymentProjectID: deploymentProjectID,
      deploymentAccountID: deploymentAccountID
    )
    Task { @MainActor in
      if await store.importExistingSiteFromStarter(request) != nil {
        store.selectSection(.siteStarter)
        selectedStep = .deployment
      }
    }
  }

  private func templateIndexDescription(_ template: SiteStarterTemplate) -> String {
    guard let index = SiteStarterTemplate.builtIn.firstIndex(where: { $0.id == template.id }) else {
      return "\(SiteStarterTemplate.builtIn.count) 个"
    }
    return "\(index + 1)/\(SiteStarterTemplate.builtIn.count)"
  }

  private func createGitHubRepositoryFromWizard() {
    syncGitHubInputsToActiveProfile()
    Task {
      if await store.createGitHubRepositoryForActiveProfile(privateRepository: createsPrivateRepository) != nil {
        selectedStep = .firstPush
      }
    }
  }

  private func syncGitHubInputsToActiveProfile() {
    let owner = githubOwner.trimmedForPublishing
    let repo = githubRepo.trimmedForPublishing
    let targetBranch = branch.trimmedForPublishing

    store.updateActiveProfile { profile in
      profile.repositoryProvider = .github
      profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
      profile.repoOwner = owner
      profile.repoName = repo
      profile.branch = targetBranch
    }
  }

  private func copyStarterCommands(_ commands: [String]) {
    ClipboardWriter.copy(
      commands.joined(separator: "\n"),
      successMessage: "已复制建站命令。"
    ) { store.setPublishActionMessage($0) }
  }
}
