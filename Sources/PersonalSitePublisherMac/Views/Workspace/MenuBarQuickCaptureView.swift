import AppKit
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class MenuBarQuickCaptureState: ObservableObject {
  @Published var text = ""
  @Published private(set) var isSaving = false
  @Published private(set) var feedback: String?

  var canSave: Bool {
    !isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func save(using knowledge: KnowledgeStore) async {
    guard canSave else { return }
    let capturedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    isSaving = true
    defer { isSaving = false }

    let title = String(capturedText.split(separator: "\n", maxSplits: 1).first?.prefix(80) ?? "")
    let note = KnowledgeNote(title: title, markdown: capturedText)
    if await knowledge.createNote(note) != nil {
      if text.trimmingCharacters(in: .whitespacesAndNewlines) == capturedText {
        text = ""
      }
      feedback = String(localized: "速记已保存到知识笔记")
    } else {
      feedback = knowledge.lastError ?? String(localized: "速记保存失败")
    }
  }
}

struct MenuBarQuickCaptureView: View {
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  @ObservedObject var capture: MenuBarQuickCaptureState
  let openWorkbench: () -> Void

  var body: some View {
    Group {
      if let store = coordinator.store {
        MenuBarReadyView(store: store, capture: capture, openWorkbench: openWorkbench)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Label("RepoPress Studio", systemImage: "square.and.pencil")
            .font(.headline)
          Text("请先在主窗口完成数据文件夹设置。")
            .foregroundStyle(.secondary)
          Button("打开主窗口", action: openWorkbench)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
      }
    }
  }
}

private struct MenuBarReadyView: View {
  let store: WorkbenchStore
  @ObservedObject var capture: MenuBarQuickCaptureState
  @ObservedObject private var status: WorkbenchPublishStatusFeatureFacade
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  let openWorkbench: () -> Void
  @State private var isRefreshing = false
  @FocusState private var isCaptureFocused: Bool

  init(
    store: WorkbenchStore,
    capture: MenuBarQuickCaptureState,
    openWorkbench: @escaping () -> Void
  ) {
    self.store = store
    self.capture = capture
    _status = ObservedObject(wrappedValue: store.publishStatus)
    _shell = ObservedObject(wrappedValue: store.shell)
    self.openWorkbench = openWorkbench
  }

  private var presentation: MenuBarStatusPresentation {
    MenuBarStatusPresentation(
      profile: status.activeProfile,
      report: status.repositoryReport,
      entries: status.activeProfileReleaseLedger.entries
    )
  }

  private var hasConfiguredRepository: Bool {
    !status.activeProfile.localRepositoryRootPath.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
  }

  var body: some View {
    Group {
      if shell.isQuickHideActive {
        VStack(alignment: .leading, spacing: 12) {
          Label("快速隐藏已开启", systemImage: "eye.slash")
          Button("打开主窗口", action: openWorkbench)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
      } else {
        readyContent
      }
    }
  }

  private var readyContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("速记", systemImage: "square.and.pencil")
          .font(.headline)
        Spacer()
        Text(status.activeProfile.name)
          .lineLimit(1)
          .foregroundStyle(.secondary)
      }

      TextEditor(text: $capture.text)
        .accessibilityLabel("速记内容")
        .focused($isCaptureFocused)
        .frame(height: 108)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

      HStack {
        Button("保存速记") {
          Task { await capture.save(using: store.knowledge) }
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!capture.canSave)
        Spacer()
        if capture.isSaving {
          ProgressView()
            .controlSize(.small)
        }
      }

      if let feedback = capture.feedback {
        Text(feedback)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("menu-bar-capture-feedback")
      }

      Divider()

      statusRow("Git 工作区", value: presentation.repositorySummary)
      if let scannedAt = presentation.repositoryScannedAt {
        Text("上次扫描：\(scannedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      statusRow("最近部署", value: presentation.deploymentSummary)
      if let checkedAt = presentation.deploymentCheckedAt {
        Text("上次检查：\(checkedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button("刷新 Git") {
          Task { await refreshRepository() }
        }
        .disabled(isRefreshing || !hasConfiguredRepository)
        Spacer()
        Button("打开主窗口", action: openWorkbench)
      }
    }
    .padding(16)
    .frame(width: 320)
    .onAppear { isCaptureFocused = true }
    .task(id: status.activeProfile.id) {
      await refreshRepository()
    }
  }

  private func statusRow(_ title: LocalizedStringKey, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value)
        .lineLimit(1)
    }
  }

  private func refreshRepository() async {
    guard !isRefreshing, hasConfiguredRepository else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    await store.refreshRepositoryReportAsync()
  }
}
