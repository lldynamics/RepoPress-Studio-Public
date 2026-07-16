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
    HStack(spacing: 10) {
      Label("Profile", systemImage: "person.crop.rectangle.stack")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Picker("当前 Profile", selection: activeProfileIDBinding) {
        ForEach(profiles) { profile in
          Text(profile.name).tag(profile.id)
        }
      }
      .labelsHidden()
      .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
      .accessibilityLabel("当前 Profile")
      .accessibilityValue(activeProfile.name)

      Spacer()

      Button {
        isProfileManagementPresented.toggle()
      } label: {
        Label("管理 Profile", systemImage: "slider.horizontal.3")
      }
      .popover(isPresented: $isProfileManagementPresented, arrowEdge: .bottom) {
        profileManagementPopover
      }
      .help("管理当前 Profile")
    }
  }

  private var profileManagementPopover: some View {
    Form {
      Section("当前 Profile") {
        TextField("Profile 名称", text: activeProfileBinding.name)
          .accessibilityLabel("Profile 名称")
          .accessibilityValue(activeProfile.name)

      }

      Section {
        HStack {
          Button {
            createProfile()
          } label: {
            Label("新增", systemImage: "plus")
          }
          .accessibilityLabel("新增 Profile")

          Button {
            duplicateActiveProfile()
          } label: {
            Label("复制", systemImage: "doc.on.doc")
          }
          .accessibilityLabel("复制当前 Profile")

          Button(role: .destructive) {
            isDeleteConfirmationPresented = true
          } label: {
            Label("删除", systemImage: "trash")
          }
          .disabled(profiles.count <= 1)
          .accessibilityLabel("删除当前 Profile")
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
      "删除当前 Profile？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除 Profile 和 \(activeProfileDraftCount) 篇草稿", role: .destructive) {
        deleteActiveProfile()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将删除「\(activeProfile.name)」及其 \(activeProfileDraftCount) 篇草稿；可在本次会话中通过“撤销删除”恢复。")
    }
  }
}
