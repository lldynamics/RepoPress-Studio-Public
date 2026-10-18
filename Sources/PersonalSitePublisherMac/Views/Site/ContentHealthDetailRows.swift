import PublishingWorkbenchCore
import SwiftUI

extension ContentHealthDetailView {
  func runAIFixQueueItem(_ item: AIPublishingFixQueueItem) {
    guard let draft = store.publishing.visibleDrafts.first(where: { $0.id == item.draftID }) else {
      return
    }
    cancelAIFixTask()
    store.publishing.selectDraft(item.draftID)
    let requestID = UUID()
    let profileID = store.activeProfile.id
    let draftID = draft.id
    aiFixRequestID = requestID
    aiFixTask = Task { @MainActor in
      defer {
        if aiFixRequestID == requestID {
          aiFixTask = nil
          aiFixRequestID = nil
        }
      }
      guard !Task.isCancelled,
        aiFixRequestID == requestID,
        store.activeProfile.id == profileID,
        store.publishing.visibleDrafts.contains(where: { $0.id == draftID })
      else {
        return
      }
      guard let result = await store.ai.performAction(item.recommendedAction, draft: draft),
        !Task.isCancelled,
        aiFixRequestID == requestID,
        store.activeProfile.id == profileID,
        store.publishing.visibleDrafts.contains(where: { $0.id == draftID })
      else {
        return
      }
      aiFixResultPreview = ContentHealthAIFixResultPreview(
        draftID: draft.id,
        draftTitle: draft.title.nilIfEmpty ?? String(localized: "未命名文章"),
        result: result,
        metadataBaseline: ContentHealthAIFixFieldPolicy.baseline(for: draft)
      )
    }
  }

}

