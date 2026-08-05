import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum SiteStarterMode: String, CaseIterable, Identifiable {
  case create
  case importExisting

  var id: String { rawValue }

  var title: String {
    switch self {
    case .create:
      return String(localized: "新建站点")
    case .importExisting:
      return String(localized: "导入仓库")
    }
  }
}

enum SiteStarterWizardStep: String, CaseIterable, Identifiable {
  case template
  case localDirectory
  case generate
  case github
  case firstPush
  case deployment

  var id: String { rawValue }

  var title: String {
    switch self {
    case .template:
      return String(localized: "模板")
    case .localDirectory:
      return String(localized: "本地目录")
    case .github:
      return "GitHub"
    case .generate:
      return String(localized: "生成站点")
    case .firstPush:
      return String(localized: "首次推送")
    case .deployment:
      return String(localized: "部署状态")
    }
  }

  var summary: String {
    switch self {
    case .template:
      return String(localized: "新建站点使用 Zola 写作起点；导入已有站点时选择其类型，并填写站点名称、描述、作者和 URL。")
    case .localDirectory:
      return String(localized: "选择一个空文件夹作为本地静态站点仓库。")
    case .github:
      return String(localized: "配置 owner/repo/branch，必要时直接创建 GitHub 仓库。")
    case .generate:
      return String(localized: "生成模板文件、首篇文章、部署说明和本地站点配置。")
    case .firstPush:
      return String(localized: "把生成的 Starter 提交并推送到远端分支。")
    case .deployment:
      return String(localized: "确认 GitHub Pages / Actions 的首次部署状态。")
    }
  }

  var systemImage: String {
    switch self {
    case .template:
      return "sparkles.rectangle.stack"
    case .localDirectory:
      return "folder"
    case .github:
      return "point.3.connected.trianglepath.dotted"
    case .generate:
      return "wand.and.stars"
    case .firstPush:
      return "arrow.up.circle"
    case .deployment:
      return "checkmark.icloud"
    }
  }

  var next: SiteStarterWizardStep? {
    let steps = Self.allCases
    guard let index = steps.firstIndex(of: self),
          index < steps.index(before: steps.endIndex) else {
      return nil
    }
    return steps[steps.index(after: index)]
  }

  var previous: SiteStarterWizardStep? {
    let steps = Self.allCases
    guard let index = steps.firstIndex(of: self),
          index > steps.startIndex else {
      return nil
    }
    return steps[steps.index(before: index)]
  }
}

enum SiteStarterWizardStepStatus {
  case done
  case active
  case pending

  var title: String {
    switch self {
    case .done:
      return String(localized: "已完成")
    case .active:
      return String(localized: "当前")
    case .pending:
      return String(localized: "未完成")
    }
  }

  var systemImage: String {
    switch self {
    case .done:
      return "checkmark.circle"
    case .active:
      return "circle.dotted"
    case .pending:
      return "circle"
    }
  }

  var color: Color {
    switch self {
    case .done:
      return WorkbenchTheme.success
    case .active:
      return .accentColor
    case .pending:
      return .secondary
    }
  }
}

