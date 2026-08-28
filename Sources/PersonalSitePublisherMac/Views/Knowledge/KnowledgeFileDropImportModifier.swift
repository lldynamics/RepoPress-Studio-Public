import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeFileDropImportRequest: Identifiable, Hashable {
  let id: UUID
  let sourceURLs: [URL]
  let importDestination: KnowledgeImportDestination

  init(
    id: UUID = UUID(),
    sourceURLs: [URL],
    importDestination: KnowledgeImportDestination
  ) {
    self.id = id
    self.sourceURLs = sourceURLs
    self.importDestination = importDestination
  }

  static func make(
    from urls: [URL],
    importDestination: KnowledgeImportDestination
  ) -> Self? {
    var seenPaths = Set<String>()
    let sourceURLs = urls.compactMap { url -> URL? in
      guard url.isFileURL else { return nil }
      let standardizedURL = url.standardizedFileURL
      return seenPaths.insert(standardizedURL.path).inserted ? standardizedURL : nil
    }
    guard !sourceURLs.isEmpty else { return nil }

    return Self(
      sourceURLs: sourceURLs,
      importDestination: importDestination
    )
  }
}

struct KnowledgeFileDropImportModifier: ViewModifier {
  @ObservedObject var knowledge: KnowledgeStore
  let isEnabled: Bool

  @State private var isDropTargeted = false
  @State private var pendingImport: KnowledgeFileDropImportRequest?

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .dropDestination(for: URL.self) { urls, _ in
        acceptDrop(urls)
      } isTargeted: { isTargeted in
        isDropTargeted = isEnabled && isTargeted
      }
      .overlay {
        if isEnabled && isDropTargeted {
          dropOverlay
            .allowsHitTesting(false)
        }
      }
      .sheet(item: $pendingImport) { request in
        KnowledgeImportAssistantView(
          knowledge: knowledge,
          initialSourceURLs: request.sourceURLs,
          importDestination: request.importDestination
        )
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { isDropTargeted = false }
      }
  }

  private var dropOverlay: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .overlay(Color.black.opacity(0.20))

      VStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(Color.accentColor.opacity(0.18))
            .frame(width: 76, height: 76)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 14)

          Image(systemName: "square.and.arrow.down.on.square.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }

        VStack(spacing: 6) {
          Text(String(localized: "释放以生成导入预览"))
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)

          Text(destinationMessage)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

          HStack(spacing: 10) {
            Label("Markdown", systemImage: "doc.text")
            Label("图片", systemImage: "photo")
            Label("PDF", systemImage: "doc.richtext")
            Label("EPUB", systemImage: "book")
          }
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        }
      }
      .padding(.horizontal, 36)
      .padding(.vertical, 28)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(
            Color.accentColor,
            style: StrokeStyle(lineWidth: 2, dash: [10, 6])
          )
          .shadow(color: Color.accentColor.opacity(0.30), radius: 6)
      }
      .shadow(color: Color.black.opacity(0.20), radius: 20, y: 8)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("释放以生成导入预览"))
    .accessibilityValue(destinationMessage)
  }

  private var destinationMessage: String {
    switch knowledge.folderScope {
    case .folder(let folderID):
      let folderName = knowledge.folder(id: folderID)?.name ?? String(localized: "资料文件夹")
      return String(localized: "将先生成预览，确认后保存到“\(folderName)”。")
    case .unfiled:
      return String(localized: "将先生成预览，确认后保存到“未分类”。")
    case .all, .smartCollection, .savedCollection:
      return String(localized: "将先生成预览，确认后保存到本机资料库。")
    }
  }

  @discardableResult
  private func acceptDrop(_ urls: [URL]) -> Bool {
    guard isEnabled else { return false }
    guard
      let request = KnowledgeFileDropImportRequest.make(
        from: urls,
        importDestination: currentImportDestination
      )
    else {
      return false
    }

    pendingImport = request
    isDropTargeted = false
    return true
  }

  private var currentImportDestination: KnowledgeImportDestination {
    switch knowledge.folderScope {
    case .folder(let folderID): .folder(folderID)
    case .unfiled: .unfiled
    case .all, .smartCollection, .savedCollection: .preserveExisting
    }
  }
}

extension View {
  func knowledgeFileDropImport(
    knowledge: KnowledgeStore,
    isEnabled: Bool
  ) -> some View {
    modifier(KnowledgeFileDropImportModifier(knowledge: knowledge, isEnabled: isEnabled))
  }
}
