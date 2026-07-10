import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatComposerState {
  let isChatRunning: Bool
  let chatMessage: String?
  let chatContextModeDetail: String
  let focusedParagraphID: String?
  let focusedParagraph: AIPublishingChatDraftParagraph?
}

struct AIChatComposerPresentation {
  let sendReadiness: AIPublishingChatSendReadiness
  let modelPresentation: AIChatModelSelectionPresentation
  let modelGradeBinding: Binding<AIChatModelGrade>
  let customModelBinding: Binding<String>
  let chatContextModeBinding: Binding<AIPublishingChatContextMode>
  let chatModelGrades: [AIChatModelGrade]
  let chatModelHelpText: String
  let chatContextModeDisplayName: String
}

struct AIChatComposerActions {
  let openPromptLibrary: () -> Void
  let setCustomModel: (String) -> Void
  let resetModelToProfileDefault: () -> Void
  let setFocusedParagraph: (String?) -> Void
  let stopGenerating: () -> Void
  let send: () -> Void
  let appendArticleContext: () -> Void
  let appendParagraphContext: (AIPublishingChatDraftParagraph) -> Void
  let appendPublishingContext: () -> Void
  let saveCustomPrompt: () -> Void
  let importImages: () -> Void
  let toggleImageAttachment: (UUID) -> Void
  let attachmentLabel: (DraftAttachment) -> String
}

struct AIChatComposerView: View {
  let draft: ArticleDraft
  @Binding var inputText: String
  @Binding var applyMessage: String?
  @Binding var selectedImageAttachmentIDs: Set<UUID>
  let isComposerFocused: FocusState<Bool>.Binding
  let state: AIChatComposerState
  let presentation: AIChatComposerPresentation
  let actions: AIChatComposerActions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      toolbar

      if !selectedImageAttachmentIDs.isEmpty {
        selectedImageAttachmentStrip
      }

      if let message = state.chatMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextEditor(text: $inputText)
          .font(.body)
          .focused(isComposerFocused)
          .frame(minHeight: 62, maxHeight: 110)
          .scrollContentBackground(.hidden)
          .padding(8)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
          .accessibilityIdentifier("ai-chat-composer")
          .accessibilityLabel("AI 对话输入")

