import PublishingWorkbenchCore
import SwiftUI

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
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: WorkbenchSpacing.control) {
        profileLabel
        profilePicker
          .frame(minWidth: 108, idealWidth: 120)
          .fixedSize(horizontal: true, vertical: false)
        profileManagementButton
      }

      VStack(alignment: .leading, spacing: 4) {
        profileLabel
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: WorkbenchSpacing.control) {
            profilePicker
              .frame(minWidth: 110, maxWidth: .infinity)
            profileManagementButton
          }

          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            profilePicker
              .frame(maxWidth: .infinity)
            profileManagementButton
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
    }
    .popover(isPresented: $isProfileManagementPresented, arrowEdge: .bottom) {
      profileManagementPopover
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-profile-bar")
  }

  private var profileLabel: some View {
    Text("当前站点")
      .font(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .fixedSize()
      .accessibilityHidden(true)
  }

  private var profilePicker: some View {
    Picker("当前站点", selection: activeProfileIDBinding) {
      ForEach(profiles) { profile in
        Text(profile.name).tag(profile.id)
      }
    }
    .labelsHidden()
    .font(.callout)
    .accessibilityLabel("当前站点")
    .accessibilityValue(activeProfile.name)
    .accessibilityIdentifier("settings-current-site-picker")
  }

  private var profileManagementButton: some View {
    Button {
      isProfileManagementPresented.toggle()
    } label: {
      Label("管理", systemImage: "ellipsis.circle")
        .labelStyle(.iconOnly)
    }
    .buttonStyle(.bordered)
    .font(.callout)
    .help("管理站点")
    .accessibilityLabel("管理站点")
    .accessibilityIdentifier("settings-manage-sites")
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
    .padding(WorkbenchSpacing.card)
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