struct SiteStarterWizardStepNavigation: View {
  @Binding var selection: SiteStarterWizardStep
  let steps: [SiteStarterWizardStep]
  let status: (SiteStarterWizardStep) -> SiteStarterWizardStepStatus
  let isEnabled: (SiteStarterWizardStep) -> Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(spacing: 8) {
        ForEach(steps) { step in
          let stepStatus = status(step)
          Button {
            selection = step
          } label: {
            HStack(spacing: 7) {
              Image(systemName: stepStatus.systemImage)
                .foregroundStyle(stepStatus.color)
                .accessibilityHidden(true)
              Text(step.title)
                .font(.callout.weight(selection == step ? .semibold : .regular))
                .workbenchTruncatedIdentity(step.title)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(
              selection == step
                ? AnyShapeStyle(
                  WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.accentBackground)
                )
                : WorkbenchBackgroundStyle.subtle,
              in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            )
            .overlay {
              RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
                .stroke(
                  selection == step
                    ? WorkbenchTheme.navigationSelection.opacity(0.48)
                    : Color(nsColor: .separatorColor).opacity(0.45),
                  lineWidth: 1
                )
            }
          }
          .buttonStyle(.plain)
          .disabled(!isEnabled(step))
          .help(isEnabled(step) ? step.summary : String(localized: "请先完成前面的步骤"))
          .accessibilityLabel("\(step.title)，\(stepStatus.title)")
          .accessibilityHint(
            isEnabled(step) ? step.summary : String(localized: "请先完成前面的步骤")
          )
          .accessibilityAddTraits(selection == step ? .isSelected : [])
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("建站步骤")
  }
}

struct SiteStarterWizardStatusBadge: View {
  let status: SiteStarterWizardStepStatus

