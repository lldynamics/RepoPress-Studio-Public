import PublishingWorkbenchCore
import SwiftUI

struct FirstRunSetupView: View {
  @ObservedObject var store: WorkbenchStore
  let finish: () -> Void
  let skip: () -> Void

  @State private var step: Step = .siteType
  @State private var isPreparingRepository = false
  @State private var repositoryMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      Group {
        switch step {
        case .siteType:
          siteTypeStep
        case .repository:
          repositoryStep
        case .publishing:
          publishingStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(24)

      Divider()

      footer
    }
    .frame(width: 620, height: 500)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("首次设置")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "leaf.fill")
          .font(.title2)
          .foregroundStyle(WorkbenchTheme.primary)

        VStack(alignment: .leading, spacing: 2) {
          Text("设置个人网站发布流程")
            .font(.title3.weight(.semibold))
          Text("三步连接站点，之后可以随时在设置中修改。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 8) {
        ForEach(Step.allCases) { candidate in
          HStack(spacing: 6) {
            Image(systemName: candidate.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(candidate.rawValue + 1).circle.fill")
            Text(candidate.titleKey)
              .workbenchTruncatedIdentity(candidate.accessibilityTitle)
          }
          .font(.caption.weight(candidate == step ? .semibold : .regular))
          .foregroundStyle(candidate.rawValue <= step.rawValue ? WorkbenchTheme.primary : Color.secondary)

          if candidate != Step.allCases.last {
            Rectangle()
              .fill(candidate.rawValue < step.rawValue ? WorkbenchTheme.primary : Color.secondary.opacity(0.25))
              .frame(height: 1)
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("设置进度")
      .accessibilityValue("第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步：\(step.accessibilityTitle)")
    }
    .padding(24)
  }

  private var siteTypeStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("选择站点类型", detail: "应用会据此设置文章头信息（Front Matter）、文章目录和图片路径默认值。")

      Picker("站点生成器", selection: siteKindBinding) {
        ForEach(SiteKind.allCases) { kind in
          Text(kind.localizedDisplayName).tag(kind)
        }
      }
      .pickerStyle(.radioGroup)
      .accessibilityHint("选择当前网站使用的静态站点生成器")

      setupSummary(
        systemImage: "doc.text",
        title: store.activeProfile.siteKind.localizedDisplayName,
        detail: String(
          format: String(localized: "内容目录：%@"),
          store.activeProfile.contentRoot
        )
      )
    }
  }

  private var repositoryStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("连接本地仓库", detail: "只会访问你主动选择的文件夹，并使用 macOS 安全作用域权限。")

      setupSummary(
        systemImage: hasRepository ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.questionmark",
        title: hasRepository ? String(localized: "本地仓库已连接") : String(localized: "尚未选择本地仓库"),
        detail: hasRepository
          ? store.activeProfile.localRepositoryRootPath
          : String(localized: "选择包含站点配置和内容目录的仓库根目录。")
      )

      Button {
        chooseRepository()
      } label: {
        Label(hasRepository ? "更换本地仓库" : "选择本地仓库", systemImage: "folder.badge.plus")
      }
      .workbenchProminentActionStyle()
      .disabled(isPreparingRepository)

      if isPreparingRepository {
        ProgressView("正在读取仓库配置…")
          .controlSize(.small)
      } else if let repositoryMessage {
        AccessibleStatusMessage(message: repositoryMessage, severity: .error)
      }
    }
  }

  private var publishingStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepTitle("选择发布方式", detail: "重要文章建议使用分支和 PR/MR，日常更新可以直接提交。")

      Picker("远端平台", selection: repositoryProviderBinding) {
        ForEach(RepositoryProvider.allCases) { provider in
          Text(provider.localizedDisplayName).tag(provider)
        }
      }
      .pickerStyle(.segmented)
      .tint(WorkbenchTheme.navigationSelection)

      Picker("发布策略", selection: publishStrategyBinding) {
        ForEach(RepositoryPublishStrategy.allCases) { strategy in
          Text(strategy.localizedDisplayName).tag(strategy)
        }
      }
      .pickerStyle(.radioGroup)

      setupSummary(
        systemImage: "checkmark.seal",
        title: String(localized: "准备完成"),
        detail: String(localized: "完成后会进入同步工作区并扫描仓库；发布前仍会要求检查和差异确认。")
      )
    }
  }

  private var footer: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Button(String(localized: "稍后设置")) {
          skip()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .foregroundStyle(.secondary)

        Text("当前已选择的站点类型、仓库和发布方式会保留，可稍后在设置中继续修改。")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: 300, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      if step != .siteType {
        Button("上一步") {
          step = Step(rawValue: step.rawValue - 1) ?? .siteType
        }
      }

      Button(step == .publishing ? "完成并检查仓库" : "下一步") {
        if step == .publishing {
          finish()
        } else {
          step = Step(rawValue: step.rawValue + 1) ?? .publishing
        }
      }
      .workbenchProminentActionStyle()
      .disabled(step == .repository && !hasRepository)
      .keyboardShortcut(.defaultAction)
    }
    .padding(18)
  }

  private func stepTitle(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func setupSummary(systemImage: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(WorkbenchTheme.primary)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var hasRepository: Bool {
    !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
  }

  private var siteKindBinding: Binding<SiteKind> {
    Binding(
      get: { store.activeProfile.siteKind },
      set: { store.applySiteKindDefaults($0) }
    )
  }

  private var repositoryProviderBinding: Binding<RepositoryProvider> {
    Binding(
      get: { store.activeProfile.repositoryProvider },
      set: { store.setRepositoryProvider($0) }
    )
  }

  private var publishStrategyBinding: Binding<RepositoryPublishStrategy> {
    Binding(
      get: { store.activeProfile.repositoryPublishStrategy },
      set: { strategy in
        var profile = store.activeProfile
        profile.repositoryPublishStrategy = strategy
        store.updateActiveProfile(profile)
        store.save()
      }
    )
  }

  private func chooseRepository() {
    guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
    isPreparingRepository = true
    repositoryMessage = nil
    Task {
      await store.repository.rememberRootAsync(url)
      isPreparingRepository = false
      if hasRepository {
        step = .publishing
      } else {
        repositoryMessage = String(localized: "未能保存仓库权限，请重新选择或检查文件夹访问权限。")
      }
    }
  }

  private enum Step: Int, CaseIterable, Identifiable {
    case siteType
    case repository
    case publishing

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
      switch self {
      case .siteType: "站点"
      case .repository: "仓库"
      case .publishing: "发布"
      }
    }

    var accessibilityTitle: String {
      switch self {
      case .siteType: String(localized: "站点")
      case .repository: String(localized: "仓库")
      case .publishing: String(localized: "发布")
      }
    }
  }
}
