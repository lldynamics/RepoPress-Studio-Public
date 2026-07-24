import SwiftUI
import PublishingWorkbenchCore

struct SettingsProfileBar: View {
  let profiles: [SiteProfile]
  let activeProfile: SiteProfile
  let activeProfileIDBinding: Binding<UUID>
  let activeProfileBinding: Binding<SiteProfile>
  let createProfile: () -> Void
  let duplicateActiveProfile: () -> Void
  let deleteActiveProfile: () -> Void
  let activeProfileDraftCount: Int
  let recentlyDeletedProfile: RecentlyDeletedProfile?
  let restoreRecentlyDeletedProfile: () -> Void

  @State private var isProfileManagementPresented = false
  @State private var isDeleteConfirmationPresented = false

  var body: some View {
    HStack(alignment: .center, spacing: 7) {
      VStack(alignment: .trailing, spacing: 2) {
        Text("当前站点")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        Picker("当前站点", selection: activeProfileIDBinding) {
          ForEach(profiles) { profile in
            Text(profile.name).tag(profile.id)
          }
        }
        .labelsHidden()
        .frame(width: 170)
        .accessibilityLabel("当前站点")
        .accessibilityValue(activeProfile.name)
      }

      Button {
        isProfileManagementPresented.toggle()
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .popover(isPresented: $isProfileManagementPresented, arrowEdge: .bottom) {
        profileManagementPopover
      }
      .help("管理站点")
      .accessibilityLabel("管理站点")
    }
  }

  private var profileManagementPopover: some View {
    Form {
      Section("当前站点配置") {
        TextField("站点配置名称", text: activeProfileBinding.name)
          .accessibilityLabel("站点配置名称")
          .accessibilityValue(activeProfile.name)

      }

      Section {
        HStack {
          Button {
            createProfile()
          } label: {
            Label("新增", systemImage: "plus")
          }
          .accessibilityLabel("新增站点配置")

          Button {
            duplicateActiveProfile()
          } label: {
            Label("复制", systemImage: "doc.on.doc")
          }
          .accessibilityLabel("复制当前站点配置")

          Button(role: .destructive) {
            isDeleteConfirmationPresented = true
          } label: {
            Label("删除", systemImage: "trash")
          }
          .disabled(profiles.count <= 1)
          .accessibilityLabel("删除当前站点配置")
        }
      }

      if let recentlyDeletedProfile {
        Section("最近删除") {
          Text("\(recentlyDeletedProfile.profile.name) · \(recentlyDeletedProfile.draftCount) 篇草稿")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("撤销删除", action: restoreRecentlyDeletedProfile)
        }
      }
    }
    .formStyle(.grouped)
    .padding(12)
    .frame(width: 360)
    .confirmationDialog(
      "删除当前站点配置？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除站点配置和 \(activeProfileDraftCount) 篇草稿", role: .destructive) {
        deleteActiveProfile()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将删除「\(activeProfile.name)」及其 \(activeProfileDraftCount) 篇草稿；可在本次会话中通过“撤销删除”恢复。")
    }
  }
}