  var body: some View {
    Label(status.title, systemImage: status.systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(status.color)
  }
}

struct SiteStarterTemplateStep: View {
  let mode: Binding<SiteStarterMode>
  let selectedTemplate: SiteStarterTemplate?
  let importedSiteKind: Binding<SiteKind>
  let siteName: Binding<String>
  let siteDescription: Binding<String>
  let author: Binding<String>
  let baseURL: Binding<String>

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "选择模板"), systemImage: "sparkles.rectangle.stack") {
      Picker("模式", selection: mode) {
        ForEach(SiteStarterMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .tint(WorkbenchTheme.navigationSelection)
      .accessibilityLabel("建站模式")
      .accessibilityValue(mode.wrappedValue.title)

      if mode.wrappedValue == .create {
        if let template = selectedTemplate {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Label(template.summary, systemImage: "bolt")
              Spacer()
              Text("唯一官方起点")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Text("默认标签：\(template.defaultTags.joined(separator: ", "))")
            Text("默认分类：\(template.defaultCategories.joined(separator: ", "))")
            SiteStarterTemplatePreviewCard(template: template)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      } else {
        Picker("站点类型", selection: importedSiteKind) {
          ForEach(SiteKind.allCases) { siteKind in
            Text(siteKind.localizedDisplayName).tag(siteKind)
          }
        }
        .accessibilityLabel("已有站点类型")
        .accessibilityValue(importedSiteKind.wrappedValue.localizedDisplayName)
        Text("导入已有站点不会改写文件；这里的类型只用于选择内容目录和 Front Matter 规则。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      SiteStarterThemeCloneGuide()

      Divider()

      TextField("网站名称", text: siteName)
        .accessibilityLabel("网站名称")
        .accessibilityValue(siteName.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      TextField("描述", text: siteDescription)
        .accessibilityLabel("网站描述")
        .accessibilityValue(siteDescription.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      TextField("作者", text: author)
        .accessibilityLabel("网站作者")
        .accessibilityValue(author.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      TextField("生产站 URL", text: baseURL)
        .accessibilityLabel("生产站 URL")
        .accessibilityValue(baseURL.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
    }
  }
}

struct SiteStarterThemeCloneGuide: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("想直接使用现成主题？", systemImage: "arrow.down.doc")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
      Text("先克隆主题仓库，再回到这里选择“导入已有站点”。导入会保留主题文件，不会把主题改造成 Starter。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("git clone <主题仓库地址> <本地站点目录>")
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
      Text("推荐流程：克隆主题 → 导入已有站点 → 选择对应的站点类型 → 开始写作。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("现成主题导入指引")
  }
}

struct SiteStarterLocalDirectoryStep: View {
  let mode: SiteStarterMode
  let rootPath: Binding<String>
  let initializesGit: Binding<Bool>
  let configuresOrigin: Binding<Bool>
  let siteStarterResultProfilePath: String?
  let siteStarterImportProfilePath: String?
  let importedDraftCount: Int?

  let selectDirectory: () -> Void

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "本地目录"), systemImage: "folder") {
      HStack {
        TextField(
          mode == .create
            ? String(localized: "空文件夹路径")
            : String(localized: "已有站点仓库路径"),
          text: rootPath
        )
        .accessibilityLabel(
          mode == .create
            ? String(localized: "空文件夹路径")
            : String(localized: "已有站点仓库路径")
        )
          .accessibilityValue(rootPath.wrappedValue.nilIfEmpty ?? String(localized: "未选择"))
        Button {
          selectDirectory()
        } label: {
          Label("选择", systemImage: "folder")
        }
        .accessibilityLabel("选择本地站点目录")
      }

      if mode == .create {
        Toggle("初始化 Git 仓库", isOn: initializesGit)
          .accessibilityLabel("初始化 Git 仓库")
          .accessibilityValue(
            initializesGit.wrappedValue ? String(localized: "开启") : String(localized: "关闭")
          )
        Toggle("生成后配置 origin remote", isOn: configuresOrigin)
          .disabled(!initializesGit.wrappedValue)
          .accessibilityLabel("生成后配置 origin remote")
          .accessibilityValue(
            configuresOrigin.wrappedValue ? String(localized: "开启") : String(localized: "关闭")
          )
      } else {
        Label("导入模式会保留已有文件，只创建工作台站点配置并导入内容目录里的 Markdown/MDX。", systemImage: "tray.and.arrow.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let path = siteStarterResultProfilePath {
        Divider()
        let generatedPathLabel = String(format: String(localized: "已生成到 %@"), path)
        Label(generatedPathLabel, systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
          .font(.caption)
          .workbenchTruncatedIdentity(path, lineLimit: 2)
      }

      if let importPath = siteStarterImportProfilePath {
        Divider()
        let importedPathLabel = String(format: String(localized: "已导入 %@"), importPath)
        Label(importedPathLabel, systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
          .font(.caption)
          .workbenchTruncatedIdentity(importPath, lineLimit: 2)
        if let importedDraftCount {
          InspectorStatRow(title: "导入文章", value: "\(importedDraftCount)", systemImage: "doc.text")
        }
      }
    }
  }
}

struct SiteStarterGitHubStep: View {
  let githubOwner: Binding<String>
  let githubRepo: Binding<String>
  let branch: Binding<String>
  let deploymentTarget: Binding<SiteStarterDeploymentTarget>
  let deploymentProjectID: Binding<String>
  let deploymentAccountID: Binding<String>
  let createsPrivateRepository: Binding<Bool>
  let canCreateGitHubRepository: Bool
  let isRepositoryOperationRunning: Bool
  let hasVerifiedExistingRepository: Bool
  let remoteRepositoryURL: String?
  let remoteRepositoryHTMLURL: String?
  let remoteRepositoryName: String?
  let createAction: () -> Void
  let verifyExistingAction: () -> Void

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "GitHub"), systemImage: "point.3.connected.trianglepath.dotted") {
      HStack {
        TextField("Owner", text: githubOwner)
          .accessibilityLabel("GitHub Owner")
          .accessibilityValue(githubOwner.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
        TextField("Repo", text: githubRepo)
          .accessibilityLabel("GitHub Repo")
          .accessibilityValue(githubRepo.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
        TextField("Branch", text: branch)
          .frame(width: 120)
          .accessibilityLabel("Git 分支")
          .accessibilityValue(branch.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      }

      Picker("部署", selection: deploymentTarget) {
        ForEach(SiteStarterDeploymentTarget.allCases) { target in
          Text(target.localizedDisplayName).tag(target)
        }
      }
      .accessibilityLabel("部署平台")
      .accessibilityValue(deploymentTarget.wrappedValue.localizedDisplayName)

      if deploymentTarget.wrappedValue == .netlify {
        TextField("Netlify Site ID（可稍后补）", text: deploymentProjectID)
          .accessibilityLabel("Netlify Site ID")
          .accessibilityValue(deploymentProjectID.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      }
      if deploymentTarget.wrappedValue == .vercel {
        TextField("Vercel Project ID（可稍后补）", text: deploymentProjectID)
          .accessibilityLabel("Vercel Project ID")
          .accessibilityValue(deploymentProjectID.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
        TextField("Vercel Team ID（可选）", text: deploymentAccountID)
          .accessibilityLabel("Vercel Team ID")
          .accessibilityValue(deploymentAccountID.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      }
      if deploymentTarget.wrappedValue == .cloudflarePages {
        TextField("Cloudflare Account ID（可稍后补）", text: deploymentAccountID)
          .accessibilityLabel("Cloudflare Account ID")
          .accessibilityValue(deploymentAccountID.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
        TextField("Cloudflare Pages Project", text: deploymentProjectID)
          .accessibilityLabel("Cloudflare Pages Project")
          .accessibilityValue(deploymentProjectID.wrappedValue.nilIfEmpty ?? String(localized: "未填写"))
      }

      Toggle("创建为私有仓库", isOn: createsPrivateRepository)
        .accessibilityLabel("创建为私有仓库")
        .accessibilityValue(
          createsPrivateRepository.wrappedValue ? String(localized: "开启") : String(localized: "关闭")
        )

      if !createsPrivateRepository.wrappedValue {
        Label {
          Text("公开仓库中的代码和内容可被任何人查看。")
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
      }

      HStack {
        Button {
          createAction()
        } label: {
          Label("创建 GitHub 仓库", systemImage: "plus.circle")
        }
        .disabled(!canCreateGitHubRepository || isRepositoryOperationRunning)
        .accessibilityLabel("创建 GitHub 仓库")
        .accessibilityHint("使用填写的 Owner、Repo 和分支创建远端仓库")

        Button {
          verifyExistingAction()
        } label: {
          Label("验证已有仓库", systemImage: "checkmark.shield")
        }
        .disabled(!canCreateGitHubRepository || isRepositoryOperationRunning)
        .accessibilityHint("检查已有仓库是否可读且可写")

        if isRepositoryOperationRunning {
          ProgressView()
            .controlSize(.small)
        }
      }

      if hasVerifiedExistingRepository, remoteRepositoryName == nil {
        Label("已验证远端仓库可读且可写", systemImage: "checkmark.shield.fill")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
      }

      if let repositoryName = remoteRepositoryName {
        Divider()
        Label(repositoryName, systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
        let remoteURL = remoteRepositoryHTMLURL ?? remoteRepositoryURL ?? repositoryName
        Text(remoteURL)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(remoteURL, lineLimit: 2)
      }
    }
  }
}

struct SiteStarterGenerateStep: View {
  let isCreateMode: Bool
  let createAction: () -> Void
  let disabled: Bool
  let isRunning: Bool
  let createdFileCount: Int?
  let createdProfileText: String?
  let createdProfileKindText: String?
  let guideText: String?
  let importedArticleCount: Int?
  let skippedPathCount: Int?

  var body: some View {
    SiteStarterWizardPanel(
      title: isCreateMode ? String(localized: "生成站点") : String(localized: "导入仓库"),
      systemImage: isCreateMode ? "wand.and.stars" : "tray.and.arrow.down"
    ) {
      Text(
        isCreateMode
          ? String(localized: "生成 Starter 会写入模板文件、示例文章、部署说明，并把新站点配置加入工作台。")
          : String(localized: "导入已有仓库不会改写文件；会按所选 SSG 默认内容目录导入文章。")
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      Button {
        createAction()
      } label: {
        if isRunning {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(
              isCreateMode
                ? String(localized: "正在生成站点…")
                : String(localized: "正在导入已有仓库…")
            )
          }
        } else {
          Label(
            isCreateMode ? String(localized: "生成站点") : String(localized: "导入已有仓库"),
            systemImage: isCreateMode ? "wand.and.stars" : "tray.and.arrow.down"
          )
        }
      }
      .workbenchProminentActionStyle()
      .disabled(disabled || isRunning)

      if let createdProfileText, let createdProfileKindText {
        Divider()
        Label("\(createdProfileText) · \(createdProfileKindText)", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
        if let fileCount = createdFileCount {
          InspectorStatRow(title: "创建文件", value: "\(fileCount)", systemImage: "doc.badge.plus")
        }
        if let guideText {
          Text(guideText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      if let importedArticleCount {
        Divider()
        let profileText = createdProfileText ?? String(localized: "仓库")
        let profileKindText = createdProfileKindText ?? String(localized: "站点")
        Label("\(profileText) · \(profileKindText)", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
        InspectorStatRow(title: "导入文章", value: "\(importedArticleCount)", systemImage: "doc.text")
        if let skippedPathCount {
          InspectorStatRow(title: "跳过文件", value: "\(skippedPathCount)", systemImage: "exclamationmark.triangle")
        }
      }
    }
  }
}

struct SiteStarterFirstPushStep: View {
  let canPushStarterSite: Bool
  let pushAction: () -> Void
  let pushBranch: String?
  let pushSHA: String?
  let committedPathCount: Int?
  let remoteURL: String?

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "首次推送"), systemImage: "arrow.up.circle") {
      Text("首次推送会提交生成的 Starter 文件，并推送到 origin 的目标分支。")
        .font(.callout)
        .foregroundStyle(.secondary)

      Button {
        pushAction()
      } label: {
        Label("首次提交并推送", systemImage: "arrow.up.circle")
      }
      .workbenchProminentActionStyle()
      .disabled(!canPushStarterSite)

      if let pushBranch, let pushSHA {
        Divider()
        Label("\(pushBranch) · \(pushSHA.prefix(8))", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
        if let committedPathCount {
          InspectorStatRow(title: "文件", value: "\(committedPathCount)", systemImage: "shippingbox")
        }
        if let remoteURL {
          Text(remoteURL)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(remoteURL, lineLimit: 2)
        }
      }
    }
  }
}

struct SiteStarterDeploymentStep: View {
  let deploymentTarget: SiteStarterDeploymentTarget
  let deploymentGuidePath: String?
  let deploymentCommands: [String]
  let deploymentStatusMessage: String?
  let copyCommands: ([String]) -> Void

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "部署状态"), systemImage: "checkmark.icloud") {
      if deploymentTarget == .none {
        Label("当前选择暂不部署。", systemImage: "pause.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Text("首次推送后，到 GitHub 仓库的 Pages / Actions 确认构建状态。后续文章发布会在发布记录里持续追踪部署。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if !deploymentCommands.isEmpty || deploymentGuidePath != nil {
        DisclosureGroup("部署说明") {
          VStack(alignment: .leading, spacing: 8) {
            if let guide = deploymentGuidePath {
              Text(guide)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }

            ForEach(deploymentCommands, id: \.self) { command in
              Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }

            Button {
              copyCommands(deploymentCommands)
            } label: {
              Label("复制命令", systemImage: "doc.on.doc")
            }
          }
          .padding(.vertical, 4)
        }
      }

      if let message = deploymentStatusMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct SiteStarterWizardPanel<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SiteStarterTemplatePreviewCard: View {
  var template: SiteStarterTemplate

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(template.preview.headline)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
          Text(template.preview.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Text(template.preview.accentName)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(WorkbenchBackgroundStyle.badge, in: Capsule())
      }

      VStack(alignment: .leading, spacing: 7) {
        Text(template.preview.primarySectionTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        ForEach(template.preview.sampleItems, id: \.self) { item in
          HStack(spacing: 8) {
            Circle()
              .fill(.secondary)
              .frame(width: 4, height: 4)
            Text(item)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
