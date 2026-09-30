import AppKit
import PublishingSyncCore
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorkspaceView: View {
  @WorkspaceModuleVisibilityStorage var moduleVisibility
  @Environment(\.workbenchAccentColor) var workbenchAccentColor
  let store: WorkbenchStore
  @ObservedObject private var workspaceObservation: WorkbenchRepositoryWorkspaceObservationFacade
  @StateObject var externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator
  @Binding var stage: RepositoryContextStage
  @Binding var changedFileSelection: RepositoryChangedFileSelection?
  @ObservedObject var sourceSession: RepositoryHTMLSourceSession
  @Environment(\.openSettings) var openSettings
  @Environment(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @Environment(\.localSitePreviewCommandAction) var localSitePreviewCommandAction
  @Environment(\.settingsWorkspaceCommandAction) var settingsWorkspaceCommandAction
  @AppStorage("dataManagementRequestedSection") var dataManagementRequestedSection =
    DataManagementSection.migration.rawValue
  @State var isOverviewMoreToolsExpanded = false
  @State var pendingRepositoryCreationTarget: SiteOperationConfirmationTarget?
  @State var createsPrivateRepository = true
  @State var repositoryCreationFailureMessage: String?
  @State var pendingRemoteArticleImport: RemoteArticleImportConfirmation?
  @State var pendingRepositorySafeSyncConfirmation: RepositorySafeSyncConfirmation?
  @State var pendingRepositoryRebaseSyncConfirmation: RepositoryRebaseSyncConfirmation?

  init(
    store: WorkbenchStore,
    stage: Binding<RepositoryContextStage>,
    changedFileSelection: Binding<RepositoryChangedFileSelection?>,
    sourceSession: RepositoryHTMLSourceSession
  ) {
    self.store = store
    _workspaceObservation = ObservedObject(
      wrappedValue: store.repositoryWorkspaceObservation
    )
    _externalBrowserPreviewCoordinator = StateObject(
      wrappedValue: ExternalBrowserPreviewCoordinator(store: store)
    )
    _stage = stage
    _changedFileSelection = changedFileSelection
    _sourceSession = ObservedObject(wrappedValue: sourceSession)
  }

  var body: some View {
    VStack(spacing: 0) {
      if stage == .history || stage == .source, hasPendingRepositoryRecovery {
        repositoryWorkflowBanner
          .padding(.horizontal, 20)
          .padding(.top, 12)
      }
      if stage == .history {
        ReleaseHistoryDetailView(store: store)
      } else {
        Group {
          if stage == .source {
            RepositoryHTMLSourceWorkspaceView(store: store, session: sourceSession)
          } else {
            repositoryContent
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository-workspace")
      }
    }
    .sheet(item: $pendingRepositoryCreationTarget) { target in
      let profile = target.profile
      RemoteRepositoryCreationConfirmationView(
        siteName: profile.name,
        providerName: profile.repositoryProvider.localizedDisplayName,
        owner: profile.repoOwner,
        repositoryName: profile.repoName,
        createsPrivateRepository: $createsPrivateRepository,
        isCreating: store.isRemoteRepositoryChecking,
        failureMessage: repositoryCreationFailureMessage,
        cancelAction: {
          pendingRepositoryCreationTarget = nil
        },
        createAction: { createRepositoryFromConfirmation(target) }
      )
    }
    .sheet(item: $pendingRemoteArticleImport) { confirmation in
      RemoteArticleImportPreviewView(
        siteName: confirmation.target.profile.name,
        repositoryName: confirmation.target.profile.repositoryDisplayName,
        files: confirmation.files,
        cancelAction: {
          pendingRemoteArticleImport = nil
        },
        confirmAction: { repositoryPaths in
          let frozenPaths = repositoryPaths
          pendingRemoteArticleImport = nil
          Task { @MainActor in
            _ = await store.importRemoteArticleDraftsFromRepository(
              repositoryPaths: frozenPaths,
              expectedTarget: confirmation.target
            )
          }
        }
      )
    }
    .sheet(item: $pendingRepositorySafeSyncConfirmation) { confirmation in
      RepositorySafeSyncConfirmationView(
        confirmation: confirmation,
        isApplying: store.isLocalRepositoryBranchOperationRunning,
        feedback: store.publishActionFeedback,
        cancelAction: {
          pendingRepositorySafeSyncConfirmation = nil
        },
        confirmAction: {
          applyRepositorySafeSync(confirmation)
        }
      )
    }
    .sheet(item: $pendingRepositoryRebaseSyncConfirmation) { confirmation in
      RepositoryRebaseSyncConfirmationView(
        confirmation: confirmation,
        isApplying: store.isLocalRepositoryBranchOperationRunning,
        feedback: store.publishActionFeedback,
        cancelAction: {
          pendingRepositoryRebaseSyncConfirmation = nil
        },
        confirmAction: {
          applyRepositoryRebaseSync(confirmation)
        }
      )
    }
    .onChange(of: store.repositoryReport) { _, report in
      let reconciled = RepositoryChangedFileSelectionPresentation.reconciledSelection(
        changedFileSelection,
        localFiles: report?.changedFiles ?? [],
        remoteFiles: report?.remoteChangedFiles ?? []
      )
      if changedFileSelection != reconciled {
        changedFileSelection = reconciled
      }
    }
    .externalBrowserPreviewPresentation(coordinator: externalBrowserPreviewCoordinator)
    .onChange(of: store.activeProfile) {
      externalBrowserPreviewCoordinator.cancelPendingOpen()
      pendingRepositoryCreationTarget = nil
      pendingRemoteArticleImport = nil
      pendingRepositorySafeSyncConfirmation = nil
      pendingRepositoryRebaseSyncConfirmation = nil
    }
    .onDisappear {
      externalBrowserPreviewCoordinator.cancelPendingOpen()
    }
  }

  private var hasPendingRepositoryRecovery: Bool {
    store.repositoryOperationLifecycle?.isOperationInProgress == true
      || store.repositoryRebaseRecoveryContext != nil
      || store.repositoryRebaseRecoveryDiagnostic != nil
  }

  private var repositoryContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 5) {
          Text(repositoryPageTitle)
            .font(.workbenchPageTitle)
            .accessibilityAddTraits(.isHeader)
          Text(repositoryPageSubtitle)
            .font(.workbenchPageSubtitle)
            .foregroundStyle(.secondary)
        }

        repositoryPrimaryActions
        repositoryWorkflowBanner
        repositoryPrimaryContent
      }
      .workbenchOperationalPageLayout()
    }
    // Each page starts with its own viewport. Reusing a deeply scrolled lazy
    // stack for a shorter page can leave its content outside the visible area.
    .id(stage)
  }

  private var repositoryPageTitle: LocalizedStringKey {
    switch stage {
    case .changes:
      return "文件变更"
    case .overview, .source, .history:
      return "站点"
    }
  }

  private var repositoryPageSubtitle: LocalizedStringKey {
    switch stage {
    case .changes:
      return "先处理网站更新，再审阅这台 Mac 上的变化，确认后进入统一发布流程。"
    case .overview, .source, .history:
      return "管理仓库、图片资源和发布记录；最终写入与发布统一在发布流程中确认。"
    }
  }

  @ViewBuilder
  private var repositoryPrimaryContent: some View {
    if hasSelectedRepository {
      if store.repositoryReport != nil || stage == .overview {
        repositoryStageContent
      } else {
        repositoryScanRequiredState
      }
    } else {
      repositoryGettingStartedGuide
    }
  }

  private func createRepositoryFromConfirmation(_ target: SiteOperationConfirmationTarget) {
    let privateRepository = createsPrivateRepository
    repositoryCreationFailureMessage = nil
    Task { @MainActor in
      let result = await store.createRemoteRepositoryForActiveProfile(
        privateRepository: privateRepository,
        expectedTarget: target
      )
      guard pendingRepositoryCreationTarget?.id == target.id else { return }
      guard result != nil else {
        repositoryCreationFailureMessage = store.publishActionMessage
        return
      }
      store.refreshPublishPreviewInBackground()
      pendingRepositoryCreationTarget = nil
    }
  }

  func presentRemoteArticleImportPreview(_ files: [RepositoryChangedFile]) {
    let confirmation = RemoteArticleImportConfirmation(profile: store.activeProfile, files: files)
    pendingRemoteArticleImport = confirmation.files.isEmpty ? nil : confirmation
  }

  func presentRepositoryCreationConfirmation() {
    createsPrivateRepository = true
    repositoryCreationFailureMessage = nil
    pendingRepositoryCreationTarget = SiteOperationConfirmationTarget(profile: store.activeProfile)
  }

  private func applyRepositorySafeSync(_ confirmation: RepositorySafeSyncConfirmation) {
    Task { @MainActor in
      guard await store.applyRepositorySafeSync(confirmation) != nil else { return }
      pendingRepositorySafeSyncConfirmation = nil
    }
  }

  private func applyRepositoryRebaseSync(_ confirmation: RepositoryRebaseSyncConfirmation) {
    Task { @MainActor in
      let result = await store.applyRepositoryRebaseSync(confirmation)
      if result != nil || store.repositoryMergeConflictSession?.conflicts.isEmpty == false {
        pendingRepositoryRebaseSyncConfirmation = nil
      }
    }
  }

  func openDataManagement(_ section: DataManagementSection = .migration) {
    dataManagementRequestedSection = section.rawValue
    SettingsNavigation.present(
      destination: .data(SettingsDataDestination(rawValue: section.rawValue) ?? .migration),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }
}
