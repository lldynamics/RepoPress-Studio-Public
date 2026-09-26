import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// Presents one external project-file conflict at a time. The panel owns no
/// draft state: every load and resolution is delegated to the store, which
/// revalidates the frozen review before it changes any persisted state.
@MainActor
enum ProjectFileConflictReviewPanel {
  private static var coordinators: [UUID: ProjectFileConflictReviewPanelCoordinator] = [:]

  static func present(for store: WorkbenchStore, draftID: UUID) {
    if let coordinator = coordinators[draftID] {
      coordinator.panel.makeKeyAndOrderFront(nil)
      return
    }

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1_160, height: 760),
      styleMask: [.titled, .closable, .resizable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = String(localized: "项目文件冲突审阅")
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 900, height: 620)
    panel.setFrameAutosaveName("ProjectFileConflictReviewPanel")

    let coordinator = ProjectFileConflictReviewPanelCoordinator(draftID: draftID, panel: panel)
    panel.delegate = coordinator
    panel.contentView = NSHostingView(
      rootView: ProjectFileConflictReviewView(store: store, draftID: draftID) {
        panel.close()
      }
    )
    coordinators[draftID] = coordinator
    panel.center()
    panel.makeKeyAndOrderFront(nil)
  }

  fileprivate static func releasePanel(for draftID: UUID) {
    coordinators[draftID] = nil
  }
}

@MainActor
private final class ProjectFileConflictReviewPanelCoordinator: NSObject, NSWindowDelegate {
  let draftID: UUID
  let panel: NSPanel

  init(draftID: UUID, panel: NSPanel) {
    self.draftID = draftID
    self.panel = panel
  }

  func windowWillClose(_ notification: Notification) {
    ProjectFileConflictReviewPanel.releasePanel(for: draftID)
  }
}

private enum ProjectFileConflictResolutionChoice: Equatable {
  case keepBoth
  case useDisk
  case mergedDocument
}

@MainActor
private struct ProjectFileConflictReviewView: View {
  @ObservedObject var store: WorkbenchStore
  let draftID: UUID
  let close: () -> Void

