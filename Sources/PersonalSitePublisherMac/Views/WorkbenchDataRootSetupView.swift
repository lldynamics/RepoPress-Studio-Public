import SwiftUI

struct WorkbenchDataRootSetupView: View {
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "externaldrive.fill.badge.plus")
        .font(.system(size: 42, weight: .medium))
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("设置 RepoPress 数据文件夹")
          .font(.title2.weight(.semibold))
        Text("资料库、RSS、工作台和应用内附件会统一保存在这个文件夹。删除并重新安装应用后，再次选择它即可恢复。")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 540)
      }

      if let message = coordinator.dataRootMessage {
        Label(message, systemImage: "info.circle.fill")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
          .frame(maxWidth: 560)
      }

      VStack(spacing: 10) {
        Button {
          Task { await coordinator.restoreExistingDataRoot() }
        } label: {
          Label("恢复已有数据文件夹…", systemImage: "arrow.clockwise.circle")
            .frame(maxWidth: .infinity)
        }
        .workbenchProminentActionStyle()
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

      Text("数据文件夹不包含 API Key。凭据仍由 macOS 钥匙串单独保护。")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
  }
}
