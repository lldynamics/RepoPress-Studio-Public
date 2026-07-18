import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeImportAssistantView: View {
  @ObservedObject var knowledge: KnowledgeStore
  let initialSourceURLs: [URL]
  let importDestination: KnowledgeImportDestination
  @Environment(\.dismiss) private var dismiss
  @State private var webURLText = ""
  @State private var preview: KnowledgeImportPreview?
  @State private var performsPDFOCR = true
  @State private var isAnalyzing = false
  @State private var isCommitting = false
  @State private var statusMessage: StatusMessage?
  @State private var analysisTask: Task<Void, Never>?
  @State private var isFileDropTargeted = false
  @State private var didAnalyzeInitialSources = false

  init(
    knowledge: KnowledgeStore,
    initialSourceURLs: [URL] = [],
    importDestination: KnowledgeImportDestination = .preserveExisting
  ) {
    self.knowledge = knowledge
    self.initialSourceURLs = initialSourceURLs
    self.importDestination = importDestination
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          sourceSection
          if let preview {
            previewSummary(preview)
            candidateList(preview)
            warningList(preview)
          } else {
            ContentUnavailableView(
              String(localized: "选择阅读资料"),
              systemImage: "books.vertical",
              description: Text("先提取并预览，再确认保存。预览阶段不会把内容加入 AI 检索。")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
          }
        }
        .padding(20)
      }

      Divider()
      footer
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 580, idealHeight: 700)
    .onAppear {
      guard !didAnalyzeInitialSources, !initialSourceURLs.isEmpty else { return }
      didAnalyzeInitialSources = true
      analyzeFileSources(initialSourceURLs)
    }
    .onDisappear {
      analysisTask?.cancel()
      analysisTask = nil
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("导入资料")
          .font(.title2.weight(.semibold))
        Text("把 EPUB 书籍、文章、网页或 PDF 保存到本机资料库并建立检索索引。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  private var sourceSection: some View {
    GroupBox(String(localized: "1. 选择来源")) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: isFileDropTargeted ? "tray.and.arrow.down.fill" : "arrow.down.doc")
            .font(.title3)
            .foregroundStyle(isFileDropTargeted ? Color.accentColor : Color.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(
              isFileDropTargeted
                ? String(localized: "释放以生成导入预览")
                : String(localized: "可直接拖入文件或文件夹")
            )
              .font(.callout.weight(.medium))
            Text(String(localized: "支持一次拖入多项；会先分析、去重，再由你确认保存。"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          isFileDropTargeted
            ? AnyShapeStyle(Color.accentColor.opacity(0.12))
            : WorkbenchBackgroundStyle.subtle,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .overlay {
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .stroke(
              isFileDropTargeted ? Color.accentColor : Color.secondary.opacity(0.22),
              style: StrokeStyle(lineWidth: isFileDropTargeted ? 2 : 1, dash: [6, 4])
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
          handleDroppedURLs(urls)
        } isTargeted: { isTargeted in
          isFileDropTargeted = isTargeted
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("拖放资料文件或文件夹"))
        .accessibilityHint(Text("释放后生成导入预览，不会立即保存"))

        Divider()

        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("本地文件或文件夹")
              .font(.callout.weight(.medium))
            Text("支持 EPUB、Markdown、TXT、HTML、PDF；文件夹会批量分析。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            chooseFileSource()
          } label: {
            Label(String(localized: "选择文件…"), systemImage: "folder.badge.plus")
          }
          .disabled(isAnalyzing || isCommitting)
        }

        Divider()

        Toggle(isOn: $performsPDFOCR) {
          VStack(alignment: .leading, spacing: 3) {
            Text("识别扫描版 PDF")
              .font(.callout.weight(.medium))
            Text("仅对没有文字层的页面使用本机 Vision OCR；一次最多处理 200 页。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(isAnalyzing || isCommitting)

        Divider()

        HStack(alignment: .center, spacing: 10) {
          TextField("https://example.com/article", text: $webURLText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("网页地址")
          Button {
            analyzeWebURL()
          } label: {
            Label("读取网页", systemImage: "globe")
          }
          .disabled(webURL == nil || isAnalyzing || isCommitting)
        }

        if isAnalyzing {
          ProgressView("正在提取正文并检查重复内容…")
            .controlSize(.small)
        }
        if let statusMessage {
          Text(statusMessage.text)
            .font(.caption)
            .foregroundStyle(statusMessage.color)
            .textSelection(.enabled)
        }
      }
      .padding(.top, 4)
    }
  }

  private func previewSummary(_ preview: KnowledgeImportPreview) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("2. 导入概览")
        .font(.headline)
      HStack(spacing: 12) {
        metric(String(localized: "可导入"), value: "\(preview.importableCount)", image: "tray.and.arrow.down")
        metric(String(localized: "新增"), value: "\(preview.newCount)", image: "plus.circle")
        metric(String(localized: "更新"), value: "\(preview.updateCount)", image: "arrow.triangle.2.circlepath")
        metric(String(localized: "重复"), value: "\(preview.duplicateCount)", image: "doc.on.doc")
      }
      Text("来源：\(preview.sourceName) · 只会保存到本机资料库，不会生成发布草稿。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func metric(_ title: String, value: String, image: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: image)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(value)
          .font(.headline)
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func candidateList(_ preview: KnowledgeImportPreview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("3. 内容预览")
        .font(.headline)
      ForEach(preview.candidates.prefix(50)) { candidate in
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: candidate.kind.systemImage)
            .frame(width: 18)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text(candidate.title)
              .font(.callout.weight(.medium))
              .workbenchTruncatedIdentity(candidate.title)
            Text(candidateDetail(candidate))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer()
          Text(candidate.disposition.localizedDisplayNameKey)
            .font(.caption.weight(.medium))
            .foregroundStyle(candidate.disposition == .duplicate ? Color.secondary : Color.accentColor)
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }
      if preview.candidates.count > 50 {
        Text("另有 \(preview.candidates.count - 50) 条资料将在确认后处理。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func warningList(_ preview: KnowledgeImportPreview) -> some View {
    let warnings = preview.warnings + preview.candidates.flatMap(\.warnings)
    if !warnings.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("注意")
          .font(.headline)
        ForEach(Array(warnings.prefix(12).enumerated()), id: \.offset) { _, warning in
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("取消") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(isCommitting)

      Spacer()

      Text("AI 只会在你启用资料库检索时读取命中的少量片段。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let preview {
        Button {
          commit(preview)
        } label: {
          if isCommitting {
            Label(String(localized: "正在建立索引"), systemImage: "hourglass")
          } else {
            Label(
              String(
                format: String(localized: "确认导入 %@ 条"),
                "\(preview.importableCount)"
              ),
              systemImage: "tray.and.arrow.down.fill"
            )
          }
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(isCommitting || isAnalyzing || preview.importableCount == 0)
      }
    }
    .padding(16)
  }

  private var webURL: URL? {
    guard let url = URL(string: webURLText.trimmedForPublishing),
          url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  private func chooseFileSource() {
    let urls = KnowledgeSelectionPanel.chooseSources()
    guard !urls.isEmpty else { return }
    analyzeFileSources(urls)
  }

  @discardableResult
  private func handleDroppedURLs(_ urls: [URL]) -> Bool {
    let fileURLs = normalizedFileURLs(urls)
    guard !fileURLs.isEmpty, !isAnalyzing, !isCommitting else { return false }
    isFileDropTargeted = false
    analyzeFileSources(fileURLs)
    return true
  }

  private func analyzeFileSources(_ urls: [URL]) {
    let fileURLs = normalizedFileURLs(urls)
    guard !fileURLs.isEmpty else {
      statusMessage = .failure(String(localized: "失败：请拖入本机文件或文件夹。"))
      return
    }
    analyze {
      let accessedURLs = fileURLs.map { url in
        (url, url.startAccessingSecurityScopedResource())
      }
      defer {
        for (url, didStartAccessing) in accessedURLs where didStartAccessing {
          url.stopAccessingSecurityScopedResource()
        }
      }
      return try await knowledge.makeImportPreview(
        sourceURLs: fileURLs,
        options: KnowledgeImportOptions(
          performsPDFOCR: performsPDFOCR,
          maximumPDFOCRPageCount: 200
        )
      )
    }
  }

  private func normalizedFileURLs(_ urls: [URL]) -> [URL] {
    var seenPaths = Set<String>()
    return urls.compactMap { url in
      guard url.isFileURL else { return nil }
      let standardizedURL = url.standardizedFileURL
      return seenPaths.insert(standardizedURL.path).inserted ? standardizedURL : nil
    }
  }

  private func analyzeWebURL() {
    guard let webURL else { return }
    analyze {
      try await knowledge.makeWebImportPreview(url: webURL)
    }
  }

  private func analyze(
    _ operation: @escaping @MainActor () async throws -> KnowledgeImportPreview
  ) {
    analysisTask?.cancel()
    isAnalyzing = true
    statusMessage = nil
    analysisTask = Task {
      defer { isAnalyzing = false }
      do {
        preview = try await operation()
        try Task.checkCancellation()
        statusMessage = .success(String(localized: "预览已生成，请检查后确认导入。"))
      } catch is CancellationError {
        return
      } catch {
        preview = nil
        statusMessage = .failure(
          String(
            format: String(localized: "失败：%@"),
            error.localizedDescription
          )
        )
      }
    }
  }

  private func commit(_ preview: KnowledgeImportPreview) {
    isCommitting = true
    statusMessage = nil
    Task {
      defer { isCommitting = false }
      do {
        let result = try await knowledge.commit(preview, destination: importDestination)
        statusMessage = .success(
          String(
            format: String(localized: "导入完成：新增 %@，更新 %@，跳过 %@。"),
            "\(result.insertedCount)",
            "\(result.updatedCount)",
            "\(result.skippedCount)"
          )
        )
        dismiss()
      } catch {
        statusMessage = .failure(
          String(
            format: String(localized: "失败：%@"),
            error.localizedDescription
          )
        )
      }
    }
  }

  private func candidateDetail(_ candidate: KnowledgeImportCandidate) -> String {
    var parts = [candidate.kind.localizedDisplayName]
    if !candidate.authors.isEmpty {
      parts.append(candidate.authors.joined(separator: "、"))
    }
    parts.append(
      String(
        format: String(localized: "%@ 个章节/页面"),
        "\(candidate.sections.count)"
      )
    )
    parts.append(
      String(
        format: String(localized: "%@ 字符"),
        "\(candidate.normalizedText.count)"
      )
    )
    return parts.joined(separator: " · ")
  }

  private enum StatusMessage {
    case success(String)
    case failure(String)

    var text: String {
      switch self {
      case let .success(text), let .failure(text):
        return text
      }
    }

    var color: Color {
      switch self {
      case .success:
        return WorkbenchTheme.success
      case .failure:
        return WorkbenchTheme.risk
      }
    }
  }
}