extension ContentHealthDetailView {
  func conflictingDrafts(for routes: [String], targetDraftID: UUID) -> [ArticleDraft] {
    let normalized = Set(routes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
    return store.publishing.visibleDrafts.filter { draft in
      guard draft.id != targetDraftID, !draft.isGeneralDraft else { return false }
      let slug = draft.slug.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let aliases = Set(
        draft.aliases.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
      return normalized.contains(slug) || !aliases.isDisjoint(with: normalized)
    }
  }
}

struct ContentHealthIssueListView: View {
  let rows: [ContentHealthIssueSelection]
  @Binding var selection: ContentHealthIssueSelection?
  let locate: (PreflightIssue, UUID) -> Void
  let runAIFix: (AIPublishingFixQueueItem) -> Void
  let isAIRunning: Bool
  let openMaintenanceDraft: (UUID) -> Void
  let copyMaintenance: (MaintenanceActionItem) -> Void
  let recordMaintenance: (MaintenanceActionItem) -> Void
  let sendMaintenanceToAI: (MaintenanceActionItem) -> Void
  let suppress: (PreflightIssue, UUID, ContentHealthSuppressionMode) -> Void
  @FocusState private var isListFocused: Bool
  @Environment(\.workbenchAccentColor) private var accentColor

  var body: some View {
    ScrollViewReader { proxy in
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(ContentHealthIssueSection.allCases, id: \.self) { section in
          let sectionRows = rows.filter { $0.section == section }
          if !sectionRows.isEmpty {
            HStack(spacing: WorkbenchSpacing.control) {
              Text(section.title)
                .font(.workbenchSectionTitle)
              Text("\(sectionRows.reduce(0) { $0 + $1.occurrenceCount }) 项")
                .font(.workbenchMetadata.monospacedDigit())
                .foregroundStyle(.workbenchSecondary)
            }
            .padding(WorkbenchSpacing.card)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("content-health-group-\(section.rawValue)")

            ForEach(sectionRows) { row in
              Divider()
              issueRow(row)
                .id(row.id)
            }
          }
        }
      }
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .focusable()
      .focusEffectDisabled()
      .focused($isListFocused)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("问题列表")
      .accessibilityIdentifier("content-health-issue-list")
      .accessibilityHint("点击问题后，可使用上下箭头选择问题")
      .onKeyPress(.upArrow) {
        moveSelection(by: -1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        moveSelection(by: 1)
        return .handled
      }
      .onChange(of: rows, initial: true) { _, current in
        selection = ContentHealthIssueListProjection.reconciled(selection, rows: current)
      }
      .onChange(of: selection?.id) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }

  private func issueRow(_ row: ContentHealthIssueSelection) -> some View {
    let isSelected = selection?.id == row.id
    return HStack(spacing: WorkbenchSpacing.card) {
      Button {
        selection = row
        isListFocused = true
      } label: {
        HStack(spacing: WorkbenchSpacing.card) {
          Image(systemName: row.section.systemImage)
            .foregroundStyle(row.section.color)
            .font(.system(size: WorkbenchIconSize.inline))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
            Text(row.title)
              .font(.workbenchItemTitle)
              .workbenchTruncatedTitle(row.title)
            Text(description(row))
              .font(.workbenchMetadata)
              .foregroundStyle(.workbenchSecondary)
              .lineLimit(1)
              .help(description(row))
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(WorkbenchFocusRingButtonStyle())
      .accessibilityLabel("选择问题：\(row.title)")
      .accessibilityValue(description(row))
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("content-health-select-issue-\(row.id)")

      ContentHealthSuppressionMenu(row: row, suppress: suppress)
        .controlSize(.small)
      rowActions(row)
        .controlSize(.small)
        .fixedSize()
    }
    .padding(.horizontal, WorkbenchSpacing.card)
    .padding(.vertical, WorkbenchSpacing.control)
    .background(
      isSelected ? accentColor.opacity(WorkbenchOpacity.selectionBackground) : Color.clear)
  }

  /// Task data, not UI copy: joined outside the `Section` call so the
  /// separator is never extracted as a localization key.
  private func maintenanceMenuTitle(_ item: MaintenanceActionItem) -> String {
    [item.title, item.contentHealthActionTarget].joined(separator: " · ")
  }

  @ViewBuilder
  private func rowActions(_ row: ContentHealthIssueSelection) -> some View {
    if !row.maintenanceItems.isEmpty {
      Menu {
        ForEach(row.maintenanceItems) { item in
          Section(maintenanceMenuTitle(item)) {
            if let draftID = item.draftID {
              Button("打开草稿") { openMaintenanceDraft(draftID) }
            }
            Button("记录处理：\(item.contentHealthActionTarget)") { recordMaintenance(item) }
            Button("复制任务：\(item.contentHealthActionTarget)") { copyMaintenance(item) }
            if item.draftID != nil {
              Button("AI 修复：\(item.contentHealthActionTarget)") { sendMaintenanceToAI(item) }
                .disabled(isAIRunning)
            }
          }
        }
      } label: {
        if row.affectedArticleCount > 1 {
          Text("\(row.affectedArticleCount) 篇")
        } else {
          Text("处理")
        }
      }
      .accessibilityLabel("处理维护事项：\(row.title)")
    } else if row.articles.count == 1, let article = row.articles.first,
      let issue = article.issues.first
    {
      Button("定位") {
        selection = row
        locate(issue, article.draftID)
      }
      .accessibilityLabel("定位问题：\(row.title)")
      .contextMenu { articleActions(article, selection: row) }
    } else if !row.articles.isEmpty {
      Menu {
        ForEach(row.articles) { article in
          Section(article.draftTitle) { articleActions(article, selection: row) }
        }
      } label: {
        Text("\(row.affectedArticleCount) 篇")
      }
      .accessibilityLabel("受影响的文章：\(row.title)")
    } else {
      Text("\(row.occurrenceCount) 项")
        .font(.workbenchMetadata.monospacedDigit())
        .foregroundStyle(.workbenchSecondary)
    }
  }

  @ViewBuilder
  private func articleActions(
    _ article: ContentHealthArticleRowModel, selection row: ContentHealthIssueSelection
  ) -> some View {
    ForEach(article.issues) { issue in
      Button(issue.message) {
        selection = row
        locate(issue, article.draftID)
      }
    }
    if let item = article.aiFixItem {
      Button("AI 修复") { runAIFix(item) }
        .disabled(isAIRunning)
    }
  }

  private func description(_ row: ContentHealthIssueSelection) -> String {
    var parts: [String] = []
    if let subgroup = row.subgroup { parts.append(subgroup) }
    if let item = row.maintenanceItems.first {
      parts.append(String(localized: "\(row.maintenanceItems.count) 项"))
      parts.append(
        String.localizedStringWithFormat(
          String(localized: "优先级：%@"), item.priority.localizedDisplayName))
    }
    if row.affectedArticleCount > 1 {
      parts.append(String(localized: "\(row.affectedArticleCount) 篇文章"))
    } else if let article = row.articles.first {
      parts.append(article.draftTitle)
    }
    parts.append(row.detail)
    return parts.joined(separator: " · ")
  }

  private func moveSelection(by offset: Int) {
    selection = ContentHealthIssueListProjection.moved(selection, offset: offset, rows: rows)
  }
}

/// The unified inspector renders only the selected issue. Actions return to
/// the mounted health page, which continues to own tasks and approval sheets.
struct ContentHealthSelectedIssueInspector: View {
  let selectedIssue: ContentHealthIssueSelection?
  @ObservedObject var actions: ContentHealthInspectorActions
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceAction

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
          if let selectedIssue {
            header(selectedIssue)
            Text(selectedIssue.detail)
              .font(.workbenchSupporting)
              .foregroundStyle(.workbenchSecondary)
              .fixedSize(horizontal: false, vertical: true)
            if !selectedIssue.articles.isEmpty {
              Label("受影响的文章", systemImage: "doc.text")
                .font(.workbenchSectionTitle)
              ForEach(selectedIssue.articles) { article in
                articleCard(article)
              }
            }
            ForEach(selectedIssue.siteIssues) { issue in
              ContentHealthIssueCard(issue: issue)
            }
            ForEach(selectedIssue.maintenanceItems) { item in
              maintenanceCard(item)
            }
          } else {
            Label("问题详情", systemImage: "sidebar.right")
              .font(.workbenchSectionTitle)
            Text("选择一个问题以查看详情。")
              .font(.workbenchSupporting)
              .foregroundStyle(.workbenchSecondary)
          }
        }
        .padding(WorkbenchSpacing.content)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      rulesFooter
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("问题详情")
    .accessibilityIdentifier("content-health-selected-issue-inspector")
  }

  private func header(_ selection: ContentHealthIssueSelection) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      HStack(spacing: WorkbenchSpacing.icon) {
        Label(selection.section.title, systemImage: selection.section.systemImage)
          .foregroundStyle(selection.section.color)
        Text(sourceTitle(selection))
          .foregroundStyle(.workbenchSecondary)
      }
      .font(.workbenchMetadata)
      Text(selection.title)
        .font(.workbenchCardTitle)
        .fixedSize(horizontal: false, vertical: true)
      if selection.affectedArticleCount > 0 {
        Text("\(selection.affectedArticleCount) 篇文章")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
      if let generatedAt = actions.generatedAt {
        Text("上次扫描 \(generatedAt.workbenchShortText)")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
    }
    // Native static-text accessibility may replace an explicit value with its
    // label. Keep the title and its context in one readable name instead.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(verbatim: "\(selection.title)，\(headingAccessibilityDetails(selection))")
    )
    .accessibilityIdentifier("content-health-selected-issue-heading")
  }

  private func headingAccessibilityDetails(_ selection: ContentHealthIssueSelection) -> String {
    var details = [selection.section.title, sourceTitle(selection)]
    if selection.affectedArticleCount > 0 {
      details.append(String(localized: "\(selection.affectedArticleCount) 篇文章"))
    }
    if let generatedAt = actions.generatedAt {
      details.append(String(localized: "上次扫描 \(generatedAt.workbenchShortText)"))
    }
    return details.joined(separator: "、")
  }

  private func sourceTitle(_ selection: ContentHealthIssueSelection) -> String {
    if !selection.articles.isEmpty { return ContentHealthSourceFilter.articles.title }
    if !selection.siteIssues.isEmpty { return ContentHealthSourceFilter.site.title }
    return ContentHealthSourceFilter.maintenance.title
  }

  private func articleCard(_ article: ContentHealthArticleRowModel) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      Text(article.draftTitle)
        .font(.workbenchItemTitle)
        .workbenchTruncatedTitle(article.draftTitle)
      Text(article.markdownPath)
        .font(.workbenchMetadata.monospaced())
        .foregroundStyle(.workbenchSecondary)
        .workbenchTruncatedIdentity(article.markdownPath)
      Button("前往写作") { actions.openMaintenanceDraft(article.draftID) }
        .buttonStyle(.link)
        .accessibilityIdentifier("content-health-open-article-\(article.draftID.uuidString)")
      ForEach(article.issues) { issue in
        ContentHealthIssueCard(issue: issue) {
          actions.locate(issue, draftID: article.draftID)
        }
      }
      if let resolution = actions.slugResolution(for: article.draftID) {
        resolution
      }
      if let item = article.aiFixItem {
        Divider()
        Text("修复建议生成后先审阅，再选择要应用的字段。")
          .font(.workbenchSupporting)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          actions.runAIFix(item)
        } label: {
          Label("AI 修复", systemImage: "sparkles")
        }
        .workbenchProminentActionStyle()
        .disabled(actions.isAIRunning)
        .accessibilityLabel("AI 修复：\(article.draftTitle)")
        .accessibilityIdentifier("content-health-inspector-ai-fix-\(article.draftID.uuidString)")
      }
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .disabled(!actions.isAvailable)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("content-health-inspector-article-\(article.draftID.uuidString)")
  }

