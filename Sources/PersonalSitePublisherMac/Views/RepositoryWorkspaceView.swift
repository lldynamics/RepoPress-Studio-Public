import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorkspaceView: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var stage: RepositoryContextStage
  @FocusedValue(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @State var isContentMigrationPresented = false
  @State var isRepositoryCreationConfirmationPresented = false
  @State var createsPrivateRepository = true
  @State var repositoryCreationFailureMessage: String?
  @State var pendingRemoteArticleImportFiles: [RepositoryChangedFile] = []

  var body: some View {
    VStack(spacing: 0) {
      repositoryStageNavigation
      Divider()

      Group {
        if stage == .history {
          ReleaseHistoryDetailView(store: store)
        } else {
          repositoryContent
        }
      }
    }
    .sheet(isPresented: $isContentMigrationPresented) {
      ContentMigrationAssistantView(store: store)
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

  private var repositoryStageNavigation: some View {
    HStack(spacing: 12) {
      Label("仓库流程", systemImage: "arrow.triangle.2.circlepath")
        .font(.callout.weight(.semibold))

      Picker("仓库阶段", selection: $stage) {
        ForEach(RepositoryContextStage.allCases) { item in
          Text(item.title)
            .tag(item)
            .disabled(item.requiresRepository && !hasSelectedRepository)
        }
      }
      .pickerStyle(.segmented)
      .tint(WorkbenchTheme.navigationSelection)
      .labelsHidden()
      .frame(maxWidth: 620)
      .accessibilityLabel("仓库阶段")
      .accessibilityValue(stage.accessibilityTitle)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var repositoryContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("本地仓库")
              .font(.title2.weight(.semibold))
            Text("只做文章发布需要的 Git：路径规则、diff 摘要和发布准备。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          if hasSelectedRepository {
            repositoryActionsMenu
          }
        }

        repositoryWorkflowBanner

        if hasSelectedRepository {
          if store.repositoryReport != nil || stage == .overview {
            AnyView(repositoryStageContent)
          } else {
            repositoryScanRequiredState
          }
        } else {
          repositorySelectionEmptyState
        }
      }
      .workbenchPageLayout()
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
}
