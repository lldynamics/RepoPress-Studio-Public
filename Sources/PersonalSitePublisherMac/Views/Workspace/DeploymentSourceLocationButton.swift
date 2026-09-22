import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct DeploymentSourceContext {
  let profile: SiteProfile
  let shell: WorkbenchShellFeatureFacade

  static func profile(for record: ReleaseRecord, in profiles: [SiteProfile]) -> SiteProfile? {
    guard let profileID = record.siteProfileID else { return nil }
    return profiles.first(where: { $0.id == profileID })
  }
}

struct DeploymentSourceRequest: Identifiable {
  let id = UUID()
  let profile: SiteProfile
  let entry: DeploymentLogEntry

  func isValid(activeProfile: SiteProfile, canUseProtectedWorkbench: Bool) -> Bool {
    canUseProtectedWorkbench && activeProfile == profile
  }
}

struct DeploymentSourceLocationButton: View {
  let entry: DeploymentLogEntry
  private let profile: SiteProfile
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  @State private var request: DeploymentSourceRequest?

  init(entry: DeploymentLogEntry, context: DeploymentSourceContext) {
    self.entry = entry
    profile = context.profile
    _shell = ObservedObject(wrappedValue: context.shell)
  }

  private var isAvailable: Bool {
    shell.canUseProtectedWorkbench && shell.activeProfile == profile
  }

  private var isRequestValid: Bool {
    request?.isValid(
      activeProfile: shell.activeProfile,
      canUseProtectedWorkbench: shell.canUseProtectedWorkbench) ?? false
  }

  var body: some View {
    if entry.filePath != nil {
      Button {
        guard isAvailable else { return }
        request = DeploymentSourceRequest(profile: profile, entry: entry)
      } label: {
        Label("定位到文件", systemImage: "doc.text.magnifyingglass")
      }
      .buttonStyle(.borderless)
      .disabled(!isAvailable)
      .accessibilityIdentifier("deployment-open-source-\(entry.id)")
      .sheet(item: $request) { request in
        if request.isValid(
          activeProfile: shell.activeProfile,
          canUseProtectedWorkbench: shell.canUseProtectedWorkbench)
        {
          DeploymentSourcePreview(profile: request.profile, entry: request.entry)
            .id(request.id)
        }
      }
      .onChange(of: isRequestValid) { _, valid in
        if !valid { request = nil }
      }
    }
  }
}

private struct DeploymentSourcePreview: View {
  let profile: SiteProfile
  let entry: DeploymentLogEntry
  @Environment(\.dismiss) private var dismiss
  @State private var document: DeploymentSourceDocument?
  @State private var didFail = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("部署错误源码").font(.headline)
        Spacer()
        Button("返回部署日志") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("deployment-source-close")
      }
      if let document {
        Text("\(document.repositoryPath) · 第 \(document.lineNumber) 行")
          .font(.callout.monospaced())
          .textSelection(.enabled)
        Text("显示当前本地文件，可能与日志对应的构建版本不同。此预览不会修改文件。")
          .font(.callout)
          .foregroundStyle(.secondary)
        if document.didClampLine {
          Text("日志行号超出当前文件，已定位到最后一行。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        DeploymentSourceTextView(document: document)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if didFail {
        Text("无法读取日志中的文件。请确认它是当前仓库内的文本源码，文件存在且不超过 2 MB；符号链接和仓库外路径不会打开。")
          .accessibilityIdentifier("deployment-source-unavailable")
        Spacer()
      } else {
        ProgressView(String(localized: "正在读取源码…"))
        Spacer()
      }
    }
    .padding(20)
    .frame(minWidth: 640, idealWidth: 780, minHeight: 420, idealHeight: 540)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("deployment-source-preview")
    .task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { try DeploymentSourceFileService().open(profile: profile, entry: entry) }
      }.value
      guard !Task.isCancelled else { return }
      switch result {
      case .success(let value): document = value
      case .failure: didFail = true
      }
    }
  }
}

struct DeploymentSourceTextView: NSViewRepresentable {
  let document: DeploymentSourceDocument

  final class Coordinator {
    var documentID: UUID?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    text.textContainerInset = NSSize(width: 10, height: 10)
    text.autoresizingMask = [.width]
    text.isVerticallyResizable = true
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel(String(localized: "部署源码预览"))
    text.setAccessibilityIdentifier("deployment-source-text")
    scroll.documentView = text
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView,
      context.coordinator.documentID != document.id
    else { return }
    context.coordinator.documentID = document.id
    text.string = document.text
    text.setSelectedRange(document.selectionRange)
    text.scrollRangeToVisible(document.selectionRange)
  }
}
