import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryHTMLSourceInspectorView: View {
  let store: WorkbenchStore
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  @ObservedObject var session: RepositoryHTMLSourceSession

  init(store: WorkbenchStore, session: RepositoryHTMLSourceSession) {
    self.store = store
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    _session = ObservedObject(wrappedValue: session)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("HTML 源码 Inspector")
            .font(.headline)
          Text("文件格式、诊断与 Git 差异")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(14)

      Divider()

      if let document = session.activeDocument {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            identityCard(document)
            formatCard(document)
            diagnosticsCard
            gitCard(document)
            actionsCard(document)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        EmptyStateView(
          title: "没有打开源码文件",
          message: "从资料库的“源码”阶段选择 HTML 文件后，这里会显示文件信息与诊断。",
          systemImage: "sidebar.right",
          density: .compactPane
        )
      }
    }
    .background(.bar)
    .accessibilityIdentifier("html-source-inspector")
    .accessibilityLabel("HTML 源码 Inspector")
  }

  private func identityCard(_ document: RepositoryTextDocument) -> some View {
    inspectorCard(title: "当前文件", systemImage: "doc.text") {
      Text(URL(fileURLWithPath: document.repositoryPath).lastPathComponent)
        .font(.callout.weight(.semibold))
        .lineLimit(2)
        .truncationMode(.middle)
      Text(document.repositoryPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .truncationMode(.middle)
        .help(document.repositoryPath)
        .textSelection(.enabled)
      Label(
        session.hasUnsavedChanges ? "有未保存更改" : "磁盘内容已同步",
        systemImage: session.hasUnsavedChanges ? "circle.fill" : "checkmark.circle.fill"
      )
      .font(.caption)
      .foregroundStyle(session.hasUnsavedChanges ? WorkbenchTheme.warning : WorkbenchTheme.success)
    }
  }

  private func formatCard(_ document: RepositoryTextDocument) -> some View {
    inspectorCard(title: "文件格式", systemImage: "textformat") {
      InspectorStatRow(title: "模板档位", value: document.dialect.localizedDisplayName, systemImage: "curlybraces")
      InspectorStatRow(title: "编码", value: document.encoding.localizedDisplayName, systemImage: "character.cursor.ibeam")
      InspectorStatRow(
        title: "换行符",
        value: document.hasMixedLineEndings
          ? String(localized: "混合（只读保护）")
          : document.lineEnding.localizedDisplayName,
        systemImage: "return"
      )
      InspectorStatRow(title: "行数", value: "\(lineCount(document.text))", systemImage: "list.number")
      InspectorStatRow(title: "文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(document.byteSize), countStyle: .file), systemImage: "doc")
      if let date = document.modificationDate {
        InspectorStatRow(title: "磁盘修改", value: date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
      }
    }
  }

  private var diagnosticsCard: some View {
    inspectorCard(title: "源码诊断", systemImage: "checkmark.shield") {
      if session.diagnostics.isEmpty {
        Label("没有发现标签结构问题", systemImage: "checkmark.circle")
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.success)
      } else {
        ForEach(session.diagnostics.prefix(12)) { diagnostic in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
              Text("第 \(diagnostic.line) 行 · \(diagnostic.title)")
                .font(.caption.weight(.semibold))
            }
            .foregroundStyle(diagnostic.severity == .error ? WorkbenchTheme.risk : WorkbenchTheme.warning)
            Text(diagnostic.message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if diagnostic.id != session.diagnostics.prefix(12).last?.id {
            Divider()
          }
        }
      }
    }
  }

  private func gitCard(_ document: RepositoryTextDocument) -> some View {
    inspectorCard(title: "Git 状态", systemImage: "arrow.left.arrow.right") {
      if let changedFile = changedFile(for: document) {
        HStack {
          Text(changedFile.kind.localizedDisplayName)
            .font(.caption.weight(.semibold))
          Spacer()
          Text(changedFile.status)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        if let lineDiff = changedFile.lineDiff {
          Text(lineDiff)
            .font(.caption.monospaced())
            .lineLimit(12)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
        }
      } else {
      Text(statusState.repositoryReport == nil ? "扫描仓库后显示 Git 状态。" : "当前扫描中没有这个文件的 Git 变更。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func actionsCard(_ document: RepositoryTextDocument) -> some View {
    inspectorCard(title: "文件操作", systemImage: "hammer") {
      Button {
        save()
      } label: {
        Label("保存源文件", systemImage: "square.and.arrow.down")
      }
      .workbenchProminentActionStyle()
      .disabled(!canSave)
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        Task { await session.reload(profile: statusState.activeProfile) }
      } label: {
        Label("重新载入磁盘版本", systemImage: "arrow.clockwise")
      }
      .disabled(session.hasUnsavedChanges)
      .help(session.hasUnsavedChanges ? "请先在编辑区确认是否放弃未保存更改。" : "重新读取磁盘内容")

      Button {
        openInSystemBrowser(document)
      } label: {
        Label("用系统浏览器预览", systemImage: "safari")
      }
      .disabled(document.dialect != .html || session.hasUnsavedChanges)
      .help(document.dialect == .html ? "纯 HTML 可直接系统预览；请先保存更改。" : "模板文件请使用本地站点预览。")
    }
  }

  private var canSave: Bool {
    session.hasUnsavedChanges
      && !session.isSaving
      && session.isDocumentFromCurrentRepository(statusState.activeProfile)
  }

  private func save() {
    guard canSave else { return }
    Task {
      if await session.save(profile: statusState.activeProfile) {
        await store.repository.scanAsync()
        await session.refreshFiles(profile: statusState.activeProfile)
      }
    }
  }

  private func openInSystemBrowser(_ document: RepositoryTextDocument) {
    guard document.dialect == .html, !session.hasUnsavedChanges else { return }
    do {
      _ = try HTMLSourceEditingService().withResolvedFileURL(
        profile: statusState.activeProfile,
        repositoryPath: document.repositoryPath
      ) { url in
        NSWorkspace.shared.open(url)
      }
    } catch {
      EditorAccessibilityAnnouncementCenter.announce(error.localizedDescription, priority: .high)
    }
  }

  private func changedFile(for document: RepositoryTextDocument) -> RepositoryChangedFile? {
    statusState.repositoryReport?.changedFiles.first {
      $0.displayPath == document.repositoryPath
    }
  }

  private func lineCount(_ text: String) -> Int {
    max(1, text.components(separatedBy: "\n").count)
  }

  private func inspectorCard<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
