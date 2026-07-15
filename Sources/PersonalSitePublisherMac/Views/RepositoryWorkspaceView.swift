import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorkspaceView: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var stage: RepositoryContextStage
  @FocusedValue(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @State var isContentMigrationPresented = false

  var body: some View {
    Group {
      if stage == .history {
        ReleaseHistoryDetailView(store: store)
      } else {
        repositoryContent
      }
    }
    .sheet(isPresented: $isContentMigrationPresented) {
      ContentMigrationAssistantView(store: store)
    }
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
            repositoryStageContent
          } else {
            repositoryScanRequiredState
          }
        } else {
          repositorySelectionEmptyState
        }
      }
      .padding(20)
    }
  }
}
