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
  @State private var performsImageOCR = true
  @State private var isAnalyzing = false
  @State private var isCommitting = false
  @State private var statusMessage: WorkbenchStatePresentation?
  @State private var analysisTask: Task<Void, Never>?
  @State private var analysisGeneration = UUID()
  @State private var isFileDropTargeted = false
  @State private var didAnalyzeInitialSources = false
  @State private var selectedCandidateIDs: Set<UUID> = []
  @State private var showsRemainingCandidates = false
  @State private var showsRemainingWarnings = false

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
            WorkbenchStateView(
              presentation: WorkbenchStatePresentation(
                kind: .empty,
                icon: "books.vertical"
              ),
              detail: "先提取并预览，再确认保存。预览阶段不会修改资料库索引。"
            )
            .frame(maxWidth: .infinity, minHeight: 260)
          }
        }
        .padding(WorkbenchSpacing.page)
      }

      Divider()
      footer
    }
    .workbenchSheetSize(.wide)
    .onAppear {
      guard !didAnalyzeInitialSources, !initialSourceURLs.isEmpty else { return }
      didAnalyzeInitialSources = true
      analyzeFileSources(initialSourceURLs)
    }
    .onDisappear {
      analysisTask?.cancel()
      analysisTask = nil
    }
    .onChange(of: selectedCandidateIDs) { _, _ in
      guard let preview, !isAnalyzing, !isCommitting else { return }
      statusMessage = previewStatusPresentation(for: preview)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("导入资料")
          .font(.title2.weight(.semibold))
        Text("把图片、EPUB 书籍、文章、网页或 PDF 保存到本机资料库并建立检索索引。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(WorkbenchSpacing.page)
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
            : WorkbenchBackgroundStyle.card,
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
            Text("支持 JPEG、PNG、HEIC、EPUB、Markdown、TXT、HTML、PDF；文件夹会批量分析。")
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

        Toggle(isOn: $performsImageOCR) {
          VStack(alignment: .leading, spacing: 3) {
            Text("识别图片中的文字")
              .font(.callout.weight(.medium))
            Text("只在本机使用 Vision OCR；不会上传原图。")
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
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(
              kind: .loading(
                detail: String(localized: "正在提取正文并检查重复内容…")
              )
            ),
            density: .inline,
            actions: WorkbenchStateActions(
              primary: WorkbenchStateAction(
                title: "取消分析",
                systemImage: "xmark",
                role: .cancel,
                action: cancelAnalysis
              )
            )
          )
        }
        if let statusMessage {
          WorkbenchStateView(
            presentation: statusMessage,
            density: .inline
          )
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
      let selectedCandidates = preview.candidates.filter {
        selectedCandidateIDs.contains($0.id)
      }
      let selectedImageCount = selectedCandidates.filter { $0.kind == .image }.count
      let selectedByteCount = selectedCandidates.reduce(into: Int64(0)) { total, candidate in
        total += Int64(candidate.originalData?.count ?? 0)
      }
      if selectedImageCount > 0 {
        let selectedByteText = ByteCountFormatter.string(
          fromByteCount: selectedByteCount,
          countStyle: .file
        )
        Label(
          String(
            format: String(localized: "已选 %lld 张图片 · %@"),
            Int64(selectedImageCount),
            selectedByteText
          ),
          systemImage: "photo.stack"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
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
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func candidateList(_ preview: KnowledgeImportPreview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Text("3. 内容预览")
          .font(.headline)
        Text("已选择 \(selectedCandidateIDs.count)/\(preview.candidates.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("全选") {
          selectedCandidateIDs = Set(preview.candidates.map(\.id))
        }
        .buttonStyle(.link)
        .disabled(
          isCommitting
            || isAnalyzing
            || selectedCandidateIDs.count == preview.candidates.count
        )
        Button("全部取消") {
          selectedCandidateIDs.removeAll()
        }
        .buttonStyle(.link)
        .disabled(isCommitting || isAnalyzing || selectedCandidateIDs.isEmpty)
      }

      ForEach(preview.candidates.prefix(KnowledgeImportSelectionPresentation.initialCandidateLimit)) {
        candidate in
        candidateRow(candidate)
      }
      let remainingCandidates = preview.candidates.dropFirst(
        KnowledgeImportSelectionPresentation.initialCandidateLimit
      )
      if !remainingCandidates.isEmpty {
        DisclosureGroup(isExpanded: $showsRemainingCandidates) {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(remainingCandidates) { candidate in
              candidateRow(candidate)
            }
          }
          .padding(.top, 8)
        } label: {
          Text("查看其余 \(remainingCandidates.count) 条资料")
            .font(.callout.weight(.medium))
        }
        .padding(10)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
        Text("其余资料默认已勾选；展开后可逐项取消，再确认导入。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func candidateRow(_ candidate: KnowledgeImportCandidate) -> some View {
    Toggle(isOn: candidateSelectionBinding(candidate.id)) {
      HStack(alignment: .top, spacing: 12) {
        if candidate.kind == .image, let data = candidate.originalData {
          KnowledgeImageDataThumbnailView(data: data, requestID: candidate.id)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
        } else {
          Image(systemName: candidate.kind.systemImage)
            .frame(width: 18)
            .foregroundStyle(.secondary)
        }
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
    }
    .toggleStyle(.checkbox)
    .disabled(isCommitting || isAnalyzing)
    .padding(10)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityHint(
      selectedCandidateIDs.contains(candidate.id)
        ? String(localized: "取消勾选后不会保存这条资料")
        : String(localized: "勾选后会在确认导入时保存这条资料")
    )
  }

  private func candidateSelectionBinding(_ candidateID: UUID) -> Binding<Bool> {
    Binding(
      get: { selectedCandidateIDs.contains(candidateID) },
      set: { isSelected in
        if isSelected {
          selectedCandidateIDs.insert(candidateID)
        } else {
          selectedCandidateIDs.remove(candidateID)
        }
      }
    )
  }

  @ViewBuilder
  private func warningList(_ preview: KnowledgeImportPreview) -> some View {
    let warnings = preview.warnings
      + preview.candidates
        .filter { selectedCandidateIDs.contains($0.id) }
        .flatMap(\.warnings)
    if !warnings.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("注意")
          .font(.headline)
        ForEach(
          Array(warnings.prefix(KnowledgeImportSelectionPresentation.initialWarningLimit).enumerated()),
          id: \.offset
        ) { _, warning in
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }
        let remainingWarnings = warnings.dropFirst(
          KnowledgeImportSelectionPresentation.initialWarningLimit
        )
        if !remainingWarnings.isEmpty {
          DisclosureGroup(isExpanded: $showsRemainingWarnings) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(remainingWarnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(WorkbenchTheme.warning)
              }
            }
            .padding(.top, 6)
          } label: {
            Text("查看其余 \(remainingWarnings.count) 条提醒")
              .font(.caption.weight(.medium))
          }
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

      Text("只会保存已勾选的内容；搜索索引在本机建立。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let preview {
        let selectedPreview = KnowledgeImportSelectionPresentation.selectedPreview(
          from: preview,
          selectedCandidateIDs: selectedCandidateIDs
        )
        Button {
          commit(selectedPreview)
        } label: {
          if isCommitting {
            Label(String(localized: "正在建立索引"), systemImage: "hourglass")
          } else {
            Label(
              String(
                format: String(localized: "确认导入 %@ 条"),
                "\(selectedPreview.importableCount)"
              ),
              systemImage: "tray.and.arrow.down.fill"
            )
          }
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(isCommitting || isAnalyzing || selectedPreview.importableCount == 0)
      }
    }
    .padding(WorkbenchSpacing.content)
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
      statusMessage = WorkbenchStatePresentation(
        kind: .failure(reason: String(localized: "请拖入本机文件或文件夹。"))
      )
      return
    }
    analyze {
      return try await knowledge.makeImportPreview(
        sourceURLs: fileURLs,
        options: KnowledgeImportOptions(
          performsPDFOCR: performsPDFOCR,
          performsImageOCR: performsImageOCR,
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

  private func cancelAnalysis() {
    guard isAnalyzing else { return }
    analysisTask?.cancel()
    statusMessage = nil
  }

  private func analyze(
    _ operation: @escaping @MainActor () async throws -> KnowledgeImportPreview
  ) {
    analysisTask?.cancel()
    let generation = UUID()
    analysisGeneration = generation
    isAnalyzing = true
    statusMessage = nil
    analysisTask = Task {
      defer {
        if analysisGeneration == generation {
          isAnalyzing = false
          analysisTask = nil
        }
      }
      do {
        let generatedPreview = try await operation()
        try Task.checkCancellation()
        guard analysisGeneration == generation else { return }
        preview = generatedPreview
        selectedCandidateIDs = Set(generatedPreview.candidates.map(\.id))
        showsRemainingCandidates = false
        showsRemainingWarnings = false
        statusMessage = previewStatusPresentation(for: generatedPreview)
      } catch is CancellationError {
        return
      } catch {
        guard analysisGeneration == generation else { return }
        preview = nil
        selectedCandidateIDs.removeAll()
        showsRemainingCandidates = false
        showsRemainingWarnings = false
        statusMessage = WorkbenchStatePresentation(
          kind: .failure(reason: error.localizedDescription)
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
        statusMessage = WorkbenchStatePresentation(
          kind: .success(
            detail: String(
              format: String(localized: "导入完成：新增 %@，更新 %@，跳过 %@。"),
              "\(result.insertedCount)",
              "\(result.updatedCount)",
              "\(result.skippedCount)"
            )
          )
        )
        dismiss()
      } catch {
        statusMessage = WorkbenchStatePresentation(
          kind: .failure(reason: error.localizedDescription)
        )
      }
    }
  }

  private func previewStatusPresentation(
    for preview: KnowledgeImportPreview
  ) -> WorkbenchStatePresentation {
    let selectedPreview = KnowledgeImportSelectionPresentation.selectedPreview(
      from: preview,
      selectedCandidateIDs: selectedCandidateIDs
    )
    guard selectedPreview.importableCount > 0 else {
      return WorkbenchStatePresentation(
        kind: .unavailable(
          reason: String(localized: "当前没有可导入的已选资料。")
        )
      )
    }
    return WorkbenchStatePresentation(
      kind: .awaitingConfirmation(
        detail: String(localized: "预览已生成，请检查后确认导入。")
      )
    )
  }

  private func candidateDetail(_ candidate: KnowledgeImportCandidate) -> String {
    var parts = [candidate.kind.localizedDisplayName]
    if let image = candidate.imageMetadata {
      parts.append("\(image.pixelWidth) × \(image.pixelHeight)")
      parts.append("识别 \(image.recognizedRegionCount) 个区域")
      parts.append(image.wasPrivacySanitized ? "已通过隐私清理" : "未执行隐私清理")
      return parts.joined(separator: " · ")
    }
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

}

enum KnowledgeImportSelectionPresentation {
  static let initialCandidateLimit = 50
  static let initialWarningLimit = 12

  static func selectedPreview(
    from preview: KnowledgeImportPreview,
    selectedCandidateIDs: Set<UUID>
  ) -> KnowledgeImportPreview {
    KnowledgeImportPreview(
      sourceName: preview.sourceName,
      candidates: preview.candidates.filter { selectedCandidateIDs.contains($0.id) },
      warnings: preview.warnings
    )
  }
}
