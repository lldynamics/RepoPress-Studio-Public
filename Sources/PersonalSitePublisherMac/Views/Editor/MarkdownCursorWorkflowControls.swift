import PublishingWorkbenchCore
import SwiftUI

struct MarkdownCursorWorkflowControls: View {
  let position: MarkdownCursorPosition?
  let lineCount: Int
  let fenceMatch: MarkdownFenceMatch?
  let completion: MarkdownCompletionContext?
  let showsTitle: Bool
  let onJumpToLine: (Int) -> Void
  let onJumpToCounterpartFence: () -> Void
  let onApplyCompletion: (MarkdownCompletionCandidate) -> Void
  let onInsertCompletionTrigger: (MarkdownCompletionTrigger) -> Void

  @State private var isGoToLinePresented = false
  @State private var requestedLine = ""
  @FocusState private var isLineFieldFocused: Bool

  var body: some View {
    HStack(spacing: 5) {
      completionMenu

      if let fenceMatch {
        Button(action: onJumpToCounterpartFence) {
          Label(
            fenceStatus(fenceMatch),
            systemImage: fenceMatch.isClosed
              ? "chevron.left.forwardslash.chevron.right"
              : "exclamationmark.triangle"
          )
          .labelStyle(.titleAndIcon)
          .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(fenceMatch.isClosed ? Color.secondary : WorkbenchTheme.warning)
        .help(
          fenceMatch.isClosed
            ? String(
              localized:
                "代码围栏第 \(fenceMatch.openingLine)–\(fenceMatch.closingLine ?? fenceMatch.openingLine) 行；点击跳转到另一端"
            )
            : String(localized: "代码围栏未闭合；点击定位到起始标记")
        )
        .accessibilityIdentifier("markdown-fence-match-button")
      }

      Button {
        requestedLine = position.map { String($0.line) } ?? "1"
        isGoToLinePresented = true
      } label: {
        Text(cursorStatus)
          .font(.caption.monospacedDigit())
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("l", modifiers: [.command])
      .foregroundStyle(.secondary)
      .help(String(localized: "当前光标位置；点击或按 ⌘L 跳转到指定行"))
      .accessibilityLabel("光标位置")
      .accessibilityValue(cursorStatus)
      .accessibilityIdentifier("markdown-cursor-position-button")
      .popover(isPresented: $isGoToLinePresented, arrowEdge: .bottom) {
        goToLinePopover
      }
    }
  }

  private var completionMenu: some View {
    Menu {
      if let completion {
        let totalCount = completion.candidates.count
        let prefixCount = min(12, totalCount)
        let sectionTitle =
          totalCount > 12
          ? "\(completionSectionTitle(completion.kind))（显示前 \(prefixCount) 项，共 \(totalCount) 项）"
          : completionSectionTitle(completion.kind)
        Section(sectionTitle) {
          ForEach(completion.candidates.prefix(12)) { candidate in
            Button {
              onApplyCompletion(candidate)
            } label: {
              VStack(alignment: .leading) {
                Text(candidate.title)
                Text(candidate.detail)
              }
            }
          }
        }
        Divider()
      }

      Section("输入触发词") {
        ForEach(MarkdownCompletionTrigger.allCases) { trigger in
          Button {
            onInsertCompletionTrigger(trigger)
          } label: {
            Label(trigger.title, systemImage: trigger.systemImage)
          }
        }
      }
    } label: {
      if showsTitle {
        Label(
          "Markdown 智能补全",
          systemImage: completion == nil ? "wand.and.stars" : "wand.and.stars.inverse"
        )
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
      } else {
        Image(systemName: completion == nil ? "wand.and.stars" : "wand.and.stars.inverse")
          .frame(width: 24, height: 24)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(completion == nil ? Color.secondary : WorkbenchTheme.primary)
    .help(
      completion == nil
        ? String(localized: "智能补全：支持 / 块命令、[[文章]] 和代码语言")
        : String(localized: "有 \(completion?.candidates.count ?? 0) 个可用补全")
    )
    .accessibilityLabel("Markdown 智能补全")
    .accessibilityValue(
      completion == nil ? String(localized: "没有活动补全") : String(localized: "有可用补全")
    )
    .accessibilityIdentifier("markdown-completion-menu")
  }

  private var goToLinePopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("跳转到行")
        .font(.headline)
      TextField("行号", text: $requestedLine)
        .textFieldStyle(.roundedBorder)
        .frame(width: 180)
        .focused($isLineFieldFocused)
        .onSubmit(performLineJump)
        .accessibilityLabel("行号")
        .accessibilityIdentifier("markdown-go-to-line-field")
      Text(String(localized: "正文共 \(lineCount) 行"))
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("取消") {
          isGoToLinePresented = false
        }
        Spacer()
        Button("跳转", action: performLineJump)
          .keyboardShortcut(.defaultAction)
          .disabled(validRequestedLine == nil)
      }
    }
    .padding(14)
    .onAppear {
      isLineFieldFocused = true
    }
  }

  private var cursorStatus: String {
    guard let position else { return String(localized: "行 —，列 —") }
    return String(localized: "行 \(position.line)，列 \(position.column)")
  }

  private var validRequestedLine: Int? {
    guard let line = Int(requestedLine), (1...max(1, lineCount)).contains(line) else {
      return nil
    }
    return line
  }

  private func performLineJump() {
    guard let line = validRequestedLine else { return }
    isGoToLinePresented = false
    onJumpToLine(line)
  }

  private func fenceStatus(_ match: MarkdownFenceMatch) -> String {
    guard let closingLine = match.closingLine else { return String(localized: "围栏未闭合") }
    return "\(match.openingLine)–\(closingLine)"
  }

  private func completionSectionTitle(_ kind: MarkdownCompletionKind) -> String {
    switch kind {
    case .slashCommand:
      String(localized: "块命令")
    case .internalLink:
      String(localized: "文章链接")
    case .codeLanguage:
      String(localized: "代码语言")
    }
  }
}
