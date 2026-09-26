import Foundation
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

/// A read-only document surface for a separately opened reference window.
/// Its identity is the supplied document ID; it never uses or changes the
/// library's global selection.
struct KnowledgePopOutWindowView: View {
  let store: WorkbenchStore
  @ObservedObject var knowledge: KnowledgeStore
  let documentID: UUID

  @ObservedObject private var rootPresentation: WorkbenchRootPresentationFeatureFacade

  @State private var presentation: Presentation = .loading
  @State private var readerBlocks: [KnowledgeDocumentBlock] = []
  @State private var originalFileURL: URL?
  @State private var retryID = UUID()

  init(store: WorkbenchStore, knowledge: KnowledgeStore, documentID: UUID) {
    self.store = store
    self.knowledge = knowledge
    self.documentID = documentID
    _rootPresentation = ObservedObject(wrappedValue: store.rootPresentation)
  }

  var body: some View {
    Group {
      switch presentation {
      case .loading:
        ProgressView("正在读取参考资料…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .document(let document, let text):
        documentView(document: document, text: text)

      case .missing:
        unavailableView(
          title: String(localized: "资料已删除"),
          message: String(localized: "这份参考资料已不在资料库中。"),
          systemImage: "trash"
        )

      case .archived(let title):
        unavailableView(
          title: String(localized: "资料已归档"),
          message: String(
            format: String(localized: "“%@”已归档，无法继续作为独立参考资料显示。"),
            title
          ),
          systemImage: "archivebox"
        )

      case .failure(let message):
        VStack(alignment: .leading, spacing: 12) {
          Label("参考资料读取失败", systemImage: "exclamationmark.triangle")
            .font(.headline)
            .foregroundStyle(.red)
          Text(message)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Button("重新读取") {
            retryID = UUID()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(32)
      }
    }
    .frame(minWidth: 420, minHeight: 360)
    .navigationTitle(windowTitle)
    .disabled(rootPresentation.isQuickHideActive)
    .overlay {
      if rootPresentation.isQuickHideActive {
        QuickHideOverlay(store: store)
      }
    }
    .task(id: taskID) {
      await loadPresentation(for: taskID)
    }
  }

  @ViewBuilder
  private func documentView(document: KnowledgeDocument, text: String) -> some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Label(document.kind.localizedDisplayName, systemImage: document.kind.systemImage)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(document.title)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        if !document.sourceName.isEmpty {
          Text(document.sourceName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)

      Divider()

      ScrollView {
        if document.kind == .image {
          KnowledgeImageDocumentView(
            imageURL: originalFileURL,
            title: document.title,
            sourceName: document.sourceName,
            ocrText: text,
            highlightedAnchor: nil
          )
          .padding(24)
        } else if readerBlocks.isEmpty {
          unavailableView(
            title: String(localized: "没有可显示正文"),
            message: String(localized: "资料已保存，但没有可供阅读的正文。"),
            systemImage: "doc.text.magnifyingglass"
          )
          .padding(32)
        } else {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(readerBlocks) { block in
              blockView(block)
            }
          }
          .textSelection(.enabled)
          .frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(24)
        }
      }
      .accessibilityIdentifier("knowledge-pop-out-reader")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-pop-out-window")
  }

  @ViewBuilder
  private func blockView(_ block: KnowledgeDocumentBlock) -> some View {
    switch block.kind {
    case .heading(let level):
      markdownText(block.text)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 8 : 3)
        .accessibilityHeading(headingLevel(level))

    case .paragraph:
      markdownText(block.text)
        .font(.body)
        .lineSpacing(5)

    case .quote:
      markdownText(block.text)
        .font(.body)
        .foregroundStyle(.secondary)
        .lineSpacing(5)
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.accentColor.opacity(0.5))
            .frame(width: 2)
        }

    case .unorderedListItem:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•")
          .foregroundStyle(.secondary)
        markdownText(block.text)
          .font(.body)
          .lineSpacing(5)
      }

    case .orderedListItem(let number):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: number.map { "\($0)." } ?? "•")
          .foregroundStyle(.secondary)
          .frame(minWidth: 20, alignment: .trailing)
        markdownText(block.text)
          .font(.body)
          .lineSpacing(5)
      }

    case .code(let language):
      VStack(alignment: .leading, spacing: 6) {
        if let language, !language.isEmpty {
          Text(language.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(block.text)
          .font(.body.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

    case .locator:
      Label(block.text, systemImage: "mappin.and.ellipse")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

    case .separator:
      Divider()
    }
  }

  private func markdownText(_ source: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let text =
      (try? AttributedString(markdown: source, options: options))
      ?? AttributedString(source)
    return Text(text)
  }

  private func unavailableView(
    title: String,
    message: String,
    systemImage: String
  ) -> some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }

  private var taskID: TaskID {
    let document = knowledge.documents.first(where: { $0.id == documentID })
    return TaskID(
      documentID: documentID,
      revisionID: document?.currentRevisionID,
      updatedAt: document?.updatedAt,
      isArchived: document?.isArchived,
      retryID: retryID
    )
  }

  private var windowTitle: String {
    guard !rootPresentation.isQuickHideActive else {
      return String(localized: "独立参考资料")
    }
    if case .document(let document, _) = presentation {
      return document.title
    }
    return String(localized: "独立参考资料")
  }

  @MainActor
  private func loadPresentation(for request: TaskID) async {
    presentation = .loading
    readerBlocks = []
    originalFileURL = nil

    do {
      guard let snapshot = try await knowledge.referenceDocumentSnapshot(documentID: documentID)
      else {
        guard !Task.isCancelled, taskID == request else { return }
        presentation = .missing
        return
      }
      let document = snapshot.document
      guard !document.isArchived else {
        guard !Task.isCancelled, taskID == request else { return }
        presentation = .archived(title: document.title)
        return
      }

      let parsedBlocks = await parseBlocks(
        from: snapshot.normalizedText,
        documentKind: document.kind
      )

      guard !Task.isCancelled, taskID == request else { return }
      readerBlocks = parsedBlocks
      originalFileURL = snapshot.originalFileURL
      presentation = .document(document, text: snapshot.normalizedText)
    } catch {
      guard !Task.isCancelled, taskID == request else { return }
      presentation = .failure(error.localizedDescription)
    }
  }

  private func parseBlocks(
    from text: String,
    documentKind: KnowledgeDocumentKind
  ) async -> [KnowledgeDocumentBlock] {
    guard documentKind != .image, !text.isEmpty else { return [] }
    let parsingTask = Task.detached(priority: .userInitiated) {
      KnowledgeDocumentBlockParser().blocks(in: text)
    }
    return await withTaskCancellationHandler {
      await parsingTask.value
    } onCancel: {
      parsingTask.cancel()
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title.weight(.semibold)
    case 2: .title2.weight(.semibold)
    case 3: .title3.weight(.semibold)
    default: .headline
    }
  }

  private func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
    switch level {
    case 1: .h1
    case 2: .h2
    case 3: .h3
    case 4: .h4
    case 5: .h5
    default: .h6
    }
  }
}

extension KnowledgePopOutWindowView {
  fileprivate struct TaskID: Hashable {
    let documentID: UUID
    let revisionID: UUID?
    let updatedAt: Date?
    let isArchived: Bool?
    let retryID: UUID
  }

  fileprivate enum Presentation {
    case loading
    case document(KnowledgeDocument, text: String)
    case missing
    case archived(title: String)
    case failure(String)
  }
}
