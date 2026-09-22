import PublishingWorkbenchCore
import SwiftUI

/// A small, shared destination context for surfaces that collect material for
/// an article. The destination is deliberately the store's current selection:
/// changing it uses the same focus routing as the writing list and therefore
/// keeps the window-scoped article identity in sync.
struct KnowledgeWritingContextView: View {
  enum Presentation {
    case card
    case menu
  }

  let store: WorkbenchStore
  private let presentation: Presentation
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @Environment(\.workspaceWindowSession) private var workspaceWindowSession
  @Environment(\.workspaceWindowIsKey) private var workspaceWindowIsKey
  @State private var isTargetPickerPresented = false

  init(store: WorkbenchStore, presentation: Presentation = .card) {
    self.store = store
    self.presentation = presentation
    _publishing = ObservedObject(wrappedValue: store.publishing)
  }

  private var targetDraftID: UUID? {
    if let workspaceWindowSession {
      return workspaceWindowSession.selectedDraftID
    }
    return workspaceWindowIsKey ? publishing.selectedDraftID : nil
  }

  private var currentDraft: ArticleDraft? {
    guard let targetDraftID else { return nil }
    return publishing.drafts.first { $0.id == targetDraftID }
  }

  private var targetPresentations: [KnowledgeWritingTargetPickerPresentation] {
    let targets = publishing.drafts.map { targetPresentation(for: $0) }
    return KnowledgeWritingTargetPickerPresentation.ordered(
      targets,
      selectedID: targetDraftID
    )
  }

  private func targetPresentation(for draft: ArticleDraft)
    -> KnowledgeWritingTargetPickerPresentation
  {
    let display = store.privateContentDisplay(for: draft)
    guard !display.isMasked else {
      return KnowledgeWritingTargetPickerPresentation(
        id: draft.id,
        updatedAt: draft.updatedAt,
        title: "",
        siteName: nil,
        path: nil,
        isGeneral: draft.isGeneralDraft,
        isMasked: true
      )
    }
    let profile = store.profile(for: draft)
    let path =
      draft.isGeneralDraft
      ? draft.slug.nilIfEmpty
      : (draft.repositoryPath?.nilIfEmpty ?? profile.markdownPath(for: draft))
    return KnowledgeWritingTargetPickerPresentation(
      id: draft.id,
      updatedAt: draft.updatedAt,
      title: display.title,
      siteName: draft.isGeneralDraft ? nil : profile.name,
      path: path,
      isGeneral: draft.isGeneralDraft,
      isMasked: false
    )
  }

  var body: some View {
    switch presentation {
    case .card:
      contextCard
    case .menu:
      compactMenu
    }
  }

