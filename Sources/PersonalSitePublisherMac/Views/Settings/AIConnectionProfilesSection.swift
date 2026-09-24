import PublishingWorkbenchCore
import SwiftUI

struct AIConnectionProfilesSection: View {
  enum Presentation {
    case siteSelection
    case sharedEditor
  }

  let profiles: [AIConnectionProfile]
  let referencingSiteProfiles: [SiteProfile]
  let selectedProfileID: Binding<UUID>
  let updateProfile: (AIConnectionProfile) -> Void
  let createProfile: (String, AIProviderPreset) -> AIConnectionProfile
  let duplicateProfileForCurrentSite: (UUID) -> AIConnectionProfile?
  let currentActionMessage: () -> String?
  let deleteProfile: (UUID) -> Void
  let deletableProfiles: [AIConnectionProfile]
  let presentation: Presentation
  let currentSiteName: String
  let editSharedConnection: (() -> Void)?
  var subsectionAnchor: SettingsSubsection? = nil
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
      switch presentation {
      case .siteSelection:
        siteSelectionContent
      case .sharedEditor:
        sharedEditorContent
      }
    } header: {
      Group {
        if presentation == .siteSelection {
          Text("当前站点的 AI 连接")
        } else {
          Text("共享 AI 连接")
        }
      }
      .settingsSubsectionAnchor(subsectionAnchor)
    } footer: {
      switch presentation {
      case .siteSelection:
        Text("选择会立即应用到当前站点“\(currentSiteName)”。新建或复制后，只有当前站点会改用新档案。")
      case .sharedEditor:
        Text("地址、模型和 API Key 属于共享连接；修改会影响每个引用该档案的站点。")
      }
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

  @ViewBuilder
  private var siteSelectionContent: some View {
    Picker("当前站点使用", selection: selectedProfileID) {
      ForEach(profiles) { profile in
        Text(profile.name).tag(profile.id)
      }
    }
    .accessibilityLabel("当前站点使用的 AI 连接档案")
    .accessibilityIdentifier("settings-site-ai-connection-picker")

    if let selectedProfile {
      Label(selectedProfile.summary, systemImage: "point.3.connected.trianglepath.dotted")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .accessibilityIdentifier("settings-site-ai-connection-summary")
    }

    HStack(spacing: 8) {
      Menu {
        Section("创建并用于当前站点") {
          ForEach(AIConnectionProfile.templates) { template in
            Button {
              let created = createProfile(template.name, template.config.preset)
              selectedProfileID.wrappedValue = created.id
            } label: {
              Label(
                template.name,
                systemImage: template.config.preset == .local ? "desktopcomputer" : "sparkles")
            }
          }
        }
      } label: {
        Label("创建并用于当前站点", systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("创建并用于当前站点的 AI 连接档案")

      Button {
        duplicateSelectedProfileForCurrentSite()
      } label: {
        Label("为当前站点复制配置", systemImage: "doc.on.doc")
      }
      .buttonStyle(.bordered)
      .disabled(selectedProfile == nil)
      .help("复制地址、模型和参数到新档案，并让当前站点改用副本。API Key 不会复制。")
      .accessibilityLabel("为当前站点复制 AI 连接配置")
    }

    if let editSharedConnection {
      Button("编辑共享连接", action: editSharedConnection)
        .accessibilityIdentifier("settings-site-ai-edit-shared-connection")
    }

    copyFeedback
  }

  @ViewBuilder
  private var sharedEditorContent: some View {
    LabeledContent("来源站点", value: currentSiteName)
    if let selectedProfile {
      TextField("档案名称", text: profileNameBinding(for: selectedProfile))
        .accessibilityLabel("AI 连接档案名称")

      VStack(alignment: .leading, spacing: 6) {
        Label("正在编辑“\(selectedProfile.name)”", systemImage: "rectangle.3.group")
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

  @ViewBuilder
  private var copyFeedback: some View {
    if let copyFeedbackMessage {
      Text(copyFeedbackMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityIdentifier("settings-ai-connection-copy-feedback")
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
