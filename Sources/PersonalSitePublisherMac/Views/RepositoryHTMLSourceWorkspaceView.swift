import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryHTMLSourceWorkspaceView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var session: RepositoryHTMLSourceSession
  @State private var searchQuery = ""
  @State private var displayedFiles: [RepositoryHTMLFileDescriptor] = []
  @State private var selectedRepositoryPath: String?
  @State private var fileFilterTask: Task<Void, Never>?
  @State private var fileFilterGeneration = 0
  @State private var findRequest: HTMLSourceFindRequest?
  @State private var pendingAction: PendingAction?
  @FocusState private var isFileListFocused: Bool

  var body: some View {
    HSplitView {
      sourceFileSidebar
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)

      sourceEditor
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("html-source-workspace")
    .focusedSceneValue(\.repositorySourceEditorCommandActions, commandActions)
    .task(id: repositoryIdentity) {
      if session.activeDocument == nil || !session.hasUnsavedChanges {
        if !session.isDocumentFromCurrentRepository(store.activeProfile) {
          session.close()
        }
      }
      await session.refreshFiles(profile: store.activeProfile)
      scheduleFileFilter()
      handleQueuedOpenRequest()
    }
    .onChange(of: searchQuery) { _, _ in
      scheduleFileFilter()
    }
    .onChange(of: session.files) { _, _ in
      scheduleFileFilter()
    }
    .onChange(of: session.activeDocument?.repositoryPath) { _, path in
      if let path {
        selectedRepositoryPath = path
      }
    }
    .onChange(of: session.openRequest) { _, _ in
      handleQueuedOpenRequest()
    }
    .onChange(of: session.isSaving) { _, isSaving in
      if !isSaving {
        handleQueuedOpenRequest()
      }
    }
    .onDisappear {
      fileFilterTask?.cancel()
    }
    .alert(
      "HTML 源码操作失败",
      isPresented: Binding(
        get: { session.errorMessage != nil },
        set: { if !$0 { session.dismissError() } }
      )
    ) {
      Button("好", role: .cancel) {
        session.dismissError()
      }
      if session.hasExternalConflict {
        Button("重新载入磁盘版本") {
          pendingAction = .reload
        }
      }
    } message: {
      Text(session.errorMessage ?? "")
    }
    .confirmationDialog(
      pendingAction?.confirmationTitle ?? "",
      isPresented: Binding(
        get: { pendingAction != nil },
        set: { if !$0 { pendingAction = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(pendingAction?.confirmationButtonTitle ?? "继续", role: .destructive) {
        performPendingAction()
      }
      Button("取消", role: .cancel) {
        pendingAction = nil
      }
    } message: {
      Text("当前文件还有未保存的更改。继续会丢弃这些更改。")
    }
  }

  private var sourceFileSidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("HTML 源文件")
            .font(.headline)
          Text("只显示 .html / .htm")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if session.isLoading {
          ProgressView()
            .controlSize(.small)
        } else {
          Button {
            Task { await session.refreshFiles(profile: store.activeProfile) }
          } label: {
            Image(systemName: "arrow.clockwise")
              .frame(width: 22, height: 22)
          }
          .buttonStyle(.borderless)
          .disabled(session.isSaving)
          .help("刷新 HTML 文件列表")
          .accessibilityLabel("刷新 HTML 文件列表")
        }
      }
      .padding(14)

      TextField("搜索文件名或路径", text: $searchQuery)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索 HTML 源文件")
        .accessibilityHint("按文件名或仓库相对路径筛选")
        .onSubmit {
          if selectedRepositoryPath == nil {
            selectedRepositoryPath = displayedFiles.first(where: \.isEditable)?.repositoryPath
          }
          openSelectedFile()
        }
        .onKeyPress(.downArrow) {
          selectFirstVisibleFile()
          isFileListFocused = true
          return .handled
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)

      Divider()

      if session.isLoading && session.files.isEmpty && displayedFiles.isEmpty {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.regular)
          Text("正在扫描 HTML 文件…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if displayedFiles.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: searchQuery.isEmpty ? "chevron.left.forwardslash.chevron.right" : "magnifyingglass")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(.secondary)
          Text(searchQuery.isEmpty ? "没有 HTML 源文件" : "没有匹配文件")
            .font(.headline)
          Text(searchQuery.isEmpty ? "仓库中的 HTML 或 HTM 文件会显示在这里。" : "清除搜索条件后查看全部文件。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          if !searchQuery.isEmpty {
            Button("清除搜索") { searchQuery = "" }
          }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(displayedFiles, selection: $selectedRepositoryPath) { file in
          HStack(spacing: 9) {
            Image(systemName: file.isEditable ? "chevron.left.forwardslash.chevron.right" : "exclamationmark.triangle")
              .foregroundStyle(file.isEditable ? WorkbenchTheme.navigationSelection : WorkbenchTheme.warning)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
              Text(URL(fileURLWithPath: file.repositoryPath).lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
              Text(file.repositoryPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if session.activeDocument?.repositoryPath == file.repositoryPath {
              Circle()
                .fill(session.hasUnsavedChanges ? WorkbenchTheme.warning : WorkbenchTheme.success)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            }
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .tag(file.repositoryPath)
          .onTapGesture {
            selectedRepositoryPath = file.repositoryPath
            requestOpen(file)
          }
          .help(file.isEditable ? file.repositoryPath : "文件超过 4 MB，只能在外部编辑器中打开。")
          .accessibilityLabel(URL(fileURLWithPath: file.repositoryPath).lastPathComponent)
          .accessibilityValue(file.repositoryPath)
        }
        .listStyle(.sidebar)
        .focused($isFileListFocused)
        .onKeyPress(.return) {
          openSelectedFile()
          return .handled
        }
      }

      if let status = session.statusMessage {
        Divider()
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
  }

  @ViewBuilder
  private var sourceEditor: some View {
    if let document = session.activeDocument {
      VStack(spacing: 0) {
        sourceEditorToolbar(document)
        Divider()

        if !session.isDocumentFromCurrentRepository(store.activeProfile) {
          Label(
            "当前站点已切换。此文件仍保留在编辑器中，但必须切回原仓库才能保存。",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchTheme.warning.opacity(0.08))
        }

        if document.hasMixedLineEndings {
          Label(
            "此文件混用了多种换行符。为避免产生整文件差异，源码编辑保持只读；请先在外部工具中统一换行符。",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchTheme.warning.opacity(0.08))
        }

        if let firstDiagnostic = session.diagnostics.first {
          HStack(spacing: 8) {
            Image(systemName: firstDiagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            Text("第 \(firstDiagnostic.line) 行：\(firstDiagnostic.title)")
              .font(.callout.weight(.medium))
            Text(firstDiagnostic.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer()
            if session.diagnostics.count > 1 {
              Text("另有 \(session.diagnostics.count - 1) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .foregroundStyle(firstDiagnostic.severity == .error ? WorkbenchTheme.risk : WorkbenchTheme.warning)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(WorkbenchBackgroundStyle.subtle)
        }

        MacHTMLSourceTextView(
          text: Binding(
            get: { session.activeDocument?.text ?? document.text },
            set: { newValue in
              session.updateText(newValue)
            }
          ),
          isEditable: !session.isOpeningDocument
            && session.isDocumentFromCurrentRepository(store.activeProfile)
            && !document.hasMixedLineEndings,
          findRequest: findRequest
        )
        .id(document.id + "|\(session.editorResetGeneration)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      EmptyStateView(
        title: "选择一个 HTML 文件",
        message: "高级源码编辑会保留文件编码和换行符，并在保存前检查外部修改。",
        systemImage: "chevron.left.forwardslash.chevron.right",
        density: .compactPane
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
  }

  private func sourceEditorToolbar(_ document: RepositoryTextDocument) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 7) {
          Text(URL(fileURLWithPath: document.repositoryPath).lastPathComponent)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
          Label(
            session.hasUnsavedChanges ? "未保存" : "已保存",
            systemImage: session.hasUnsavedChanges ? "circle.fill" : "checkmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(session.hasUnsavedChanges ? WorkbenchTheme.warning : WorkbenchTheme.success)
        }
        Text(document.repositoryPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(document.repositoryPath)
          .contextMenu {
            Button("复制路径") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(document.repositoryPath, forType: .string)
            }
          }
      }

      Spacer(minLength: 8)

      Button {
        findRequest = HTMLSourceFindRequest(action: .show)
      } label: {
        Label("查找", systemImage: "magnifyingglass")
      }
      .help("查找源码（⌘F）")

      Button {
        requestReload()
      } label: {
        Label("重新载入", systemImage: "arrow.clockwise")
      }
      .disabled(session.isSaving || session.isOpeningDocument)
      .help("重新读取磁盘内容")

      Button {
        openInSystemBrowser(document)
      } label: {
        Label("系统预览", systemImage: "safari")
      }
      .disabled(document.dialect != .html || session.hasUnsavedChanges)
      .help(systemPreviewHelp(document))

      Button {
        save()
      } label: {
        if session.isSaving {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("保存", systemImage: "square.and.arrow.down")
        }
      }
      .workbenchProminentActionStyle()
      .disabled(!canSave)
      .accessibilityIdentifier("html-source-save")

      Button {
        requestClose()
      } label: {
        Image(systemName: "xmark")
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .disabled(session.isSaving)
      .help("关闭源码文件")
      .accessibilityLabel("关闭源码文件")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var repositoryIdentity: String {
    "\(store.activeProfile.id.uuidString)|\(store.activeProfile.localRepositoryRootPath)"
  }

  private var canSave: Bool {
    session.hasUnsavedChanges
      && !session.isSaving
      && session.activeDocument?.hasMixedLineEndings != true
      && session.isDocumentFromCurrentRepository(store.activeProfile)
  }

  private var commandActions: RepositorySourceEditorCommandActions {
    RepositorySourceEditorCommandActions(
      hasDocument: session.activeDocument != nil,
      canSave: canSave,
      save: save,
      showFind: { findRequest = HTMLSourceFindRequest(action: .show) },
      findNext: { performFindAction(.next) },
      findPrevious: { performFindAction(.previous) },
      reload: requestReload
    )
  }

  private func requestOpen(_ file: RepositoryHTMLFileDescriptor) {
    guard file.isEditable, !session.isSaving else { return }
    guard session.activeDocument?.repositoryPath != file.repositoryPath else { return }
    if session.hasUnsavedChanges {
      pendingAction = .open(file.repositoryPath)
    } else {
      Task { await open(file.repositoryPath) }
    }
  }

  private func openSelectedFile() {
    guard let selectedRepositoryPath,
          let file = displayedFiles.first(where: { $0.repositoryPath == selectedRepositoryPath }) else {
      return
    }
    requestOpen(file)
  }

  private func selectFirstVisibleFile() {
    guard let path = displayedFiles.first(where: \.isEditable)?.repositoryPath else { return }
    selectedRepositoryPath = path
  }

  private func scheduleFileFilter() {
    fileFilterTask?.cancel()
    fileFilterGeneration += 1
    let generation = fileFilterGeneration
    let files = session.files
    let query = searchQuery
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedQuery.isEmpty {
      displayedFiles = files
      restoreFileSelectionIfNeeded(in: files)
      return
    }
    fileFilterTask = Task {
      try? await Task.sleep(for: .milliseconds(140))
      guard !Task.isCancelled else { return }
      let filtered = await Task.detached(priority: .userInitiated) {
        RepositoryHTMLSourceFileFilter.filtered(files, query: query)
      }.value
      guard !Task.isCancelled, fileFilterGeneration == generation else { return }
      displayedFiles = filtered
      restoreFileSelectionIfNeeded(in: filtered)
    }
  }

  private func restoreFileSelectionIfNeeded(in files: [RepositoryHTMLFileDescriptor]) {
    if let activePath = session.activeDocument?.repositoryPath,
       files.contains(where: { $0.repositoryPath == activePath }) {
      selectedRepositoryPath = activePath
    } else if let selectedRepositoryPath,
              !files.contains(where: { $0.repositoryPath == selectedRepositoryPath }) {
      self.selectedRepositoryPath = nil
    }
  }

  private func handleQueuedOpenRequest() {
    guard !session.isSaving, let request = session.openRequest else { return }
    session.consumeOpenRequest(id: request.id)
    if session.activeDocument?.repositoryPath == request.repositoryPath {
      store.setInspectorPresented(true)
      return
    }
    if session.hasUnsavedChanges {
      pendingAction = .open(request.repositoryPath)
    } else {
      Task { await open(request.repositoryPath) }
    }
  }

  private func requestReload() {
    guard session.activeDocument != nil, !session.isSaving else { return }
    if session.hasUnsavedChanges {
      pendingAction = .reload
    } else {
      Task { await session.reload(profile: store.activeProfile) }
    }
  }

  private func requestClose() {
    guard !session.isSaving else { return }
    if session.hasUnsavedChanges {
      pendingAction = .close
    } else {
      session.close()
    }
  }

  private func performPendingAction() {
    guard let action = pendingAction else { return }
    pendingAction = nil
    switch action {
    case let .open(path):
      Task { await open(path) }
    case .reload:
      Task { await session.reload(profile: store.activeProfile) }
    case .close:
      session.close()
    }
  }

  private func open(_ path: String) async {
    await session.open(path: path, profile: store.activeProfile)
    if session.activeDocument?.repositoryPath == path {
      store.setInspectorPresented(true)
      EditorAccessibilityAnnouncementCenter.announce(
        String(localized: "已打开 HTML 源文件：\(path)"),
        priority: .high
      )
    }
  }

  private func save() {
    guard canSave else { return }
    Task {
      if await session.save(profile: store.activeProfile) {
        EditorAccessibilityAnnouncementCenter.announce(
          String(localized: "HTML 源文件已保存。"),
          priority: .high
        )
        await store.repository.scanAsync()
        await session.refreshFiles(profile: store.activeProfile)
      }
    }
  }

  private func openInSystemBrowser(_ document: RepositoryTextDocument) {
    guard document.dialect == .html, !session.hasUnsavedChanges else { return }
    do {
      _ = try HTMLSourceEditingService().withResolvedFileURL(
        profile: store.activeProfile,
        repositoryPath: document.repositoryPath
      ) { url in
        NSWorkspace.shared.open(url)
      }
    } catch {
      EditorAccessibilityAnnouncementCenter.announce(error.localizedDescription, priority: .high)
    }
  }

  private func systemPreviewHelp(_ document: RepositoryTextDocument) -> String {
    if document.dialect != .html {
      return String(localized: "模板文件请使用资料库中的本地站点预览。")
    }
    if session.hasUnsavedChanges {
      return String(localized: "先保存更改，再用系统浏览器预览。")
    }
    return String(localized: "使用系统默认浏览器打开这个 HTML 文件。")
  }

  private func performFindAction(_ action: HTMLSourceFindRequest.Action) {
    findRequest = HTMLSourceFindRequest(action: action)
  }

  private enum PendingAction: Identifiable {
    case open(String)
    case reload
    case close

    var id: String {
      switch self {
      case let .open(path): "open-\(path)"
      case .reload: "reload"
      case .close: "close"
      }
    }

    var confirmationTitle: String {
      switch self {
      case .open: String(localized: "放弃更改并打开其他文件？")
      case .reload: String(localized: "放弃更改并重新载入？")
      case .close: String(localized: "放弃更改并关闭文件？")
      }
    }

    var confirmationButtonTitle: String {
      switch self {
      case .open: String(localized: "放弃并打开")
      case .reload: String(localized: "放弃并重新载入")
      case .close: String(localized: "放弃并关闭")
      }
    }
  }
}
