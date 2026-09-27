import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryHTMLSourceWorkspaceView: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  @ObservedObject var session: RepositoryHTMLSourceSession
  @State private var searchQuery = ""
  @State private var displayedFiles: [RepositoryHTMLFileDescriptor] = []
  @State private var displayedRepositoryIdentity: RepositoryHTMLSourceRepositoryIdentity?
  @State private var selectedRepositoryPath: String?
  @State private var fileFilterTask: Task<Void, Never>?
  @State private var fileFilterGeneration = 0
  @FocusState private var isFileListFocused: Bool

  init(store: WorkbenchStore, session: RepositoryHTMLSourceSession) {
    _shell = ObservedObject(wrappedValue: store.shell)
    _session = ObservedObject(wrappedValue: session)
  }

  var body: some View {
    HSplitView {
      sourceFileSidebar
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)

      fileActions
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("html-source-workspace")
    .task(id: repositoryIdentity) {
      selectedRepositoryPath = nil
      displayedFiles = []
      displayedRepositoryIdentity = nil
      searchQuery = ""
      await session.refreshFiles(profile: shell.activeProfile)
      scheduleFileFilter()
      handleQueuedOpenRequest()
    }
    .onChange(of: searchQuery) { _, _ in scheduleFileFilter() }
    .onChange(of: session.files) { _, _ in
      scheduleFileFilter()
      handleQueuedOpenRequest()
    }
    .onChange(of: session.openRequest) { _, _ in handleQueuedOpenRequest() }
    .onDisappear { fileFilterTask?.cancel() }
    .alert(
      "无法访问 HTML 文件",
      isPresented: Binding(
        get: { session.errorMessage != nil },
        set: { if !$0 { session.dismissError() } }
      )
    ) {
      Button("好", role: .cancel) { session.dismissError() }
    } message: {
      Text(session.errorMessage ?? "")
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
          ProgressView().controlSize(.small)
        } else {
          Button {
            Task { await session.refreshFiles(profile: shell.activeProfile) }
          } label: {
            Image(systemName: "arrow.clockwise")
              .frame(width: 22, height: 22)
          }
          .buttonStyle(.borderless)
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
            selectedRepositoryPath = displayedFiles.first?.repositoryPath
          }
          revealSelectedFile()
        }
        .onKeyPress(.downArrow) {
          selectedRepositoryPath = displayedFiles.first?.repositoryPath
          isFileListFocused = true
          return .handled
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)

      Divider()

      if session.isLoading && displayedFiles.isEmpty {
        VStack(spacing: 10) {
          ProgressView()
          Text("正在扫描 HTML 文件…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if displayedFiles.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: searchQuery.isEmpty ? "doc.text" : "magnifyingglass")
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
            Image(systemName: "doc.text")
              .foregroundStyle(workbenchAccentColor)
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
          }
          .padding(.vertical, 4)
          .tag(file.repositoryPath)
          .contextMenu {
            Button("在 Finder 中显示") { reveal(file) }
            Button("用默认应用打开") { openWithDefaultApplication(file) }
          }
          .accessibilityLabel(URL(fileURLWithPath: file.repositoryPath).lastPathComponent)
          .accessibilityValue(file.repositoryPath)
        }
        .listStyle(.sidebar)
        .focused($isFileListFocused)
        .onKeyPress(.return) {
          revealSelectedFile()
          return .handled
        }
      }

      if let status = session.statusMessage {
        Divider()
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
  }

  @ViewBuilder
  private var fileActions: some View {
    if let file = selectedFile {
      VStack(alignment: .leading, spacing: 16) {
        Image(systemName: "doc.text")
          .font(.system(size: 36))
          .foregroundStyle(workbenchAccentColor)
        Text(URL(fileURLWithPath: file.repositoryPath).lastPathComponent)
          .font(.title2.weight(.semibold))
          .lineLimit(2)
          .truncationMode(.middle)
        Text(file.repositoryPath)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteSize), countStyle: .file))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let date = file.modificationDate {
          Text("修改于 \(date.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          Button {
            reveal(file)
          } label: {
            Label("在 Finder 中显示", systemImage: "folder")
          }
          .workbenchProminentActionStyle()
          .accessibilityIdentifier("html-source-reveal-in-finder")

          Button {
            openWithDefaultApplication(file)
          } label: {
            Label("用默认应用打开", systemImage: "arrow.up.forward.app")
          }
          .accessibilityIdentifier("html-source-open-with-default-app")
        }
        Text("如需编辑 HTML 模板，可在 Finder 中选择文件并使用你常用的编辑器打开。")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      EmptyStateView(
        title: "选择一个 HTML 文件",
        message: "选择文件后，可在 Finder 中显示，或用 macOS 的默认应用打开。",
        systemImage: "doc.text",
        density: .compactPane
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var selectedFile: RepositoryHTMLFileDescriptor? {
    guard let selectedRepositoryPath,
      displayedRepositoryIdentity == repositoryIdentity,
      session.repositoryIdentity == repositoryIdentity
    else { return nil }
    return displayedFiles.first { $0.repositoryPath == selectedRepositoryPath }
  }

  private var repositoryIdentity: RepositoryHTMLSourceRepositoryIdentity {
    RepositoryHTMLSourceRepositoryIdentity(profile: shell.activeProfile)
  }

  private func scheduleFileFilter() {
    fileFilterTask?.cancel()
    fileFilterGeneration += 1
    let generation = fileFilterGeneration
    let files = session.files
    let query = searchQuery
    let identity = session.repositoryIdentity
    guard identity == repositoryIdentity else {
      displayedFiles = []
      displayedRepositoryIdentity = nil
      selectedRepositoryPath = nil
      return
    }
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      displayedFiles = files
      displayedRepositoryIdentity = identity
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
      displayedRepositoryIdentity = identity
      restoreFileSelectionIfNeeded(in: filtered)
    }
  }

  private func restoreFileSelectionIfNeeded(in files: [RepositoryHTMLFileDescriptor]) {
    if let selectedRepositoryPath,
      !files.contains(where: { $0.repositoryPath == selectedRepositoryPath })
    {
      self.selectedRepositoryPath = nil
    }
  }

  private func handleQueuedOpenRequest() {
    guard let request = session.openRequest else { return }
    guard request.repositoryIdentity == repositoryIdentity else {
      session.consumeOpenRequest(id: request.id)
      return
    }
    guard session.repositoryIdentity == repositoryIdentity, !session.isLoading else { return }
    session.consumeOpenRequest(id: request.id)
    do {
      let file = try RepositoryHTMLFileService().descriptor(
        profile: shell.activeProfile,
        repositoryPath: request.repositoryPath
      )
      session.includeValidatedFile(file, profile: shell.activeProfile)
      searchQuery = ""
      displayedFiles = session.files
      displayedRepositoryIdentity = repositoryIdentity
      selectedRepositoryPath = request.repositoryPath
    } catch {
      session.reportError(error)
    }
  }

  private func canActOnDisplayedFile() -> Bool {
    guard displayedRepositoryIdentity == repositoryIdentity,
      session.repositoryIdentity == repositoryIdentity
    else {
      session.reportError(HTMLFileOpenError.repositoryChanged)
      return false
    }
    return true
  }

  private func revealSelectedFile() {
    guard let selectedFile else { return }
    reveal(selectedFile)
  }

  private func reveal(_ file: RepositoryHTMLFileDescriptor) {
    guard canActOnDisplayedFile() else { return }
    do {
      try RepositoryHTMLFileService().withOriginalFileURL(
        profile: shell.activeProfile,
        repositoryPath: file.repositoryPath
      ) { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    } catch {
      session.reportError(error)
    }
  }

  private func openWithDefaultApplication(_ file: RepositoryHTMLFileDescriptor) {
    guard canActOnDisplayedFile() else { return }
    do {
      try RepositoryHTMLFileService().withOriginalFileURL(
        profile: shell.activeProfile,
        repositoryPath: file.repositoryPath
      ) { url in
        guard NSWorkspace.shared.open(url) else {
          throw HTMLFileOpenError.defaultApplicationUnavailable
        }
      }
    } catch {
      session.reportError(error)
    }
  }
}

private enum HTMLFileOpenError: LocalizedError {
  case repositoryChanged
  case defaultApplicationUnavailable

  var errorDescription: String? {
    switch self {
    case .repositoryChanged:
      return String(localized: "当前仓库已切换，请重新选择 HTML 文件。")
    case .defaultApplicationUnavailable:
      return String(localized: "macOS 无法用默认应用打开该 HTML 文件。")
    }
  }
}
