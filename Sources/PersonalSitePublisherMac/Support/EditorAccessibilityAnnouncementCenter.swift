import AppKit
import PublishingWorkbenchCore

@MainActor
enum EditorAccessibilityAnnouncementCenter {
  static func announceDiagnostics(_ issues: [PreflightIssue]) {
    let errorCount = issues.filter { $0.severity == .error }.count
    let warningCount = issues.filter { $0.severity == .warning }.count
    let infoCount = issues.filter { $0.severity == .info }.count
    guard !issues.isEmpty else {
      post(String(localized: "诊断完成，没有发现问题。"), priority: .medium)
      return
    }

    post(
      String(
        format: String(localized: "诊断完成：%@ 个错误，%@ 个警告，%@ 个提示。"),
        "\(errorCount)",
        "\(warningCount)",
        "\(infoCount)"
      ),
      priority: errorCount > 0 ? .high : .medium
    )
  }

  static func announceFindResult(
    _ result: MarkdownFindResult,
    direction: MarkdownFindDirection
  ) {
    var message = String(
      format: String(localized: "找到第 %@ 项，共 %@ 项。"),
      "\(result.currentNumber)",
      "\(result.total)"
    )
    if result.didWrap {
      let wrapMessage = direction == .next
        ? String(localized: "已从开头继续查找。")
        : String(localized: "已从末尾继续查找。")
      message += " " + wrapMessage
    }
    post(message, priority: .low)
  }

  static func announceFindMessage(_ message: String, isError: Bool = false) {
    post(message, priority: isError ? .high : .low)
  }

  static func announceImageInsertion(count: Int) {
    post(
      String(
        format: String(localized: "已插入 %@ 张图片，请完善图片信息。"),
        "\(count)"
      ),
      priority: .medium
    )
  }

  static func announceVideoInsertion(count: Int) {
    post(
      String(
        format: String(localized: "已插入 %@ 个视频。"),
        "\(count)"
      ),
      priority: .medium
    )
  }

  static func announceAIPreview(kind: String, characterCount: Int) {
    post(
      String(
        format: String(localized: "AI 预览已生成：%@，建议内容 %@ 个字符。"),
        kind,
        "\(characterCount)"
      ),
      priority: .medium
    )
  }

  static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
    post(message, priority: priority)
  }

  private static func post(
    _ message: String,
    priority: NSAccessibilityPriorityLevel
  ) {
    let announcement = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !announcement.isEmpty else { return }
    DispatchQueue.main.async {
      guard let application = NSApp else { return }
      NSAccessibility.post(
        element: application,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement,
          .priority: priority.rawValue,
        ]
      )
    }
  }
}