  private func maintenanceCard(_ item: MaintenanceActionItem) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      Text(item.title)
        .font(.workbenchItemTitle)
        .fixedSize(horizontal: false, vertical: true)
      Text(item.contentHealthActionTarget)
        .font(.workbenchSupporting)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(
        String.localizedStringWithFormat(
          String(localized: "优先级：%@"), item.priority.localizedDisplayName)
      )
      .font(.workbenchMetadata)
      .foregroundStyle(.workbenchSecondary)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchSpacing.control) { maintenanceButtons(item) }
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          maintenanceButtons(item)
        }
      }
      .controlSize(.small)
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .disabled(!actions.isAvailable)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("content-health-inspector-maintenance-\(item.id)")
  }

  @ViewBuilder
  private func maintenanceButtons(_ item: MaintenanceActionItem) -> some View {
    if let draftID = item.draftID {
      Button("打开草稿") { actions.openMaintenanceDraft(draftID) }
      Button("AI 修复") { actions.sendMaintenanceToAI(item) }
        .disabled(actions.isAIRunning)
    }
    Button("记录处理") { actions.recordMaintenance(item) }
    Button("复制任务") { actions.copyMaintenance(item) }
  }

  private var rulesFooter: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      Button("检查规则") {
        SettingsNavigation.present(
          destination: .ai(.writingStyle), workspaceAction: settingsWorkspaceAction,
          openSettings: { openSettings() })
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("content-health-inspector-rules")
      Text("可选内容警告和提示可在问题列表中忽略；页面上的已忽略设置可恢复检查。")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension ContentHealthDetailView {
  static func preferredSource(
    for filter: ContentHealthContextFilter
  ) -> ContentHealthSourceFilter {
    switch filter {
    case .overview: .all
    case .publicRisks, .aiFixes: .articles
    case .siteIssues: .site
    case .maintenance: .maintenance
    }
  }

  static func preferredAIFixFilter(
    for filter: ContentHealthContextFilter
  ) -> ContentHealthAIFixFilter {
    filter == .aiFixes ? .fixable : .all
  }

  static func preferredGrouping(
    for filter: ContentHealthContextFilter
  ) -> ContentHealthArticleGrouping {
    switch filter {
    case .overview, .publicRisks:
      return .actionQueue
    case .aiFixes:
      return .automaticFix
    case .siteIssues:
      return .site
    case .maintenance:
      return .actionQueue
    }
  }

  func focusContentHealthIssue(_ issue: PreflightIssue, draftID: UUID) {
    switch issue.structuredField {
    case .body:
      _ = store.focusDraft(draftID, section: .writing)
      store.setInspectorPresented(true)
      store.requestEditorFocus(
        draftID: draftID,
        field: issue.field,
        query: issue.editorQuery
      )
    case .attachments, .cover, .coverAlt:
      _ = store.focusDraft(draftID, section: .images)
    default:
      _ = store.focusDraft(draftID, section: .writing)
      store.setInspectorPresented(true)
    }
  }

  func applySelectedAIFixFields(
    _ fields: [FrontMatterFixFieldItem],
    for preview: ContentHealthAIFixResultPreview
  ) -> ContentHealthAIFixApplyFeedback {
    guard let draftID = preview.draftID,
      var draft = store.publishing.visibleDrafts.first(where: { $0.id == draftID })
    else {
      return .failed(String(localized: "未能找到原文章，未应用任何字段。"))
    }

    let result = ContentHealthAIFixFieldPolicy.apply(
      fields,
      to: &draft,
      baseline: preview.metadataBaseline
    )
    guard result.didApplyChanges else {
      if result.conflictCount > 0 {
        return .applied(result)
      }
      return .failed(String(localized: "所选字段当前不能应用，文章未更改。"))
    }

    store.updateDraft(draft)
    refreshContentHealthSnapshot()
    return .applied(result)
  }
}
