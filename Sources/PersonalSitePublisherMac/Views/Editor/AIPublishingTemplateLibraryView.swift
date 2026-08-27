import PublishingWorkbenchCore
import SwiftUI

struct AIPublishingTemplateLibraryView: View {
  let draft: ArticleDraft
  let selectedText: String
  let availabilityForAction: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let onPerformAction: (AIPublishingActionKind) -> Void
  let onUsePrompt: (AIPublishingQuickPrompt) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedScope = AIPublishingPromptLibraryScope.all
  @State private var searchText = ""

  private var snapshot: AIPublishingPromptLibrarySnapshot {
    AIPublishingPromptLibraryService.snapshot(
      selectedScope: selectedScope,
      searchText: searchText,
      selectedText: selectedText,
      draft: draft
    )
  }

  private var workflowGuides: [AIPublishingWorkflowGuide] {
    snapshot.recommendedWorkflowGuides + snapshot.workflowGuides
  }

  private var promptSections: [AIPublishingQuickPromptSection] {
    let defaults = Set(AIPublishingDefaultCapability.defaultQuickPrompts)
    return snapshot.promptSections.compactMap { section in
      let prompts = section.prompts.filter { !defaults.contains($0) }
      guard !prompts.isEmpty else { return nil }
      return AIPublishingQuickPromptSection(group: section.group, prompts: prompts)
    }
  }

  private var actionSections: [AIPublishingEditorActionSection] {
    let defaults = Set(AIPublishingDefaultCapability.defaultActionKinds)
    let visibleSections = snapshot.spotlightActionSections + snapshot.editorActionSections
    return AIPublishingQuickPromptGroup.allCases.compactMap { group in
      var seen = Set<AIPublishingActionKind>()
      let actions = visibleSections
        .filter { $0.group == group }
        .flatMap(\.actions)
        .filter { !defaults.contains($0) && seen.insert($0).inserted }
      guard !actions.isEmpty else { return nil }
      return AIPublishingEditorActionSection(group: group, actions: actions)
    }
  }

  private var hasVisibleContent: Bool {
    !workflowGuides.isEmpty || !promptSections.isEmpty || !actionSections.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      scopePicker
      Divider()

      if hasVisibleContent {
        templateList
      } else {
        ContentUnavailableView.search(text: searchText)
      }
    }
    .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 680)
    .searchable(text: $searchText, placement: .toolbar, prompt: "搜索动作、提示或工作流")
    .accessibilityIdentifier("ai-template-library")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "sparkles.rectangle.stack")
        .font(.title2)
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 34, height: 34)
        .background(
          WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("AI 模板库")
          .font(.title2.weight(.semibold))
        Text("默认入口只保留 8 个高频能力；其他动作、快捷提示和工作流可在这里搜索。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 16)

      Button("完成") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("ai-template-library-close")
    }
    .padding(20)
  }

  private var scopePicker: some View {
    Picker("模板范围", selection: $selectedScope) {
      ForEach(AIPublishingPromptLibraryScope.allCases) { scope in
        Label(scope.localizedDisplayName, systemImage: scope.systemImage)
          .tag(scope)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .accessibilityLabel("模板范围")
    .accessibilityIdentifier("ai-template-library-scope")
  }

  private var templateList: some View {
    List {
      if !workflowGuides.isEmpty {
        Section {
          ForEach(workflowGuides) { guide in
            workflowRow(guide)
          }
        } header: {
          librarySectionHeader("工作流模板", count: workflowGuides.count)
        }
      }

      ForEach(promptSections) { section in
        Section {
          ForEach(section.prompts) { prompt in
            Button {
              onUsePrompt(prompt)
              dismiss()
            } label: {
              libraryRow(
                title: prompt.localizedDisplayName,
                detail: section.group.localizedDisplayName,
                systemImage: section.group.systemImage
              )
            }
            .buttonStyle(.plain)
          }
        } header: {
          librarySectionHeader(
            "\(String(localized: "快捷提示")) · \(section.group.localizedDisplayName)",
            count: section.prompts.count
          )
        }
      }

      ForEach(actionSections) { section in
        Section {
          ForEach(section.actions) { action in
            actionRow(action, group: section.group)
          }
        } header: {
          librarySectionHeader(
            "\(String(localized: "专业动作")) · \(section.group.localizedDisplayName)",
            count: section.actions.count
          )
        }
      }
    }
    .listStyle(.inset)
    .accessibilityIdentifier("ai-template-library-results")
  }

  private func workflowRow(_ guide: AIPublishingWorkflowGuide) -> some View {
    DisclosureGroup {
      ForEach(guide.prompts) { prompt in
        Button {
          onUsePrompt(prompt)
          dismiss()
        } label: {
          libraryRow(
            title: prompt.localizedDisplayName,
            detail: prompt.group.localizedDisplayName,
            systemImage: prompt.group.systemImage
          )
        }
        .buttonStyle(.plain)
      }
    } label: {
      libraryRow(
        title: guide.localizedTitle,
        detail: guide.prompts.map(\.localizedDisplayName).joined(separator: " · "),
        systemImage: guide.systemImage
      )
    }
  }

  private func actionRow(
    _ action: AIPublishingActionKind,
    group: AIPublishingQuickPromptGroup
  ) -> some View {
    let availability = availabilityForAction(action)
    return Button {
      onPerformAction(action)
      dismiss()
    } label: {
      libraryRow(
        title: action.localizedDisplayName,
        detail: availability.unavailableReason ?? group.localizedDisplayName,
        systemImage: action.promptLibrarySystemImage
      )
    }
    .buttonStyle(.plain)
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? action.localizedDisplayName)
  }

  private func libraryRow(
    title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 28, height: 28)
        .background(
          WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 12)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 3)
  }

  private func librarySectionHeader(_ title: String, count: Int) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(count, format: .number)
        .monospacedDigit()
    }
  }
}

private extension AIPublishingWorkflowGuide {
  var localizedTitle: String {
    switch id {
    case "idea-to-draft": String(localized: "从想法到初稿")
    case "draft-to-finished-article": String(localized: "初稿补完成稿")
    case "complete-article-workbench": String(localized: "完整成稿工作台")
    case "technical-explainer-kit": String(localized: "技术文章增强")
    case "draft-evidence-kit": String(localized: "正文补料工具")
    case "structure-upgrade": String(localized: "结构升级")
    case "evidence-backed-draft": String(localized: "证据驱动写作")
    case "selection-rewrite": String(localized: "选区润色改写")
    case "selection-to-structure": String(localized: "选区整理成结构")
    case "front-matter-pack": String(localized: "标题与 Front Matter")
    case "front-matter-details": String(localized: "路径与摘要细化")
    case "bilingual-publish-metadata": String(localized: "双语发布元数据")
    case "bilingual-release-kit": String(localized: "双语发布套件")
    case "publish-readiness": String(localized: "发布前 AI 审稿")
    case "evidence-and-reader-review": String(localized: "事实与读者校对")
    case "seo-link-image-audit": String(localized: "SEO、链接与图片体检")
    case "link-image-publish-pack": String(localized: "链接图片发布包")
    case "image-publishing-assistant": String(localized: "图片发布助手")
    case "publish-recovery-assistant": String(localized: "发布失败恢复助手")
    case "distribution-pack": String(localized: "发布素材生成")
    case "multi-channel-distribution": String(localized: "多渠道分发")
    case "site-maintenance-assistant": String(localized: "站点内容维护助手")
    case "refresh-and-series-plan": String(localized: "旧文与系列维护")
    default: title
    }
  }
}