  private var contextCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("资料写作目标", systemImage: "text.book.closed")
          .font(.workbenchCardTitle)
        Spacer(minLength: 4)
        targetPicker
      }

      if let draft = currentDraft {
        Text("正在为《\(safeTitle(for: draft))》收集资料")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("正在为《\(safeTitle(for: draft))》收集资料")
      } else {
        Text("尚未选择文章，请先选择一个写作目标。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      returnToWritingButton
        .buttonStyle(.link)
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-writing-context")
  }

  private var compactMenu: some View {
    Button {
      isTargetPickerPresented = true
    } label: {
      Label("更换目标", systemImage: "text.book.closed")
        .labelStyle(.iconOnly)
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .fixedSize()
    .help(targetDescription)
    .accessibilityLabel("更换资料写作目标")
    .accessibilityValue(targetDescription)
    .accessibilityIdentifier("knowledge-writing-target-picker")
    .popover(isPresented: $isTargetPickerPresented, arrowEdge: .bottom) {
      targetPickerPopover
    }
  }

  private var targetDescription: String {
    if let draft = currentDraft {
      return String(localized: "正在为《\(safeTitle(for: draft))》收集资料")
    }
    return String(localized: "尚未选择文章，请先选择一个写作目标。")
  }

  private var returnToWritingButton: some View {
    Button {
      returnToWriting()
    } label: {
      Label("返回写作", systemImage: "arrow.uturn.backward")
    }
    .help("返回当前文章的写作界面")
    .accessibilityIdentifier("knowledge-return-to-writing")
  }

  @ViewBuilder
  private var targetPicker: some View {
    Button {
      isTargetPickerPresented = true
    } label: {
      Label("更换目标", systemImage: "arrow.left.arrow.right")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help("更换资料要写入的文章")
    .accessibilityLabel("更换资料写作目标")
    .accessibilityIdentifier("knowledge-writing-target-picker")
    .popover(isPresented: $isTargetPickerPresented, arrowEdge: .bottom) {
      targetPickerPopover
    }
  }

  private var targetPickerPopover: some View {
    KnowledgeWritingTargetPicker(
      targets: targetPresentations,
      selectedID: targetDraftID,
      onReturnToWriting: {
        isTargetPickerPresented = false
        returnToWriting()
      },
      onSelect: { draftID in
        guard let draft = publishing.drafts.first(where: { $0.id == draftID }) else { return }
        isTargetPickerPresented = false
        selectTarget(draft)
      }
    )
  }

  private func safeTitle(for draft: ArticleDraft) -> String {
    let display = store.privateContentDisplay(for: draft)
    return display.isMasked
      ? String(localized: "私密文章")
      : (display.title.nilIfEmpty ?? String(localized: "未命名文章"))
  }

  private func selectTarget(_ draft: ArticleDraft) {
    if let workspaceWindowSession {
      workspaceWindowSession.selectContext(
        section: workspaceWindowSession.selectedSection,
        draftID: draft.id
      ) { section, draftID in
        guard workspaceWindowIsKey else { return }
        if let draftID {
          _ = store.focusDraft(draftID, section: section)
        } else {
          store.selectSection(section)
        }
      }
    } else {
      _ = store.focusDraft(draft.id, section: publishing.selectedSection)
    }
    EditorAccessibilityAnnouncementCenter.announce(
      String(localized: "已将资料写作目标切换为《\(safeTitle(for: draft))》。"),
      priority: .medium
    )
  }

  private func returnToWriting() {
    if let workspaceWindowSession {
      workspaceWindowSession.selectContext(
        section: .writing,
        draftID: targetDraftID
      ) { section, draftID in
        guard workspaceWindowIsKey else { return }
        if let draftID {
          _ = store.focusDraft(draftID, section: section)
        } else {
          store.selectSection(section)
        }
      }
    } else {
      if let targetDraftID {
        _ = store.focusDraft(targetDraftID, section: .writing)
      } else {
        store.selectSection(.writing)
      }
    }
  }
}

/// A privacy-safe, lightweight projection for choosing the article that receives
/// material from the knowledge library. All searchable and accessible strings
/// come from this projection so masked private metadata cannot escape through a
/// secondary UI surface.
struct KnowledgeWritingTargetPickerPresentation: Identifiable, Hashable {
  let id: UUID
  let updatedAt: Date
  let title: String
  let detail: String
  let help: String
  let accessibilityLabel: String
  private let searchableText: String

  init(
    id: UUID,
    updatedAt: Date,
    title rawTitle: String,
    siteName: String?,
    path: String?,
    isGeneral: Bool,
    isMasked: Bool
  ) {
    self.id = id
    self.updatedAt = updatedAt

    if isMasked {
      title = String(localized: "私密文章")
      detail = String(localized: "内容已遮挡")
      help = String(localized: "内容已遮挡，打开文章或关闭私密遮挡后查看。")
    } else {
      title =
        rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? String(localized: "未命名文章")
        : rawTitle
      if isGeneral {
        detail =
          path.map { "\(String(localized: "通用草稿")) · \($0)" }
          ?? String(localized: "通用草稿，不绑定站点")
      } else {
        let resolvedSiteName = siteName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visibleSiteName =
          resolvedSiteName.isEmpty
          ? String(localized: "未命名站点")
          : resolvedSiteName
        let visiblePath =
          resolvedPath.isEmpty
          ? String(localized: "未配置路径")
          : resolvedPath
        detail = "\(visibleSiteName) · \(visiblePath)"
      }
      help = detail
    }

    accessibilityLabel = "\(title)，\(detail)"
    searchableText = "\(title) \(detail)"
  }

  func matches(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedQuery.isEmpty
      || searchableText.localizedCaseInsensitiveContains(normalizedQuery)
  }

  static func ordered(
    _ targets: [KnowledgeWritingTargetPickerPresentation],
    selectedID: UUID?
  ) -> [KnowledgeWritingTargetPickerPresentation] {
    targets.sorted { lhs, rhs in
      let lhsIsSelected = lhs.id == selectedID
      let rhsIsSelected = rhs.id == selectedID
      if lhsIsSelected != rhsIsSelected { return lhsIsSelected }
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }
}

struct KnowledgeWritingTargetPicker: View {
  let targets: [KnowledgeWritingTargetPickerPresentation]
  let selectedID: UUID?
  let onReturnToWriting: () -> Void
  let onSelect: (UUID) -> Void

  @State private var searchText = ""
  @FocusState private var isSearchFocused: Bool

  private var filteredTargets: [KnowledgeWritingTargetPickerPresentation] {
    targets.filter { $0.matches(searchText) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("选择资料写作目标")
        .font(.headline)

      TextField("搜索文章、站点或路径", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .focused($isSearchFocused)
        .onSubmit {
          if filteredTargets.count == 1, let target = filteredTargets.first,
            target.id != selectedID
          {
            onSelect(target.id)
          }
        }
        .accessibilityLabel("搜索资料写作目标")
        .accessibilityIdentifier("knowledge-writing-target-search")

      List {
        if targets.isEmpty {
          ContentUnavailableView(String(localized: "暂无可用文章"), systemImage: "doc")
            .frame(maxWidth: .infinity, minHeight: 150)
            .listRowSeparator(.hidden)
        } else if filteredTargets.isEmpty {
          ContentUnavailableView(String(localized: "没有匹配的文章"), systemImage: "magnifyingglass")
            .frame(maxWidth: .infinity, minHeight: 150)
            .listRowSeparator(.hidden)
        } else {
          ForEach(filteredTargets) { target in
            Button {
              onSelect(target.id)
            } label: {
              targetRow(target)
            }
            .buttonStyle(.plain)
            .disabled(target.id == selectedID)
            .help(target.help)
            .accessibilityLabel(target.accessibilityLabel)
            .accessibilityIdentifier("knowledge-writing-target-\(target.id.uuidString)")
          }
        }
      }
      .listStyle(.inset)
      .accessibilityLabel("资料写作目标列表")
      .accessibilityIdentifier("knowledge-writing-target-list")

      Divider()

      Button(action: onReturnToWriting) {
        Label("返回写作", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.link)
      .help("返回当前文章的写作界面")
      .accessibilityIdentifier("knowledge-return-to-writing")
    }
    .padding(14)
    .frame(minWidth: 360, idealWidth: 420, maxWidth: 520, minHeight: 280, maxHeight: 460)
    .onAppear { isSearchFocused = true }
  }

  private func targetRow(_ target: KnowledgeWritingTargetPickerPresentation) -> some View {
    HStack(spacing: 9) {
      Image(systemName: target.id == selectedID ? "checkmark.circle.fill" : "doc.text")
        .foregroundStyle(target.id == selectedID ? Color.accentColor : .secondary)
        .frame(width: 16)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(target.title)
          .font(.workbenchItemTitle)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(target.detail)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }
}
