import SwiftUI

struct WorkbenchDataRootSetupView: View {
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "externaldrive.fill.badge.plus")
        .font(.system(size: WorkbenchIconSize.hero, weight: .medium))
        .foregroundStyle(.workbenchSecondary)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("设置数据文件夹")
          .font(.workbenchTitle2.weight(.semibold))
        Text("资料库、RSS、工作台和应用内附件会统一保存在这个文件夹。删除并重新安装应用后，再次选择它即可恢复。")
          .font(.workbenchBody)
          .foregroundStyle(.workbenchSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 540)
      }

      if let message = coordinator.dataRootMessage {
        AccessibleStatusMessage(
          message: message,
          severity: coordinator.dataRootMessageSeverity,
          announcesNonUrgentStatus: true
        )
        .font(.workbenchBody)
        .padding(.horizontal, WorkbenchSpacing.content)
        .padding(.vertical, WorkbenchSpacing.control)
        .background(
          .secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.panel)
        )
        .frame(maxWidth: 560)
      }

      VStack(spacing: 10) {
        Button {
          Task { await coordinator.useRecommendedDataRoot() }
        } label: {
          Label("使用推荐位置并开始", systemImage: "play.fill")
            .frame(maxWidth: .infinity)
        }
        .workbenchProminentActionStyle()
        .controlSize(.large)
        .accessibilityIdentifier("workbench-data-root-use-recommended")

        Text("存储在此 Mac 的“应用程序支持”文件夹中，之后可在“备份与恢复”中迁移到其他位置。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .multilineTextAlignment(.center)

        Button {
          Task { await coordinator.restoreExistingDataRoot() }
        } label: {
          Label("恢复已有数据文件夹…", systemImage: "arrow.clockwise.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        Button {
          Task { await coordinator.createNewDataRoot() }
        } label: {
          Label("新建数据文件夹…", systemImage: "folder.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        if coordinator.canMigrateLegacyData {
          Button {
            Task { await coordinator.migrateLegacyData() }
          } label: {
            Label("迁移本机旧版数据…", systemImage: "arrow.right.circle")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
        }
      }
      .frame(width: 360)

      Text("工作区数据和备份不包含 API Key。AI Key 按设置独立保存在受限本地配置、系统钥匙串或本次会话。")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
    }
    .padding(WorkbenchSpacing.spacious + WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Keep the setup container queryable without inheriting its identifier onto each control.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workbench-data-root-setup")
  }
}

struct WorkbenchDataRootProgressView: View {
  let message: String

  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.small)
      Text(message)
        .font(.workbenchBody)
        .foregroundStyle(.workbenchSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
  }
}
