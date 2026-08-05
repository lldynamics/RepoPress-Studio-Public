import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorkspaceView: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var stage: RepositoryContextStage
  @ObservedObject var sourceSession: RepositoryHTMLSourceSession
  @Environment(\.openSettings) var openSettings
  @Environment(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @Environment(\.localSitePreviewCommandAction) var localSitePreviewCommandAction
  @AppStorage("settingsRequestedTabID") var requestedSettingsTabID = ""
  @AppStorage("dataManagementRequestedSection") var dataManagementRequestedSection = DataManagementSection.migration.rawValue
  @State var isRepositoryCreationConfirmationPresented = false
  @State var createsPrivateRepository = true
  @State var repositoryCreationFailureMessage: String?
  @State var pendingRemoteArticleImportFiles: [RepositoryChangedFile] = []

  var body: some View {
    VStack(spacing: 0) {
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
    .sheet(isPresented: $isRepositoryCreationConfirmationPresented) {
      let profile = store.activeProfile
      RemoteRepositoryCreationConfirmationView(
        providerName: profile.repositoryProvider.localizedDisplayName,
        owner: profile.repoOwner,
        repositoryName: profile.repoName,
        createsPrivateRepository: $createsPrivateRepository,
        isCreating: store.isRemoteRepositoryChecking,
        failureMessage: repositoryCreationFailureMessage,
        cancelAction: {
          isRepositoryCreationConfirmationPresented = false
        },
        createAction: createRepositoryFromConfirmation
      )
    }
    .sheet(isPresented: remoteArticleImportPreviewPresentation) {
      RemoteArticleImportPreviewView(
        files: pendingRemoteArticleImportFiles,
        cancelAction: {
          pendingRemoteArticleImportFiles = []
        },
        confirmAction: { repositoryPaths in
          _ = store.importRemoteArticleDraftsFromRepository(repositoryPaths: repositoryPaths)
          pendingRemoteArticleImportFiles = []
        }
      )
    }
  }

  private var repositoryContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
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

  private func createRepositoryFromConfirmation() {
    let privateRepository = createsPrivateRepository
    repositoryCreationFailureMessage = nil
    Task { @MainActor in
      let result = await store.createRemoteRepositoryForActiveProfile(
        privateRepository: privateRepository
      )
      store.refreshPublishPreviewInBackground()
      guard result != nil else {
        repositoryCreationFailureMessage = store.publishActionMessage
        return
      }
      isRepositoryCreationConfirmationPresented = false
    }
  }

  var remoteArticleImportPreviewPresentation: Binding<Bool> {
    Binding(
      get: { !pendingRemoteArticleImportFiles.isEmpty },
      set: { isPresented in
        if !isPresented {
          pendingRemoteArticleImportFiles = []
        }
      }
    )
  }

  func presentRemoteArticleImportPreview(_ files: [RepositoryChangedFile]) {
    pendingRemoteArticleImportFiles = files.filter { $0.kind != .deleted }
  }

  func openDataManagement(_ section: DataManagementSection = .migration) {
    dataManagementRequestedSection = section.rawValue
    requestedSettingsTabID = SettingsTab.dataManagement.id
    openSettings()
  }
}
