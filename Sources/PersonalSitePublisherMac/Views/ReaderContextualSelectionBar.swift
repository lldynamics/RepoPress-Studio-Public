import PublishingWorkbenchCore
import SwiftUI

struct ReaderContextualSelectionBar: View {
  let selectedText: String
  let onExplain: (String) -> Void
  let onTranslate: (String) -> Void
  let onHighlight: (String) -> Void
  let onQuoteToDraft: (String) -> Void
  let onSpeak: (String) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button {
        onExplain(selectedText)
      } label: {
        Label("解释", systemImage: "lightbulb")
      }
      .help("AI 解释专业术语/概念")

      Divider()
        .frame(height: 14)

      Button {
        onTranslate(selectedText)
      } label: {
        Label("翻译", systemImage: "translate")
      }
      .help("AI 翻译选中文本")

      Divider()
        .frame(height: 14)

      Button {
        onHighlight(selectedText)
      } label: {
        Label("高亮", systemImage: "highlighter")
      }
      .help("添加划线与标注笔记")

      Divider()
        .frame(height: 14)

      Button {
        onQuoteToDraft(selectedText)
      } label: {
        Label("转引草稿", systemImage: "square.and.pencil")
      }
      .help("引用选中文本创建新博客草稿")

      Divider()
        .frame(height: 14)

      Button {
        onSpeak(selectedText)
      } label: {
        Label("朗读", systemImage: "speaker.wave.2")
      }
      .help("语音朗读选中内容")
    }
    .font(.caption.weight(.medium))
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .workbenchGlassSurface(
      material: .regularMaterial,
      in: Capsule()
    )
    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
  }
}
