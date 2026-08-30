import PublishingWorkbenchCore
import SwiftUI

struct ReaderContextualSelectionBar: View {
  let selectedText: String
  let onExplain: (String) -> Void
  let onTranslate: (String) -> Void
  let onHighlight: (String) -> Void
  let onQuoteToDraft: (String) -> Void
  let onSpeak: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var feedbackText: String? = nil

  var body: some View {
    actionBar
      .overlay {
        feedbackOverlay
          .animation(
            WorkbenchMotion.animation(
              for: .statusChange,
              reduceMotion: accessibilityReduceMotion
            ),
            value: feedbackText
          )
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

  private var actionBar: some View {
    HStack(spacing: 6) {
      Button {
        onExplain(selectedText)
        showFeedback(String(localized: "已发送给 AI 助手"))
      } label: {
        Label(String(localized: "解释"), systemImage: "lightbulb")
      }
      .help(String(localized: "AI 解释专业术语/概念"))

      Divider()
        .frame(height: 14)

      Button {
        onTranslate(selectedText)
        showFeedback(String(localized: "正在翻译…"))
      } label: {
        Label(String(localized: "翻译"), systemImage: "translate")
      }
      .help(String(localized: "AI 翻译选中文本"))

      Divider()
        .frame(height: 14)

      Button {
        onHighlight(selectedText)
        showFeedback(String(localized: "已添加高亮"))
      } label: {
        Label(String(localized: "高亮"), systemImage: "highlighter")
      }
      .help(String(localized: "添加划线与标注笔记"))

      Divider()
        .frame(height: 14)

      Button {
        onQuoteToDraft(selectedText)
        showFeedback(String(localized: "已转引为草稿"))
      } label: {
        Label(String(localized: "转引草稿"), systemImage: "square.and.pencil")
      }
      .help(String(localized: "引用选中文本创建新博客草稿"))

      Divider()
        .frame(height: 14)

      Button {
        onSpeak(selectedText)
      } label: {
        Label(String(localized: "朗读"), systemImage: "speaker.wave.2")
      }
      .help(String(localized: "语音朗读选中内容"))
    }
    .opacity(feedbackText == nil ? 1 : 0)
    .allowsHitTesting(feedbackText == nil)
    .accessibilityHidden(feedbackText != nil)
  }

  @ViewBuilder
  private var feedbackOverlay: some View {
    if let feedbackText {
      Label(feedbackText, systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.success)
        .padding(.horizontal, 4)
        .transition(
          WorkbenchMotion.statusTransition(reduceMotion: accessibilityReduceMotion)
        )
    }
  }

  private func showFeedback(_ message: String) {
    feedbackText = message
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      feedbackText = nil
    }
  }
}
