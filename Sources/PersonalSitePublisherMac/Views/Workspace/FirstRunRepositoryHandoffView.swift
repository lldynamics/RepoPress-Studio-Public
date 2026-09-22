import SwiftUI

enum FirstRunRepositoryHandoffState: Equatable {
  case preparing
  case ready(insertedCount: Int, availableCount: Int, latestDraftID: UUID?, hasWarnings: Bool)
  case failed
  case cancelled
}

/// Remains in the presenting window. Finishing background work never navigates;
/// only an explicit action may open or create an article.
struct FirstRunRepositoryHandoffView: View {
  let prepare: @MainActor (_ isRetry: Bool) async -> FirstRunRepositoryHandoffState
  let openDraft: (UUID) -> Bool
  let createDraft: () -> Bool
  let inspectRepository: () -> Void
  let close: () -> Void
  @State private var state: FirstRunRepositoryHandoffState = .preparing
  @State private var attemptNumber = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("开始写作", systemImage: "square.and.pencil")
        .font(.title2.weight(.semibold))

      switch state {
      case .preparing:
        ProgressView(String(localized: "正在读取站点并整理文章…"))
          .accessibilityIdentifier("first-run-writing-preparing")
        Text("设置已保存。整理完成后，你可以选择打开文章或新建文章。")
          .foregroundStyle(.secondary)
      case .ready(let insertedCount, let availableCount, let latestDraftID, let hasWarnings):
        Text("本次加入 \(insertedCount) 篇文章，当前站点共有 \(availableCount) 篇可用文章。")
          .accessibilityIdentifier("first-run-writing-summary")
        if hasWarnings {
          Text("部分文件未能导入，可在站点检查中查看详情；已加入的文章可以继续编辑。")
            .foregroundStyle(.secondary)
        }
        HStack {
          if let latestDraftID {
            Button("打开最近文章") {
              if !openDraft(latestDraftID) { state = .cancelled }
            }
            .workbenchProminentActionStyle()
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("first-run-open-recent-article")
          }
          Button(availableCount == 0 ? "新建第一篇文章" : "新建文章") {
            if !createDraft() { state = .cancelled }
          }
          .accessibilityIdentifier("first-run-create-article")
        }
      case .failed:
        Text("文章准备未完成。请检查仓库访问权限、内容目录和文件读取问题后重试。")
          .accessibilityIdentifier("first-run-writing-failed")
        retryButton
      case .cancelled:
        Text("站点配置已变化，或文章准备已中断。请核对当前站点后重试。")
          .accessibilityIdentifier("first-run-writing-cancelled")
        retryButton
      }

      Divider()
      HStack {
        Button("关闭", action: close)
          .keyboardShortcut(.cancelAction)
        Spacer()
        if state != .preparing {
          Button("查看站点检查", action: inspectRepository)
            .accessibilityIdentifier("first-run-inspect-repository")
        }
      }
    }
    .padding(24)
    .frame(width: 520, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("first-run-writing-handoff")
    .task(id: attemptNumber) {
      state = .preparing
      let result = await prepare(attemptNumber > 0)
      guard !Task.isCancelled else { return }
      state = result
    }
  }

  private var retryButton: some View {
    Button("重试") { attemptNumber += 1 }
      .accessibilityIdentifier("first-run-retry-writing-preparation")
  }
}
