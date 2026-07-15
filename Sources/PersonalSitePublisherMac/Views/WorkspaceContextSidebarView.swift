import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceUnifiedSidebar: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  let isAIInspectorSelected: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  let onSelectSection: (WorkspaceSection) -> Void
  let onOpenAIInspector: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceTaskNavigation(
        store: store,
        isAIInspectorSelected: isAIInspectorSelected,
        onSelectSection: onSelectSection,
        onOpenAIInspector: onOpenAIInspector
      )

      Divider()

      WorkspaceContextSidebar(
        store: store,
        isCompact: isCompact,
        contentHealthFilter: $contentHealthFilter,
        repositoryContextStage: $repositoryContextStage
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("工作区侧边栏")
    .accessibilityIdentifier("workspace-sidebar")
  }
}

struct WorkspaceContextSidebar: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage

  var body: some View {
    switch store.selectedSection.contextSidebarMode {
    case .writingDrafts:
      WritingDraftColumn(store: store, isCompact: isCompact)
    case .contentHealthFilters:
      contentHealthFilters
    case .repositoryStages:
      repositoryStages
    case .none:
      Color.clear
        .accessibilityHidden(true)
    }
  }

  private var contentHealthFilters: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(workspaceNavigationLocalizedKey("workspace.contentHealth"))
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.top, 12)

      contextButton("全站发布检查", systemImage: "checklist", isSelected: contentHealthFilter == .overview) {
        contentHealthFilter = .overview
      }
      contextButton("公开风险", systemImage: "exclamationmark.shield", isSelected: contentHealthFilter == .publicRisks) {
        contentHealthFilter = .publicRisks
      }
      contextButton("AI 修复队列", systemImage: "sparkles", isSelected: contentHealthFilter == .aiFixes) {
        contentHealthFilter = .aiFixes
      }
      contextButton("站点级问题", systemImage: "globe.badge.chevron.backward", isSelected: contentHealthFilter == .siteIssues) {
        contentHealthFilter = .siteIssues
      }
      contextButton("站点维护", systemImage: "wrench.and.screwdriver", isSelected: contentHealthFilter == .maintenance) {
        contentHealthFilter = .maintenance
      }

      Spacer()
    }
    .background(.bar)
    .accessibilityLabel("内容健康筛选")
  }

  private var repositoryStages: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(workspaceNavigationLocalizedKey("workspace.sync"))
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.top, 12)

      contextButton("本地仓库", systemImage: "externaldrive", isSelected: repositoryContextStage == .overview) {
        repositoryContextStage = .overview
      }
      if !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
        contextButton("变更", systemImage: "arrow.left.arrow.right", isSelected: repositoryContextStage == .changes) {
          repositoryContextStage = .changes
        }
        contextButton("写入与发布", systemImage: "paperplane", isSelected: repositoryContextStage == .publishing) {
          repositoryContextStage = .publishing
        }
        contextButton("本地预览", systemImage: "play.rectangle", isSelected: repositoryContextStage == .preview) {
          repositoryContextStage = .preview
        }
        contextButton("发布记录", systemImage: "clock.arrow.circlepath", isSelected: repositoryContextStage == .history) {
          repositoryContextStage = .history
        }
      }

      Spacer()
    }
    .background(.bar)
    .accessibilityLabel("同步阶段导航")
  }

  private func contextButton(
    _ title: LocalizedStringKey,
    systemImage: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .fill(WorkbenchTheme.primary.opacity(WorkbenchOpacity.accentBackground))
          }
        }
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? WorkbenchTheme.primary : Color.primary)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .padding(.horizontal, 8)
  }
}
