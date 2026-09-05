import PublishingWorkbenchCore
import SwiftUI

struct AIConnectionProfilesSection: View {
  let profiles: [AIConnectionProfile]
  let referencingSiteProfiles: [SiteProfile]
  let selectedProfileID: Binding<UUID>
  let updateProfile: (AIConnectionProfile) -> Void
  let createProfile: (String, AIProviderPreset) -> AIConnectionProfile
  let duplicateProfileForCurrentSite: (UUID) -> AIConnectionProfile?
  let currentActionMessage: () -> String?
  let deleteProfile: (UUID) -> Void
  let deletableProfiles: [AIConnectionProfile]
  @State private var profilePendingDeletion: AIConnectionProfile?
  @State private var isDeleteConfirmationPresented = false
  @State private var copyFeedbackMessage: String?

  private var selectedProfile: AIConnectionProfile? {
    profiles.first { $0.id == selectedProfileID.wrappedValue }
  }

  private var selectedProfileUsage: AIConnectionUsagePresentation? {
    selectedProfile.map {
      AIConnectionUsagePresentation(
        connectionProfileID: $0.id,
        siteProfiles: referencingSiteProfiles
      )
    }
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

        VStack(alignment: .leading, spacing: 6) {
          Label("共享连接档案", systemImage: "rectangle.3.group")
            .font(.caption.weight(.semibold))

          Label(selectedProfile.summary, systemImage: "point.3.connected.trianglepath.dotted")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

          Text("修改服务地址、模型或 API Key 会影响所有引用此档案的站点。")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let selectedProfileUsage {
            Text(selectedProfileUsage.referencedSitesDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("settings-ai-connection-referencing-sites")
          }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-ai-connection-shared-scope")
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

        Button {
          duplicateSelectedProfileForCurrentSite()
        } label: {
          Label("为当前站点复制配置", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .disabled(selectedProfile == nil)
        .help("复制地址、模型和参数到新档案，并让当前站点改用副本。API Key 不会复制。")
        .accessibilityLabel("为当前站点复制 AI 连接配置")

        Spacer(minLength: 0)

        Menu {
          ForEach(deletableProfiles) { profile in
            Button(profile.name, role: .destructive) {
              profilePendingDeletion = profile
              isDeleteConfirmationPresented = true
            }
          }
        } label: {
          Label("删除未使用档案", systemImage: "trash")
        }
        .menuStyle(.borderlessButton)
        .disabled(deletableProfiles.isEmpty)
        .help(
          deletableProfiles.isEmpty
            ? String(localized: "至少保留一个档案，且已被站点使用的档案不能删除")
            : String(localized: "删除未被任何站点使用的连接档案")
        )
      }

      if let copyFeedbackMessage {
        Text(copyFeedbackMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("settings-ai-connection-copy-feedback")
      }
    } header: {
      Text("AI 连接配置档案")
    } footer: {
      Text("连接档案可供多个站点复用。复制后仅当前站点改用副本；若服务需要 API Key，请为副本单独保存。")
    }
    .confirmationDialog(
      "删除 AI 连接档案？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      if let profilePendingDeletion {
        Button("删除“\(profilePendingDeletion.name)”", role: .destructive) {
          deleteProfile(profilePendingDeletion.id)
          self.profilePendingDeletion = nil
        }
      }
      Button("取消", role: .cancel) {
        profilePendingDeletion = nil
      }
    } message: {
      Text("将一并删除该连接档案在当前保存位置中的 API Key；其他保存位置不会被后台访问。正在被站点使用的档案不会出现在此列表中。")
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

  private func duplicateSelectedProfileForCurrentSite() {
    guard let selectedProfile else { return }
    guard let duplicatedProfile = duplicateProfileForCurrentSite(selectedProfile.id) else {
      copyFeedbackMessage =
        currentActionMessage()?.trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
        ?? String(localized: "AI 连接未复制，请稍后重试。")
      return
    }
    copyFeedbackMessage =
      currentActionMessage()?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
      ?? (duplicatedProfile.config.requiresAPIKey
        ? String(localized: "已为当前站点复制配置，请为副本单独保存 API Key。")
        : String(localized: "已为当前站点复制配置，其他站点仍使用原连接。"))
  }
}
