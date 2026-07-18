import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeFileDropImportModifier: ViewModifier {
  @ObservedObject var knowledge: KnowledgeStore
  let isEnabled: Bool

  @State private var isDropTargeted = false
  @State private var droppedSourceURLs: [URL] = []
  @State private var importDestination = KnowledgeImportDestination.preserveExisting
  @State private var isImportPresented = false

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
      .sheet(isPresented: $isImportPresented) {
        KnowledgeImportAssistantView(
          knowledge: knowledge,
          initialSourceURLs: droppedSourceURLs,
          importDestination: importDestination
        )
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { isDropTargeted = false }
      }
  }

  private var dropOverlay: some View {
    ZStack {
      Color.black.opacity(0.12)

      VStack(spacing: 10) {
        Image(systemName: "tray.and.arrow.down.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.tint)
        Text(String(localized: "释放以导入资料"))
          .font(.title3.weight(.semibold))
        Text(destinationMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 30)
      .padding(.vertical, 24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
      }
      .shadow(radius: 14, y: 6)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("释放以导入资料"))
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
    var seenPaths = Set<String>()
    let fileURLs = urls.compactMap { url -> URL? in
      guard url.isFileURL else { return nil }
      let standardizedURL = url.standardizedFileURL
      return seenPaths.insert(standardizedURL.path).inserted ? standardizedURL : nil
    }
    guard !fileURLs.isEmpty else { return false }

    droppedSourceURLs = fileURLs
    importDestination = currentImportDestination
    isDropTargeted = false
    isImportPresented = true
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
