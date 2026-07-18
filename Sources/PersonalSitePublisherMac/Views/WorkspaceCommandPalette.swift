import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceCommandPalette: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  let store: WorkbenchStore
  let onToggleFocusMode: () -> Void
  @State private var query = ""
  @State private var selectedResultID: String?
  @FocusState private var isSearchFocused: Bool

  init(store: WorkbenchStore, onToggleFocusMode: @escaping () -> Void) {
    self.store = store
    self.onToggleFocusMode = onToggleFocusMode
    _publishing = ObservedObject(wrappedValue: store.publishing)
    _shell = ObservedObject(wrappedValue: store.shell)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "command")
          .foregroundStyle(.secondary)
        TextField("搜索文章、工作区或命令…", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isSearchFocused)
          .accessibilityLabel("搜索文章、工作区或命令…")
          .onSubmit(performSelectedResult)
        Text("⌘P")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
      .padding(16)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if !matchingCommands.isEmpty {
              paletteSection(String(localized: "命令")) {
                ForEach(matchingCommands) { command in
                  row(
                    id: commandResultID(command),
                    title: command.title,
                    detail: command.detail,
                    systemImage: command.systemImage,
                    shortcut: command.shortcut,
                    action: command.action
                  )
                }
              }
            }

            if !visibleDrafts.isEmpty {
              paletteSection(String(localized: "文章")) {
                ForEach(visibleDrafts) { draft in
                  row(
                    id: draftResultID(draft),
                    title: draft.title.nilIfEmpty ?? String(localized: "未命名文章"),
                    detail: draft.slug,
                    systemImage: draft.id == publishing.selectedDraftID ? "doc.text.fill" : "doc.text",
                    action: { openDraft(draft.id) }
                  )
                }
              }
            }

            if !matchingSections.isEmpty {
              paletteSection(String(localized: "工作区")) {
                ForEach(matchingSections) { section in
                  row(
                    id: sectionResultID(section),
                    title: localizedSectionTitle(section),
                    detail: section.keyboardShortcutLabel,
                    systemImage: section.systemImage,
                    action: { openSection(section) }
                  )
                }
              }
            }

            if orderedResults.isEmpty {
              ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, minHeight: 220)
            }
          }
          .padding(16)
        }
        .onChange(of: selectedResultID) { _, resultID in
          guard let resultID else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(resultID, anchor: .center)
          }
        }
      }
    }
    .frame(width: 620, height: 560)
    .background(.regularMaterial)
    .onAppear {
      isSearchFocused = true
      synchronizeSelection()
    }
    .onChange(of: query) { _, _ in
      synchronizeSelection()
    }
    .onKeyPress(.downArrow) {
      moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      moveSelection(by: -1)
      return .handled
    }
    .onExitCommand {
      dismiss()
    }
    .accessibilityLabel("命令面板")
    .accessibilityIdentifier("workspace-command-palette")
  }

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchingDrafts: [ArticleDraft] {
    guard !normalizedQuery.isEmpty else {
      return publishing.drafts.sorted { $0.updatedAt > $1.updatedAt }
    }
    return publishing.drafts.filter {
      [$0.title, $0.slug, $0.summary, $0.tags.joined(separator: " ")]
        .joined(separator: " ")
        .localizedStandardContains(normalizedQuery)
    }
    .sorted { $0.updatedAt > $1.updatedAt }
  }

  private var visibleDrafts: [ArticleDraft] {
    Array(matchingDrafts.prefix(12))
  }

  private var matchingSections: [WorkspaceSection] {
    guard !normalizedQuery.isEmpty else { return WorkspaceSection.allCases }
    return WorkspaceSection.allCases.filter { section in
      localizedSectionTitle(section).localizedStandardContains(normalizedQuery)
        || section.rawValue.localizedStandardContains(normalizedQuery)
    }
  }

  private var matchingCommands: [PaletteCommand] {
    commands.filter {
      normalizedQuery.isEmpty
        || $0.title.localizedStandardContains(normalizedQuery)
        || $0.detail.localizedStandardContains(normalizedQuery)
    }
  }

  private var commands: [PaletteCommand] {
    [
      PaletteCommand(
        title: String(localized: "新建文章"),
        detail: String(localized: "创建并进入新的 Markdown 草稿"),
        systemImage: "square.and.pencil",
        shortcut: "⌘N"
      ) {
        store.createDraft()
        store.selectSection(.writing)
        dismiss()
      },
      PaletteCommand(
        title: String(localized: "保存工作台"),
        detail: String(localized: "立即保存当前更改"),
        systemImage: "square.and.arrow.down",
        shortcut: "⌘S"
      ) {
        store.save()
        dismiss()
      },
      PaletteCommand(
        title: String(localized: "运行发布检查"),
        detail: String(localized: "检查当前文章的元数据、正文和发布风险"),
        systemImage: "checkmark.seal"
      ) {
        store.runPreflight()
        store.selectSection(.contentHealth)
        dismiss()
      },
      PaletteCommand(
        title: String(localized: "打开 AI 对话"),
        detail: String(localized: "在右侧继续当前文章的 AI 对话"),
        systemImage: "sparkles",
        shortcut: "⌥⌘A"
      ) {
        guard let draftID = publishing.selectedDraftID else { return }
        store.ai.openChatWorkspace(for: draftID)
        dismiss()
      },
      PaletteCommand(
        title: String(localized: "打开资料库"),
        detail: String(localized: "查找并管理写作资料"),
        systemImage: "books.vertical"
      ) {
        store.selectSection(.library)
        dismiss()
      },
      PaletteCommand(
        title: String(localized: "打开图片工作台"),
        detail: String(localized: "管理文章图片与压缩设置"),
        systemImage: "photo.on.rectangle"
      ) {
        store.selectSection(.images)
        dismiss()
      },
      PaletteCommand(
        title: String(localized: "切换专注写作"),
        detail: String(localized: "使用顶部专注按钮或 ⇧⌘F"),
        systemImage: "scope",
        shortcut: "⇧⌘F"
      ) {
        onToggleFocusMode()
        dismiss()
      },
    ]
  }

  private func paletteSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func row(
    id: String,
    title: String,
    detail: String,
    systemImage: String,
    shortcut: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    let isSelected = selectedResultID == id
    return Button {
      selectedResultID = id
      action()
    } label: {
      HStack(spacing: 11) {
        Image(systemName: systemImage)
          .frame(width: 22)
          .foregroundStyle(isSelected ? WorkbenchTheme.navigationSelection : WorkbenchTheme.primary)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
            .workbenchTruncatedIdentity(title)
          if !detail.isEmpty {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        if let shortcut {
          Text(shortcut)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .background(
        isSelected
          ? WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground)
          : Color.clear,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
    .buttonStyle(.plain)
    .id(id)
    .onHover { isHovering in
      if isHovering {
        selectedResultID = id
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var orderedResults: [PaletteResult] {
    matchingCommands.map { command in
      PaletteResult(id: commandResultID(command), action: command.action)
    }
      + visibleDrafts.map { draft in
        PaletteResult(id: draftResultID(draft), action: { openDraft(draft.id) })
      }
      + matchingSections.map { section in
        PaletteResult(id: sectionResultID(section), action: { openSection(section) })
      }
  }

  private func commandResultID(_ command: PaletteCommand) -> String {
    "command:\(command.id)"
  }

  private func draftResultID(_ draft: ArticleDraft) -> String {
    "draft:\(draft.id.uuidString)"
  }

  private func sectionResultID(_ section: WorkspaceSection) -> String {
    "section:\(section.rawValue)"
  }

  private func synchronizeSelection() {
    let resultIDs = orderedResults.map(\.id)
    if let selectedResultID, resultIDs.contains(selectedResultID) {
      return
    }
    selectedResultID = resultIDs.first
  }

  private func moveSelection(by offset: Int) {
    let results = orderedResults
    guard !results.isEmpty else {
      selectedResultID = nil
      return
    }
    guard let selectedResultID,
          let currentIndex = results.firstIndex(where: { $0.id == selectedResultID }) else {
      self.selectedResultID = results.first?.id
      return
    }
    let nextIndex = (currentIndex + offset + results.count) % results.count
    self.selectedResultID = results[nextIndex].id
  }

  private func performSelectedResult() {
    guard let selectedResultID,
          let result = orderedResults.first(where: { $0.id == selectedResultID }) else {
      return
    }
    result.action()
  }

  private func localizedSectionTitle(_ section: WorkspaceSection) -> String {
    workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
  }

  private func openDraft(_ draftID: UUID) {
    _ = store.focusDraft(draftID, section: .writing)
    dismiss()
  }

  private func openSection(_ section: WorkspaceSection) {
    store.selectSection(section)
    dismiss()
  }
}

private struct PaletteCommand: Identifiable {
  var id: String { title }
  let title: String
  let detail: String
  let systemImage: String
  var shortcut: String?
  let action: () -> Void
}

private struct PaletteResult {
  let id: String
  let action: () -> Void
}
