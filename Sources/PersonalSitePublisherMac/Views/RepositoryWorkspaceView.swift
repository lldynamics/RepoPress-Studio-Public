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
    GeometryReader { geometry in
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

          WorkbenchOperationalSplitLayout(
            usesSplitLayout: WorkbenchPageMetrics.usesOperationalSplit(for: geometry.size.width)
          ) {
            VStack(alignment: .leading, spacing: 16) {
              repositoryPrimaryContent
            }
          } context: {
            repositoryOperationalContextPanel
          }
        }
        .workbenchOperationalPageLayout()
      }
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
      repositorySelectionEmptyState
    }
  }

  private var repositoryOperationalContextPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("同步 Inspector", systemImage: "sidebar.right")
        .font(.headline)

      Label {
        Text(stage.title)
          .font(.callout.weight(.semibold))
      } icon: {
        Image(systemName: repositoryStageSystemImage)
          .foregroundStyle(WorkbenchTheme.navigationSelection)
      }

      if hasSelectedRepository {
        Text(store.activeProfile.localRepositoryRootPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .textSelection(.enabled)
      }

      Divider()

      if !hasSelectedRepository {
        Label("尚未选择本地仓库", systemImage: "externaldrive.badge.questionmark")
          .foregroundStyle(WorkbenchTheme.warning)
      } else if let issue = currentRepositoryIssue {
        VStack(alignment: .leading, spacing: 5) {
          SeverityBadge(severity: issue.severity)
          Text(issue.title)
            .font(.callout.weight(.medium))
          Text(issue.message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Label("没有仓库或发布阻断", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
      }

      Divider()

      InspectorStatRow(
        title: "文件变更",
        value: "\(store.repositoryReport?.changedFiles.count ?? 0)",
        systemImage: "doc.badge.ellipsis"
      )
      InspectorStatRow(
        title: "远端变更",
        value: "\(store.repositoryReport?.remoteChangedFiles.count ?? 0)",
        systemImage: "arrow.down.doc"
      )
      InspectorStatRow(
        title: "检查结果",
        value: "\(store.repositoryReport?.preflightIssues.count ?? 0)",
        systemImage: "checklist"
      )

      Divider()

      if !hasSelectedRepository {
        Button(action: chooseRepository) {
          Label("选择仓库", systemImage: "folder.badge.plus")
        }
        .workbenchProminentActionStyle()
      } else if store.repository.scanState.isScanning {
        Button(action: store.repository.cancelScan) {
          Label("取消扫描", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
      } else {
        Button(action: scanRepository) {
          Label("重新扫描", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("同步 Inspector")
  }

  private var currentRepositoryIssue: PreflightIssue? {
    let issues = store.repositoryReport?.preflightIssues ?? []
    return issues.first(where: { $0.severity == .error })
      ?? issues.first(where: { $0.severity == .warning })
  }

  private var repositoryStageSystemImage: String {
    switch stage {
    case .overview:
      "rectangle.grid.2x2"
    case .changes:
      "arrow.left.arrow.right"
    case .automation:
      "checkmark.shield"
    case .preview:
      "play.rectangle"
    case .history:
      "clock.arrow.circlepath"
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
