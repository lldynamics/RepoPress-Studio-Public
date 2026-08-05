import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if canImport(Darwin)
import Darwin
#endif
struct FindReplaceBar: View {
  @Binding var findQuery: String
  @Binding var replacementText: String
  @Binding var isFindCaseSensitive: Bool
  @Binding var isFindWholeWord: Bool
  @Binding var isFindRegularExpression: Bool

  let canUseFindReplace: Bool
  let findMatchStatus: String
  let findReplaceMessage: String
  let onFindPrevious: () -> Void
  let onFindNext: () -> Void
  let onReplaceCurrentOrNext: () -> Void
  let onReplaceAll: () -> Void
  let onDismiss: () -> Void

  @FocusState private var isFindFieldFocused: Bool

  var body: some View {
    ViewThatFits(in: .horizontal) {
      wideLayout
      compactLayout
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(.bar)
    .onAppear {
      isFindFieldFocused = true
    }
    .onKeyPress(.return) {
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        onFindPrevious()
      } else {
        onFindNext()
      }
      return .handled
    }
    .onExitCommand(perform: onDismiss)
  }

  private var wideLayout: some View {
    HStack(spacing: 8) {
      findField(maxWidth: 170)
      replacementField(maxWidth: 170)
      findControls
      replaceControls

      if !findReplaceMessage.isEmpty {
        Text(findReplaceMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()
      dismissButton
    }
  }

  private var compactLayout: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        findField(maxWidth: .infinity)
        replacementField(maxWidth: .infinity)
        dismissButton
      }

      HStack(spacing: 8) {
        findControls
        replaceControls
        if !findReplaceMessage.isEmpty {
          Text(findReplaceMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func findField(maxWidth: CGFloat) -> some View {
    TextField("查找", text: $findQuery)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 100, idealWidth: 170, maxWidth: maxWidth)
      .focused($isFindFieldFocused)
      .accessibilityLabel("查找文本")
      .accessibilityValue(findQuery.nilIfEmpty ?? String(localized: "未输入"))
  }

  private func replacementField(maxWidth: CGFloat) -> some View {
    TextField("替换为", text: $replacementText)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 100, idealWidth: 170, maxWidth: maxWidth)
      .accessibilityLabel("替换文本")
      .accessibilityValue(replacementText.nilIfEmpty ?? String(localized: "未输入"))
  }

  private var findControls: some View {
    HStack(spacing: 4) {
      Text(findMatchStatus)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 38)
        .accessibilityLabel("查找匹配位置")
        .accessibilityValue(findMatchStatus)

      Button {
        onFindPrevious()
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(!canUseFindReplace)
      .help(String(localized: "查找上一个（Shift+Return）"))
      .accessibilityLabel("查找上一个")

      Button {
        onFindNext()
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(!canUseFindReplace)
      .help(String(localized: "查找下一个（Return）"))
      .accessibilityLabel("查找下一个")

      Menu {
        Toggle("区分大小写", isOn: $isFindCaseSensitive)
        Toggle("整词匹配", isOn: $isFindWholeWord)
        Toggle("正则表达式", isOn: $isFindRegularExpression)
      } label: {
        Image(systemName: "slider.horizontal.3")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(String(localized: "查找模式"))
      .accessibilityLabel("查找模式")
    }
    .fixedSize()
  }

  private var replaceControls: some View {
    HStack(spacing: 6) {
      Button {
        onReplaceCurrentOrNext()
      } label: {
        Label("替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!canUseFindReplace)
      .accessibilityLabel("替换当前匹配")

      Button {
        onReplaceAll()
      } label: {
        Label("全部替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!canUseFindReplace)
      .accessibilityLabel("全部替换")
    }
    .fixedSize()
  }

  private var dismissButton: some View {
    Button {
      onDismiss()
    } label: {
      Image(systemName: "xmark")
    }
    .buttonStyle(.borderless)
    .help(String(localized: "关闭查找替换"))
    .accessibilityLabel("关闭查找替换")
  }
}
