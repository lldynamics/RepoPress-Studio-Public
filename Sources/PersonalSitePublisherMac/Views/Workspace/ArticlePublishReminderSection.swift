import SwiftUI

struct ArticlePublishReminderSection: View {
  @Binding var reminderAt: Date?
  @Binding var draftID: UUID
  @State private var proposedDate = Date().addingTimeInterval(3_600)
  @State private var isRequestingPermission = false
  @State private var message: String?

  var body: some View {
    InspectorSection("到期提醒") {
      if let date = reminderAt {
        LabeledContent("提醒时间", value: date.formatted(date: .abbreviated, time: .shortened))
        Button("取消提醒", role: .destructive) { reminderAt = nil }
          .accessibilityLabel("取消文章发布提醒")
      } else {
        DatePicker(
          "提醒时间", selection: $proposedDate, in: Date()...,
          displayedComponents: [.date, .hourAndMinute]
        )
        .accessibilityLabel("文章发布提醒时间")
        Button("设置到期提醒") { enableReminder() }
          .disabled(isRequestingPermission)
          .accessibilityLabel("设置文章发布提醒")
      }
      Text("到期时发送本机通知；打开通知后可检查并发布文章。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let message {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onChange(of: draftID) { _, _ in message = nil }
    .accessibilityIdentifier("article-publish-reminder")
  }

  private func enableReminder() {
    let requestedDraftID = draftID
    let date = proposedDate
    isRequestingPermission = true
    message = nil
    Task { @MainActor in
      defer { isRequestingPermission = false }
      do {
        let isAllowed = try await ArticlePublishReminderCoordinator.shared.requestPermission()
        guard draftID == requestedDraftID else { return }
        guard isAllowed else {
          message = String(localized: "请在系统设置中允许 RepoPress Studio 发送通知。")
          return
        }
        guard draftID == requestedDraftID, date > Date() else { return }
        reminderAt = date
      } catch {
        guard draftID == requestedDraftID else { return }
        message = String(localized: "无法启用通知，请稍后重试。")
      }
    }
  }
}
