import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  var hasSelectedRepository: Bool {
    !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  /// The overview dashboard needs a readable Git work tree; otherwise only the
  /// workflow banner explains what to do next.
  var showsRepositoryDashboard: Bool {
    store.repositoryReport?.hasGitDirectory != false
      && store.repositoryOperationLifecycle?.readFailure == nil
  }

  /// Mirrors the conditional sections of the overview's primary column.
  var hasRepositoryOverviewPrimaryContent: Bool {
    store.repository.scanState.isScanning || showsRepositoryMergeConflictContent
      || showsRepositoryDashboard
  }

  /// Mirrors what `repositoryMergeConflictSection` renders. A session can exist
  /// with nothing to show, for example while the repository cannot be read.
  var showsRepositoryMergeConflictContent: Bool {
    guard let session = store.repositoryMergeConflictSession else { return false }
    if !session.conflicts.isEmpty { return true }
    guard let lifecycle = session.operationLifecycle else { return false }
    return (lifecycle.isOperationInProgress && lifecycle.readFailure == nil)
      || store.repositoryRebaseRecoveryContext != nil
      || store.repositoryRebaseRecoveryDiagnostic != nil
  }

  var repositoryPrimaryActions: some View {
    // The page subtitle already explains where writes are confirmed.
    WorkbenchSectionGroup("常用操作") {
      WorkbenchFlowLayout(
        horizontalSpacing: WorkbenchSpacing.control,
        verticalSpacing: WorkbenchSpacing.control
      ) {
        Button {
          chooseRepository()
        } label: {
          Label(
            hasSelectedRepository ? String(localized: "重新选择仓库") : String(localized: "选择站点文件夹"),
            systemImage: "folder"
          )
        }
        .buttonStyle(.bordered)
        .disabled(
          store.repository.scanState.isScanning
            || store.isLocalRepositoryBranchOperationRunning
        )
        .accessibilityIdentifier("repository-action-select-folder")

        if store.repository.scanState.isScanning {
          Button {
            store.repository.cancelScan()
          } label: {
            Label("取消扫描", systemImage: "xmark.circle")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("repository-action-scan")
        } else {
          Button {
            scanRepository()
          } label: {
            Label(
              hasSelectedRepository ? String(localized: "重新扫描") : String(localized: "扫描仓库"),
              systemImage: "arrow.clockwise"
            )
          }
          .buttonStyle(.bordered)
          .disabled(
            !hasSelectedRepository
              || store.isLocalRepositoryBranchOperationRunning
          )
          .help(
            store.isLocalRepositoryBranchOperationRunning
              ? String(localized: "正在处理分支")
              : (hasSelectedRepository
                ? String(localized: "重新读取仓库结构、Git 状态和文件变化")
                : String(localized: "请先选择站点文件夹"))
          )
          .accessibilityIdentifier("repository-action-scan")
        }

        Button {
          Task {
            await store.importDraftsFromLocalRepositoryAsync()
          }
        } label: {
          Label("导入文章", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .disabled(
          !hasSelectedRepository
            || store.repository.scanState.isScanning
            || store.isLocalRepositoryBranchOperationRunning
        )
        .help(
          hasSelectedRepository
            ? String(localized: "将仓库中的文章导入写作列表")
            : String(localized: "请先选择站点文件夹")
        )
        .accessibilityIdentifier("repository-action-import")

        Button {
          openDataManagement(.migration)
        } label: {
          Label("数据管理", systemImage: "externaldrive")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("repository-action-data-management")

        if moduleVisibility.imagesEnabled {
          Button {
            store.selectSection(.images)
          } label: {
            Label("图片资源", systemImage: "photo.on.rectangle")
          }
          .buttonStyle(.bordered)
          .help("管理站点图片、问题引用与批量优化")
          .accessibilityIdentifier("repository-action-open-images")
        }

      }
      .controlSize(.regular)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-primary-actions")
  }

}
