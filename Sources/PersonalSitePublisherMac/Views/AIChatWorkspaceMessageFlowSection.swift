import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatMessageDayGroup: Identifiable {
  let id: Date
  let title: String
  var messages: [AIPublishingChatMessage]
}

struct AIChatMessageFlowState {
  let draft: ArticleDraft
  let messages: [AIPublishingChatMessage]
  let isRunning: Bool
  let capabilityMode: AIPublishingCapabilityCenterMode
  let applyMessage: String?
}

struct AIChatMessageFlowActions {
  let setCapabilityMode: (AIPublishingCapabilityCenterMode) -> Void
  let promptSelected: (String) -> Void
  let openPromptLibrary: () -> Void
  let actionAvailability: (AIPublishingChatMessage, ArticleDraft?) -> AIPublishingChatMessageActionAvailability
  let canReplaceSelection: (ArticleDraft) -> Bool
  let messageActions: AIChatMessageActions
}

struct AIChatMessageActions {
  let copy: (AIPublishingChatMessage) -> Void
  let quote: (AIPublishingChatMessage) -> Void
  let delete: (AIPublishingChatMessage) -> Void
  let branch: (AIPublishingChatMessage) -> Void
  let regenerate: (AIPublishingChatMessage) -> Void
  let apply: AIChatMessageApplyActions
}

struct AIChatMessageApplyActions {
  let appendToBody: (AIPublishingChatMessage) -> Void
  let replaceSelection: (AIPublishingChatMessage) -> Void
  let replaceBody: (AIPublishingChatMessage) -> Void
}

struct AIChatMessageFlowView<ContextOverviewContent: View>: View {
  let state: AIChatMessageFlowState
  let contextOverview: () -> ContextOverviewContent
  let actions: AIChatMessageFlowActions

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          contextOverview()

          if state.messages.isEmpty {
            QuickPromptGrid(
              capabilityMode: capabilityModeBinding,
              isAIChatRunning: state.isRunning,
              onPromptSelected: actions.promptSelected
            )
            .padding(.top, 10)
          } else {
            activeConversationPromptRow

            ForEach(messageDayGroups) { group in
              messageDaySeparator(group.title)

              ForEach(group.messages) { message in
                AIChatMessageRow(
                  message: message,
                  actionAvailability: actions.actionAvailability(message, state.draft),
                  canReplaceSelection: actions.canReplaceSelection(state.draft),
                  onCopy: {
                    actions.messageActions.copy(message)
                  },
                  onQuote: {
                    actions.messageActions.quote(message)
                  },
                  onDelete: {
                    actions.messageActions.delete(message)
                  },
                  onBranch: {
                    actions.messageActions.branch(message)
                  },
                  onRegenerate: {
                    actions.messageActions.regenerate(message)
                  },
                  onAppendToBody: {
                    actions.messageActions.apply.appendToBody(message)
                  },
                  onReplaceSelection: {
                    actions.messageActions.apply.replaceSelection(message)
                  },
                  onReplaceBody: {
                    actions.messageActions.apply.replaceBody(message)
                  }
                )
              }
            }
          }

          if state.isRunning {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("AI 正在回复...")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .id("ai-running")
          }

          if let applyMessage = state.applyMessage {
            Text(applyMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(18)
      }
      .onChange(of: state.messages.count) { _, _ in
        scrollToBottom(proxy)
      }
      .onChange(of: state.isRunning) { _, _ in
        scrollToBottom(proxy)
      }
      .onChange(of: state.messages.last?.content) { _, _ in
        scrollToBottom(proxy)
      }
    }
  }

  private var capabilityModeBinding: Binding<AIPublishingCapabilityCenterMode> {
    Binding(
      get: {
        state.capabilityMode
      },
      set: { newValue in
        actions.setCapabilityMode(newValue)
      }
    )
  }

  private var activeConversationPromptRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(AIPublishingQuickPrompt.primaryPrompts) { prompt in
          Button {
            actions.promptSelected(prompt.prompt)
          } label: {
            Label(prompt.localizedDisplayName, systemImage: prompt.systemImage)
          }
          .buttonStyle(.bordered)
          .disabled(state.isRunning)
        }

        Button {
          actions.openPromptLibrary()
        } label: {
          Label("更多指令", systemImage: "books.vertical")
        }
        .buttonStyle(.bordered)
        .disabled(state.isRunning)
      }
      .controlSize(.small)
      .padding(.vertical, 2)
    }
  }

  private var messageDayGroups: [AIChatMessageDayGroup] {
    var groups: [AIChatMessageDayGroup] = []
    let calendar = Calendar.current

    for message in state.messages {
      let day = calendar.startOfDay(for: message.createdAt)
      if let lastIndex = groups.indices.last, groups[lastIndex].id == day {
        groups[lastIndex].messages.append(message)
      } else {
        groups.append(
          AIChatMessageDayGroup(
            id: day,
            title: messageDayTitle(for: day, calendar: calendar),
            messages: [message]
          )
        )
      }
    }

    return groups
  }

  private func messageDayTitle(for day: Date, calendar: Calendar) -> String {
    if calendar.isDateInToday(day) {
      return String(localized: "今天")
    }
    if calendar.isDateInYesterday(day) {
      return String(localized: "昨天")
    }

    return day.formatted(
      .dateTime
        .year()
        .month(.wide)
        .day()
        .weekday(.wide)
        .locale(.autoupdatingCurrent)
    )
  }

  private func messageDaySeparator(_ title: String) -> some View {
    HStack(spacing: 10) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(WorkbenchOpacity.chartEmphasis))
        .frame(height: 1)

      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(WorkbenchBackgroundStyle.control, in: Capsule())

      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(WorkbenchOpacity.chartEmphasis))
        .frame(height: 1)
    }
    .padding(.vertical, 2)
    .accessibilityLabel("对话日期 \(title)")
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
      if state.isRunning {
        proxy.scrollTo("ai-running", anchor: .bottom)
      } else if let lastMessage = state.messages.last {
        proxy.scrollTo(lastMessage.id, anchor: .bottom)
      }
    }
  }
}
