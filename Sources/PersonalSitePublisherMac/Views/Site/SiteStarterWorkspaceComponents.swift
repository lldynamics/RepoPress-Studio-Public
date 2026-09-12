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
      return String(localized: "新建站点可选 Astro、Hugo、Zola 或 VitePress 起点；导入已有站点时选择其类型。")
    case .localDirectory:
      return String(localized: "选择本地静态站点仓库文件夹。")
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

enum SiteStarterWorkflowProjection {
  static func steps(
    mode: SiteStarterMode,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [SiteStarterWizardStep] {
    if mode == .importExisting || deploymentTarget == .none {
      return [.template, .localDirectory, .generate, .deployment]
    }
    return SiteStarterWizardStep.allCases
  }
}

enum SiteStarterFormProfileBinding {
  static func canPersistGitHubInputs(
    boundProfileID: UUID?,
    activeProfileID: UUID,
    starterResultProfileID: UUID?
  ) -> Bool {
    boundProfileID == activeProfileID && starterResultProfileID == activeProfileID
  }
}

enum SiteStarterDeploymentConfigurationLock {
  static func isLocked(activeProfileID: UUID, starterResultProfileID: UUID?) -> Bool {
    activeProfileID == starterResultProfileID
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
                : WorkbenchBackgroundStyle.card,
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
  let selectedTemplateID: Binding<SiteStarterTemplateID>
  let selectedTemplate: SiteStarterTemplate?
  let importedSiteKind: Binding<SiteKind>
  let siteName: Binding<String>
  let siteDescription: Binding<String>
  let author: Binding<String>
  let baseURL: Binding<String>
  let deploymentTarget: Binding<SiteStarterDeploymentTarget>
  let deploymentProjectID: Binding<String>
  let deploymentAccountID: Binding<String>
  let deploymentConfigurationLocked: Bool

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
        Picker("起步模板", selection: selectedTemplateID) {
          ForEach(SiteStarterTemplate.builtIn) { template in
            Text(template.name).tag(template.id)
          }
        }
        .accessibilityLabel("起步模板")
        .accessibilityValue(selectedTemplate?.name ?? String(localized: "未选择"))

        if let template = selectedTemplate {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Label(template.summary, systemImage: "bolt")
              Spacer()
              Text(template.siteKind.localizedDisplayName)
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

      if deploymentConfigurationLocked {
        Label(
          "部署配置已在生成站点前锁定：\(deploymentTarget.wrappedValue.localizedDisplayName)",
          systemImage: "lock.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Picker("部署", selection: deploymentTarget) {
        ForEach(SiteStarterDeploymentTarget.allCases) { target in
          Text(target.localizedDisplayName).tag(target)
        }
      }
      .accessibilityLabel("部署平台")
      .accessibilityValue(deploymentTarget.wrappedValue.localizedDisplayName)
      .disabled(deploymentConfigurationLocked)

      if deploymentTarget.wrappedValue == .netlify {
        TextField("Netlify Site ID（可稍后补）", text: deploymentProjectID)
          .accessibilityLabel("Netlify Site ID（可稍后补）")
          .disabled(deploymentConfigurationLocked)
      } else if deploymentTarget.wrappedValue == .vercel {
        TextField("Vercel Project ID（可稍后补）", text: deploymentProjectID)
          .accessibilityLabel("Vercel Project ID（可稍后补）")
          .disabled(deploymentConfigurationLocked)
        TextField("Vercel Team ID（可选）", text: deploymentAccountID)
          .accessibilityLabel("Vercel Team ID（可选）")
          .disabled(deploymentConfigurationLocked)
      } else if deploymentTarget.wrappedValue == .cloudflarePages {
        TextField("Cloudflare Account ID（可稍后补）", text: deploymentAccountID)
          .accessibilityLabel("Cloudflare Account ID（可稍后补）")
          .disabled(deploymentConfigurationLocked)
        TextField("Cloudflare Pages Project", text: deploymentProjectID)
          .accessibilityLabel("Cloudflare Pages Project")
          .disabled(deploymentConfigurationLocked)
      }
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
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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
  let preflight: SiteStarterDirectoryPreflight?
  let selectedImportKind: SiteKind

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

      if !rootPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        SiteStarterDirectoryPreflightSummary(
          preflight: preflight,
          mode: mode,
          selectedImportKind: selectedImportKind
        )
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

struct SiteStarterInitialSiteChoice: View {
  let writeAction: () -> Void
  let connectAction: () -> Void
  let createAction: () -> Void

  var body: some View {
    SiteStarterWizardPanel(title: "从这里开始", systemImage: "flag.checkered") {
      Text("还没有配置站点。先写文章，或连接/新建一个站点后再发布。")
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Button(action: writeAction) {
          Label("先写文章", systemImage: "square.and.pencil")
        }
        .buttonStyle(.bordered)
        Button(action: connectAction) {
          Label("连接已有站点", systemImage: "link")
        }
        .buttonStyle(.bordered)
        Button(action: createAction) {
          Label("新建站点", systemImage: "plus.circle")
        }
        .workbenchProminentActionStyle()
      }
    }
    .accessibilityIdentifier("site-starter-initial-choices")
  }
}

struct SiteStarterDirectoryPreflightSummary: View {
  let preflight: SiteStarterDirectoryPreflight?
  let mode: SiteStarterMode
  let selectedImportKind: SiteKind

  var body: some View {
    Group {
      if let preflight {
        if let readErrorMessage = preflight.readErrorMessage {
          Label("无法完整读取目录：\(readErrorMessage)", systemImage: "xmark.octagon")
            .foregroundStyle(WorkbenchTheme.warning)
        } else if !preflight.exists {
          Label(
            preflight.parentIsWritable
              ? String(localized: "目录尚不存在；生成时会创建它，实际写入前仍会验证。")
              : String(localized: "目录尚不存在，且父目录不可写。"),
            systemImage: preflight.parentIsWritable ? "folder.badge.plus" : "xmark.octagon"
          )
          .foregroundStyle(preflight.parentIsWritable ? .secondary : WorkbenchTheme.warning)
        } else if !preflight.isDirectory {
          Label("所选路径不是目录；生成或导入前会再次验证路径。", systemImage: "xmark.octagon")
            .foregroundStyle(WorkbenchTheme.warning)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Label("只读预检", systemImage: "eye")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(directorySummary(preflight))
              .font(.caption)
              .foregroundStyle(.secondary)
            if mode == .importExisting {
              importKindSummary(preflight)
            } else if (preflight.visibleEntryCount ?? 0) > 0 {
              Label("新建站点要求空文件夹；实际写入前仍会执行安全检查。", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(WorkbenchTheme.warning)
            }
            if preflight.traversalWasCapped {
              Label(
                String(
                  format: String(localized: "内容目录已达到预检上限；显示的是前 %lld 个条目的计数。"),
                  SiteStarterDirectoryPreflightService.maximumTraversalEntries
                ),
                systemImage: "gauge.with.dots.needle.67percent"
              )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      } else {
        Label("正在读取目录信息…", systemImage: "eye")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("site-starter-directory-preflight")
  }

  private func directorySummary(_ preflight: SiteStarterDirectoryPreflight) -> String {
    let git = preflight.isGitRepository ? String(localized: "Git 仓库") : String(localized: "非 Git 目录")
    let entryCount = preflight.visibleEntryCount.map(String.init) ?? String(localized: "无法读取")
    let articleCount = preflight.markdownFileCount.map(String.init) ?? String(localized: "无法读取")
    let access = [preflight.isReadable ? String(localized: "可读") : String(localized: "不可读"), preflight.isWritable ? String(localized: "可写") : String(localized: "不可写")]
      .joined(separator: " · ")
    return String(
      format: String(localized: "%@ 个顶层项目 · %@/ 中 %@ 个 Markdown/MDX 文件 · %@ · %@"),
      entryCount, preflight.selectedContentRootPath, articleCount, git, access
    )
  }

  @ViewBuilder
  private func importKindSummary(_ preflight: SiteStarterDirectoryPreflight) -> some View {
    if preflight.detectionIsAmbiguous {
      Label(
        "检测结果不明确：\(preflight.detectionEvidence.joined(separator: "、"))；当前仍按 \(selectedImportKind.localizedDisplayName) 的内容目录导入。",
        systemImage: "questionmark.folder"
      )
      .font(.caption)
      .foregroundStyle(WorkbenchTheme.warning)
    } else if let detectedKind = preflight.detectedSiteKind {
      let evidence = preflight.detectionEvidence.isEmpty ? "" : "（\(preflight.detectionEvidence.joined(separator: "、"))）"
      let detectedRoot = preflight.detectedContentRootPath.map { String(localized: "，建议内容目录 \($0)") } ?? ""
      Label(
        "检测到 \(detectedKind.localizedDisplayName)\(evidence)\(detectedRoot)；当前将按 \(selectedImportKind.localizedDisplayName) 导入。",
        systemImage: detectedKind == selectedImportKind ? "checkmark.circle" : "slider.horizontal.3"
      )
      .font(.caption)
      .foregroundStyle(detectedKind == selectedImportKind ? WorkbenchTheme.success : WorkbenchTheme.warning)
    } else {
      Label(
        "未识别站点配置；将按你选择的 \(selectedImportKind.localizedDisplayName) 导入。",
        systemImage: "questionmark.folder"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

struct SiteStarterGitHubStep: View {
  let githubOwner: Binding<String>
  let githubRepo: Binding<String>
  let branch: Binding<String>
  let deploymentTarget: SiteStarterDeploymentTarget
  let deploymentProjectID: String
  let deploymentAccountID: String
  let createsPrivateRepository: Binding<Bool>
  let canCreateGitHubRepository: Bool
  let isRepositoryOperationRunning: Bool
  let repositoryTokenAvailability: KeychainTokenAvailability
  let hasVerifiedExistingRepository: Bool
  let remoteRepositoryURL: String?
  let remoteRepositoryHTMLURL: String?
  let remoteRepositoryName: String?
  let createAction: () -> Void
  let verifyExistingAction: () -> Void
  let openRepositoryTokenSettings: () -> Void

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

      Label("部署配置已在生成站点前锁定：\(deploymentTarget.localizedDisplayName)", systemImage: "lock.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !deploymentProjectID.isEmpty || !deploymentAccountID.isEmpty {
        Text([deploymentProjectID, deploymentAccountID].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      Toggle("创建为私有仓库", isOn: createsPrivateRepository)
        .accessibilityLabel("创建为私有仓库")
        .accessibilityValue(
          createsPrivateRepository.wrappedValue ? String(localized: "开启") : String(localized: "关闭")
        )

      Label("填写 Owner、Repo 和分支后，可创建仓库或验证已有仓库。验证会实际检查读写权限，不会只因检测到 Token 就通过。", systemImage: "checkmark.shield")
        .font(.caption)
        .foregroundStyle(.secondary)

      repositoryCredentialStatus

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

  @ViewBuilder
  private var repositoryCredentialStatus: some View {
    if let failureMessage = repositoryTokenAvailability.accessFailureMessage {
      Label("无法读取 GitHub 凭据：\(failureMessage)", systemImage: "xmark.octagon")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
      Button("打开 GitHub 令牌设置", action: openRepositoryTokenSettings)
        .buttonStyle(.link)
    } else if !repositoryTokenAvailability.hasToken {
      Label("未保存 GitHub 凭据；创建或验证时仍会进行实际权限检查。", systemImage: "key.slash")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
      Button("打开 GitHub 令牌设置", action: openRepositoryTokenSettings)
        .buttonStyle(.link)
    } else if hasVerifiedExistingRepository {
      Label("已验证远端仓库可读且可写", systemImage: "checkmark.shield.fill")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.success)
    } else {
      Label("检测到已保存 GitHub 凭据；尚未验证此仓库的读写权限。", systemImage: "key")
        .font(.caption)
        .foregroundStyle(.secondary)
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
  let reviewAction: () -> Void
  let pushBranch: String?
  let pushSHA: String?
  let committedPathCount: Int?
  let remoteURL: String?

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "首次推送"), systemImage: "arrow.up.circle") {
      Text("先冻结并复核远端、分支、提交说明和精确文件清单；确认后会重新校验，再提交并推送。")
        .font(.callout)
        .foregroundStyle(.secondary)

      Button {
        reviewAction()
      } label: {
        Label("复核首次提交", systemImage: "checklist")
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

struct SiteStarterFirstPushConfirmationView: View {
  let confirmation: SiteStarterPushConfirmation
  let isPushing: Bool
  let failureMessage: String?
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Group {
        if confirmation.existingCommitSHA == nil {
          Text("复核首次提交")
        } else {
          Text("复核重试推送")
        }
      }
      .font(.title2.weight(.semibold))
      Group {
        if confirmation.existingCommitSHA == nil {
          Text("以下是刚刚冻结的快照。确认后会再次校验；任一项变化都会停止，不会提交或推送。")
        } else {
          Text("以下是已提交版本的冻结复核。确认后只会推送显示的 SHA；任一项变化都会停止。")
        }
      }
      .foregroundStyle(.secondary)

      GroupBox("目标") {
        VStack(alignment: .leading, spacing: 8) {
          confirmationRow("远端", confirmation.remoteURL)
          confirmationRow("分支", confirmation.branch)
          confirmationRow("提交说明", confirmation.commitMessage)
          confirmationRow(
            "远端基线",
            confirmation.remoteBranchCommitSHA.map { String($0.prefix(12)) } ?? String(localized: "目标分支尚不存在")
          )
          confirmationRow(
            "本地 HEAD",
            confirmation.headCommitSHA.map { String($0.prefix(12)) } ?? String(localized: "尚无提交")
          )
          if let existingCommitSHA = confirmation.existingCommitSHA {
            confirmationRow("允许推送的已提交 SHA", String(existingCommitSHA.prefix(12)))
          }
        }
      }

      GroupBox {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(confirmation.committedPaths, id: \.self) { path in
              Text(path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
      } label: {
        if confirmation.existingCommitSHA == nil {
          Text(String(format: String(localized: "将提交 %lld 个文件"), confirmation.committedPaths.count))
        } else {
          Text(String(format: String(localized: "已提交 %lld 个文件"), confirmation.committedPaths.count))
        }
      }

      Label("已检查暂存区没有 Starter 清单外的文件。", systemImage: "checkmark.shield")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.success)

      if let failureMessage {
        Label(failureMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      HStack {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button {
          confirmAction()
        } label: {
          if isPushing {
            ProgressView()
              .controlSize(.small)
          } else if confirmation.existingCommitSHA != nil {
            Label("确认重试推送", systemImage: "arrow.up.circle")
          } else {
            Label("确认提交并推送", systemImage: "arrow.up.circle")
          }
        }
        .workbenchProminentActionStyle()
        .disabled(isPushing)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(minWidth: 560)
  }

  private func confirmationRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .workbenchTruncatedIdentity(value, lineLimit: 2)
    }
  }
}

struct SiteStarterDeploymentStep: View {
  let deploymentTarget: SiteStarterDeploymentTarget
  let deploymentGuidePath: String?
  let deploymentCommands: [String]
  let deploymentStatusMessage: String?
  let pushedCommitSHA: String?
  let siteURL: String?
  let copyCommands: ([String]) -> Void
  let checkDeploymentStatus: () -> Void
  let openHistory: () -> Void
  let openSite: () -> Void

  var body: some View {
    SiteStarterWizardPanel(title: String(localized: "部署状态"), systemImage: "checkmark.icloud") {
      if deploymentTarget == .none {
        Label("当前选择暂不部署。", systemImage: "pause.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Text("推送成功表示提交已到远端。检查部署会核对对应发布记录；首次推送尚无记录时，打开本次提交页面查看 GitHub 检查结果。")
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

      if let pushedCommitSHA {
        Divider()
        Label("已推送 \(pushedCommitSHA.prefix(8))；下一步确认部署。", systemImage: "arrow.up.circle.fill")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
        HStack(spacing: 10) {
          Button(action: checkDeploymentStatus) {
            Label("检查部署状态", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          Button(action: openHistory) {
            Label("查看发布记录", systemImage: "clock.arrow.circlepath")
          }
          .buttonStyle(.bordered)
          if let siteURL, URL(string: siteURL) != nil {
            Button(action: openSite) {
              Label("打开站点", systemImage: "safari")
            }
            .buttonStyle(.bordered)
          }
        }
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
          .background(WorkbenchBackgroundStyle.control, in: Capsule())
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