        if state.isChatRunning {
          Button {
            actions.stopGenerating()
          } label: {
            Label("停止", systemImage: "stop.fill")
          }
          .keyboardShortcut(.escape, modifiers: [])
        } else {
          Button {
            actions.send()
          } label: {
            Label("发送", systemImage: "paperplane.fill")
          }
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(!presentation.sendReadiness.canSend)
        }
      }
    }
    .padding(14)
    .background(.bar)
  }

  private var toolbar: some View {
    HStack {
      Picker("上下文", selection: presentation.chatContextModeBinding) {
        ForEach(AIPublishingChatContextMode.allCases) { mode in
          Label(mode.displayName, systemImage: mode.systemImage)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)
      .help(state.chatContextModeDetail)
      .disabled(state.isChatRunning)
      .accessibilityLabel("AI 对话上下文")
      .accessibilityValue(presentation.chatContextModeDisplayName)

      Picker("模型", selection: presentation.modelGradeBinding) {
        ForEach(presentation.chatModelGrades) { grade in
          Text(grade.title)
            .tag(grade)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 240)
      .help(presentation.chatModelHelpText)
      .disabled(state.isChatRunning)
      .accessibilityLabel("AI 模型档位")
      .accessibilityValue(presentation.modelGradeBinding.wrappedValue.title)

      if presentation.modelPresentation.canEditCustomModel {
        TextField("模型名称", text: presentation.customModelBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
          .help(presentation.chatModelHelpText)
          .disabled(state.isChatRunning)
          .accessibilityLabel("AI 模型名称")
          .accessibilityValue(presentation.customModelBinding.wrappedValue.nilIfEmpty ?? "未填写")
      }

      modelSelectionMenu

      Button {
        actions.openPromptLibrary()
      } label: {
        Label("AI 指令库", systemImage: "books.vertical")
      }
      .disabled(state.isChatRunning)

      Button {
        actions.appendArticleContext()
      } label: {
        Label("引用文章", systemImage: "doc.text.magnifyingglass")
      }
      .disabled(state.isChatRunning)

      paragraphContextMenu

      Button {
        actions.appendPublishingContext()
      } label: {
        Label("引用发布状态", systemImage: "checklist")
      }
      .disabled(state.isChatRunning)

      imageAttachmentMenu

      Button {
        actions.saveCustomPrompt()
      } label: {
        Label("保存提示", systemImage: "bookmark")
      }
      .disabled(state.isChatRunning || inputText.trimmedForPublishing.isEmpty)

      Spacer()
    }
  }

  private var modelSelectionMenu: some View {
    Menu {
      ForEach(presentation.modelPresentation.modelCandidates, id: \.self) { model in
        Button {
          actions.setCustomModel(model)
        } label: {
          if model == presentation.modelPresentation.activeModel {
            Label(model, systemImage: "checkmark")
          } else {
            Text(model)
          }
        }
      }

      Divider()

      Button {
        actions.resetModelToProfileDefault()
      } label: {
        Label("使用默认模型 \(presentation.modelPresentation.defaultModel)", systemImage: "arrow.counterclockwise")
      }
    } label: {
      Label("选择模型", systemImage: "chevron.up.chevron.down")
    }
    .disabled(state.isChatRunning || presentation.modelPresentation.modelCandidates.isEmpty)
  }

  private var imageAttachmentMenu: some View {
    Menu {
      Button {
        actions.importImages()
      } label: {
        Label("从文件添加图片...", systemImage: "plus")
      }

      Divider()

      if draft.attachments.isEmpty {
        Text("当前文章没有图片附件")
      } else {
        ForEach(draft.attachments) { attachment in
          Button {
            actions.toggleImageAttachment(attachment.id)
          } label: {
            Label(
              actions.attachmentLabel(attachment),
              systemImage: selectedImageAttachmentIDs.contains(attachment.id) ? "checkmark.circle.fill" : "circle"
            )
          }
        }
      }
    } label: {
      Label(
        selectedImageAttachmentIDs.isEmpty ? "附加图片" : "附加图片 \(selectedImageAttachmentIDs.count)",
        systemImage: "paperclip"
      )
    }
    .disabled(state.isChatRunning)
  }

  private var paragraphContextMenu: some View {
    let paragraphs = AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown)
    let focusedParagraph = state.focusedParagraph
    return Menu {
      if state.focusedParagraphID?.nilIfEmpty != nil {
        Button {
          actions.setFocusedParagraph(nil)
        } label: {
          Label("整篇文章上下文", systemImage: "doc.text")
        }
      }
      if paragraphs.isEmpty {
        Text("当前正文没有可引用段落")
      } else {
        if state.focusedParagraphID?.nilIfEmpty == nil {
          Label("整篇文章上下文", systemImage: "checkmark.circle.fill")
        }
        Divider()
        ForEach(paragraphs) { paragraph in
          Menu {
            Button {
              actions.setFocusedParagraph(paragraph.id)
            } label: {
              Label(
                "设为对话上下文",
                systemImage: focusedParagraph?.id == paragraph.id ? "checkmark.circle.fill" : "scope"
              )
            }

            Button {
              actions.appendParagraphContext(paragraph)
            } label: {
              Label("插入到输入框", systemImage: "text.quote")
            }
          } label: {
            Label(
              paragraph.title,
              systemImage: focusedParagraph?.id == paragraph.id ? "checkmark.circle.fill" : "text.quote"
            )
          }
        }
      }
    } label: {
      Label(state.focusedParagraphID?.nilIfEmpty == nil ? "引用段落" : "聚焦段落", systemImage: "text.quote")
    }
    .disabled(state.isChatRunning || (paragraphs.isEmpty && state.focusedParagraphID?.nilIfEmpty == nil))
  }

  private var selectedImageAttachmentStrip: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(draft.attachments.filter { selectedImageAttachmentIDs.contains($0.id) }) { attachment in
            HStack(spacing: 6) {
              Image(systemName: "photo")
                .foregroundStyle(.secondary)
              Text(actions.attachmentLabel(attachment))
                .lineLimit(1)
              Button {
                selectedImageAttachmentIDs.remove(attachment.id)
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.borderless)
              .help("移除图片附件")
              .accessibilityLabel("移除图片附件")
              .accessibilityValue(actions.attachmentLabel(attachment))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(WorkbenchBackgroundStyle.control, in: Capsule())
          }
        }
      }

      if let imageIssue = presentation.sendReadiness.imageAttachmentIssue {
        Label(imageIssue, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
  }
}
