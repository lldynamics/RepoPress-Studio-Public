import PublishingWorkbenchCore
import SwiftUI

struct AIConnectionProfilesSection: View {
  let profiles: [AIConnectionProfile]
  let selectedProfileID: Binding<UUID>
  let updateProfile: (AIConnectionProfile) -> Void
  let createProfile: (String, AIProviderPreset) -> AIConnectionProfile
  let deleteProfile: (UUID) -> Void
  let canDeleteProfile: Bool

  private var selectedProfile: AIConnectionProfile? {
    profiles.first { $0.id == selectedProfileID.wrappedValue }
  }

  var body: some View {
    Section {
      Picker("当前站点使用", selection: selectedProfileID) {
        ForEach(profiles) { profile in
          Text(profile.name).tag(profile.id)
        }
      }
      .accessibilityLabel("当前站点使用的 AI 连接档案")

      if let selectedProfile {
        TextField("档案名称", text: profileNameBinding(for: selectedProfile))
          .accessibilityLabel("AI 连接档案名称")

        VStack(alignment: .leading, spacing: 4) {
          Label(selectedProfile.summary, systemImage: "point.3.connected.trianglepath.dotted")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

          Text("同一档案可供多个站点复用；地址、模型和 API Key 只需配置一次。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      }

      HStack(spacing: 8) {
        Menu {
          Section("快速创建") {
            ForEach(AIConnectionProfile.templates) { template in
              Button {
                let created = createProfile(template.name, template.config.preset)
                selectedProfileID.wrappedValue = created.id
              } label: {
                Label(template.name, systemImage: template.config.preset == .local ? "desktopcomputer" : "sparkles")
              }
            }
          }
        } label: {
          Label("新增连接档案", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("新增 AI 连接档案")

        Spacer(minLength: 0)

        if selectedProfile != nil {
          Button("删除档案", role: .destructive) {
            deleteProfile(selectedProfileID.wrappedValue)
          }
          .buttonStyle(.borderless)
          .disabled(!canDeleteProfile)
          .help(
            canDeleteProfile
              ? String(localized: "删除当前连接档案")
              : String(localized: "至少保留一个档案，且已被站点使用的档案不能删除")
          )
        }
      }
    } header: {
      Text("AI 连接配置档案")
    } footer: {
      Text("站点只保存所选档案；切换站点时不会重复填写服务地址、模型或密钥。")
    }
  }

  private func profileNameBinding(for profile: AIConnectionProfile) -> Binding<String> {
    Binding(
      get: {
        profiles.first(where: { $0.id == profile.id })?.name ?? profile.name
      },
      set: { name in
        var updated = profiles.first(where: { $0.id == profile.id }) ?? profile
        updated.name = name
        updateProfile(updated)
      }
    )
  }
}