  @State private var review: ProjectFileConflictReview?
  @State private var mergedDocument = ""
  @State private var isLoading = false
  @State private var isResolving = false
  @State private var loadError: String?
  @State private var resolutionError: String?
  @State private var pendingConfirmation: ProjectFileConflictResolutionChoice?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 900, idealWidth: 1_160, minHeight: 620, idealHeight: 760)
    .task { await loadReview(resetMergedDocument: true) }
    .confirmationDialog(
      confirmationTitle,
      isPresented: confirmationPresented,
      titleVisibility: .visible,
      presenting: pendingConfirmation
    ) { choice in
      Button(confirmationButtonTitle(choice), role: choice == .mergedDocument ? .destructive : nil) {
        pendingConfirmation = nil
        resolve(choice)
      }
      Button("取消", role: .cancel) { pendingConfirmation = nil }
    } message: { choice in
      Text(confirmationMessage(choice))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("项目文件冲突审阅")
    .accessibilityIdentifier("project-file-conflict-review-panel")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Label("项目文件冲突审阅", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
          .font(.headline)
        Spacer()
        Button("关闭", action: close)
          .keyboardShortcut(.cancelAction)
          .disabled(isResolving)
          .accessibilityIdentifier("project-file-conflict-close")
      }
      if let review {
        Text(review.draft.title)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
          .textSelection(.enabled)
        Text(review.repositoryPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text("项目根目录：\(review.rootPath)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else {
        Text("正在读取软件草稿和项目文件…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private var content: some View {
    if isLoading && review == nil {
      ProgressView(String(localized: "正在读取两份完整 Markdown…"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("project-file-conflict-loading")
    } else if let review {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("下方两份内容都是完整 Markdown，包含 Front Matter 元数据。处理前请先核对外部修改。")
            .font(.callout)
            .foregroundStyle(.secondary)

          HStack(alignment: .top, spacing: 12) {
            readOnlyDocument(
              title: LocalizedStringKey("软件草稿"),
              detail: LocalizedStringKey("应用内等待写入的版本"),
              document: review.draftDocument,
              identifier: "project-file-conflict-draft-document"
            )
            readOnlyDocument(
              title: LocalizedStringKey("项目版本"),
              detail: LocalizedStringKey("当前磁盘上的外部修改"),
              document: review.diskDocument,
              identifier: "project-file-conflict-disk-document"
            )
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("合并后保存")
              .font(.callout.weight(.semibold))
            Text("如需保留两边内容，请在这里编辑完整 Markdown。提交前还会再次确认。")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextEditor(text: $mergedDocument)
              .font(.system(.body, design: .monospaced))
              .scrollContentBackground(.hidden)
              .padding(8)
              .background(
                WorkbenchBackgroundStyle.control,
                in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              )
              .frame(minHeight: 260)
              .disabled(isLoading || isResolving)
              .accessibilityLabel("合并后的完整 Markdown")
              .accessibilityHint("编辑后需点击保存合并稿并确认")
              .accessibilityIdentifier("project-file-conflict-merged-document")
          }
        }
        .padding(16)
      }
    } else {
      ContentUnavailableView(
        String(localized: "无法读取冲突内容"),
        systemImage: "exclamationmark.triangle",
        description: Text(loadError ?? String(localized: "请重新读取；应用不会自动覆盖未审阅内容。"))
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("project-file-conflict-load-error")
    }
  }

  private var footer: some View {
    VStack(spacing: 8) {
      if let resolutionError {
        Label(resolutionError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("project-file-conflict-resolution-error")
      }
      HStack(alignment: .center, spacing: 10) {
        Text(actionExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        if isLoading || isResolving {
          ProgressView().controlSize(.small)
        }
        Button("重新读取") {
          Task { await loadReview(resetMergedDocument: false) }
        }
        .disabled(isLoading || isResolving)
        .accessibilityHint("重新读取软件草稿和项目文件；不会保存修改")
        .accessibilityIdentifier("project-file-conflict-reload")
        Button("保留两份") {
          resolve(.keepBoth)
        }
        .disabled(review == nil || isLoading || isResolving)
        .accessibilityHint("保留软件草稿和项目版本，不会改写项目文件")
        .accessibilityIdentifier("project-file-conflict-keep-both")
        Button("采用项目版本") {
          pendingConfirmation = .useDisk
        }
        .disabled(review == nil || isLoading || isResolving)
        .accessibilityHint("先保留软件草稿恢复副本，再采用当前项目版本")
        .accessibilityIdentifier("project-file-conflict-use-disk")
        Button("保存合并稿…") {
          pendingConfirmation = .mergedDocument
        }
        .workbenchProminentActionStyle()
        .disabled(review == nil || mergedDocument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading || isResolving)
        .accessibilityHint("保存前需要确认；只提交当前编辑的完整 Markdown")
        .accessibilityIdentifier("project-file-conflict-save-merged")
      }
    }
    .padding(16)
  }

  private var actionExplanation: String {
    if isResolving { return String(localized: "正在应用已确认的处理方式…") }
    if isLoading { return String(localized: "正在读取当前版本…") }
    return String(localized: "“保留两份”不会改写项目文件；“采用项目版本”会先保留软件草稿恢复副本。")
  }

  private var confirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingConfirmation != nil },
      set: { isPresented in
        if !isPresented { pendingConfirmation = nil }
      }
    )
  }

  private var confirmationTitle: String {
    switch pendingConfirmation {
    case .mergedDocument: return String(localized: "保存合并后的文档？")
    case .useDisk: return String(localized: "采用当前项目版本？")
    case .keepBoth, nil: return String(localized: "确认处理冲突？")
    }
  }

  private func confirmationButtonTitle(_ choice: ProjectFileConflictResolutionChoice) -> String {
    switch choice {
    case .keepBoth: return String(localized: "保留两份")
    case .useDisk: return String(localized: "保留恢复副本并采用项目版本")
    case .mergedDocument: return String(localized: "保存合并稿")
    }
  }

  private func confirmationMessage(_ choice: ProjectFileConflictResolutionChoice) -> String {
    switch choice {
    case .keepBoth:
      return String(localized: "软件草稿和项目版本都会保留，不会写入项目文件。")
    case .useDisk:
      return String(localized: "软件草稿会先保留为恢复副本，再采用当前项目版本。此操作仍会校验项目文件是否在审阅后变更。")
    case .mergedDocument:
      return String(localized: "将保存当前编辑的完整 Markdown。系统会再次校验项目文件；若已变更，合并稿会保留在此面板中供你重新审阅。")
    }
  }

  private func readOnlyDocument(
    title: LocalizedStringKey,
    detail: LocalizedStringKey,
    document: String,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.callout.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        Text(verbatim: document)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
      }
      .frame(minHeight: 300, maxHeight: 420)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityLabel(Text(title))
      .accessibilityIdentifier(identifier)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func loadReview(resetMergedDocument: Bool) async {
    guard !isLoading, !isResolving else { return }
    isLoading = true
    loadError = nil
    resolutionError = nil
    defer { isLoading = false }
    do {
      let loadedReview = try await store.prepareProjectFileConflictReview(draftID: draftID)
      review = loadedReview
      if resetMergedDocument {
        mergedDocument = loadedReview.draftDocument
      }
    } catch {
      review = nil
      loadError = error.localizedDescription
    }
  }

  private func resolve(_ choice: ProjectFileConflictResolutionChoice) {
    guard let review, !isLoading, !isResolving else { return }
    let resolution: ProjectFileConflictResolution
    switch choice {
    case .keepBoth:
      resolution = .keepBoth
    case .useDisk:
      resolution = .useDisk
    case .mergedDocument:
      resolution = .mergedDocument(mergedDocument)
    }
    isResolving = true
    resolutionError = nil
    Task {
      do {
        try await store.resolveProjectFileConflict(review, resolution: resolution)
        await MainActor.run {
          isResolving = false
          showSuccessAndClose(for: choice)
        }
      } catch {
        await MainActor.run {
          isResolving = false
          resolutionError = error.localizedDescription
        }
      }
    }
  }

  private func showSuccessAndClose(for choice: ProjectFileConflictResolutionChoice) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = String(localized: "冲突处理完成")
    switch choice {
    case .keepBoth:
      alert.informativeText = String(localized: "软件草稿和项目版本均已保留，项目文件未被写入。")
    case .useDisk:
      alert.informativeText = String(localized: "已保留软件草稿恢复副本，并采用了当前项目版本。")
    case .mergedDocument:
      alert.informativeText = String(localized: "合并后的完整 Markdown 已保存。")
    }
    alert.addButton(withTitle: String(localized: "关闭"))
    Task { @MainActor in
      _ = await WindowSheetPresenter.response(to: alert)
      close()
    }
  }
}
