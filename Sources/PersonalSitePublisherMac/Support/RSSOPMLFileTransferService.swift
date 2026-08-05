import AppKit
import PublishingWorkbenchCore
import UniformTypeIdentifiers

@MainActor
enum RSSOPMLFileTransferService {
  struct ImportResult {
    let feedIDs: [UUID]
  }

  struct ExportResult {
    let destinationURL: URL
    let exportedSubscriptionCount: Int
    let excludedSubscriptionCount: Int
  }

  static func importOPML(into store: RSSReaderStore) throws -> ImportResult? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      .xml,
      UTType(filenameExtension: "opml") ?? .data,
    ]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let url = panel.url else { return nil }

    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) <= 5 * 1024 * 1024 else {
      throw RSSReaderError.invalidOPML("文件超过 5 MB")
    }
    let originalData = try Data(contentsOf: url)
    let subscriptions = try RSSOPMLParser.parse(data: originalData)
    let riskReport = RSSOPMLWriter.scanExportRisks(subscriptions: subscriptions)
    let importData: Data

    if riskReport.hasSuspectedCredentialQueryParameters {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(localized: "OPML 中的地址可能包含访问凭证")
      alert.informativeText = credentialRiskDescription(
        report: riskReport,
        actionDescription: String(
          localized: "可以将疑似凭证值替换为 REDACTED 后导入，或排除有风险的订阅。脱敏后需要有效凭证的订阅可能无法刷新。"
        )
      )
      alert.addButton(withTitle: String(localized: "脱敏后导入"))
      alert.addButton(withTitle: String(localized: "排除后导入"))
      alert.addButton(withTitle: String(localized: "取消"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        importData = try RSSOPMLWriter.prepareDocument(
          subscriptions: subscriptions,
          privacyAction: .redactCredentialQueryValues
        ).data
      case .alertSecondButtonReturn:
        importData = try RSSOPMLWriter.prepareDocument(
          subscriptions: subscriptions,
          privacyAction: .excludeSubscriptionsWithCredentialQuery
        ).data
      default:
        return nil
      }
    } else {
      importData = originalData
    }

    return ImportResult(feedIDs: try store.importOPML(data: importData))
  }

  static func exportOPML(from store: RSSReaderStore) throws -> ExportResult? {
    guard !store.feeds.isEmpty else {
      throw RSSReaderError.invalidOPML("没有可导出的 RSS 订阅。")
    }

    let subscriptions = store.feeds.map {
      RSSOPMLSubscription(title: $0.displayTitle, url: $0.url, siteURL: $0.siteURL)
    }
    let riskReport = RSSOPMLWriter.scanExportRisks(subscriptions: subscriptions)
    guard !riskReport.hasBlockingUserInfo else {
      throw RSSReaderError.invalidOPML("订阅地址包含 URL 用户名或密码，请先修改地址。")
    }

    let privacyAction: RSSOPMLExportPrivacyAction
    if riskReport.hasSuspectedCredentialQueryParameters {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(localized: "导出前处理可能的访问凭证")
      alert.informativeText = credentialRiskDescription(
        report: riskReport,
        actionDescription: String(
          localized: "可以保留订阅并将疑似凭证值替换为 REDACTED，或整个排除这些订阅。"
        )
      )
      alert.addButton(withTitle: String(localized: "脱敏导出"))
      alert.addButton(withTitle: String(localized: "排除风险订阅"))
      alert.addButton(withTitle: String(localized: "取消"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        privacyAction = .redactCredentialQueryValues
      case .alertSecondButtonReturn:
        privacyAction = .excludeSubscriptionsWithCredentialQuery
      default:
        return nil
      }
    } else {
      privacyAction = .redactCredentialQueryValues
    }

    let prepared = try RSSOPMLWriter.prepareDocument(
      subscriptions: subscriptions,
      title: "RepoPress Studio RSS 订阅",
      privacyAction: privacyAction
    )
    let panel = NSSavePanel()
    panel.title = String(localized: "导出 OPML")
    panel.message = String(localized: "OPML 仅包含订阅名称与地址，不包含文章缓存或阅读状态。")
    panel.prompt = String(localized: "导出")
    panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = "rss-subscriptions.opml"
    guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

    let destinationURL = selectedURL.pathExtension.isEmpty
      ? selectedURL.appendingPathExtension("opml")
      : selectedURL
    try prepared.data.write(to: destinationURL, options: .atomic)
    return ExportResult(
      destinationURL: destinationURL,
      exportedSubscriptionCount: prepared.exportedSubscriptionCount,
      excludedSubscriptionCount: prepared.excludedSubscriptionCount
    )
  }

  private static func credentialRiskDescription(
    report: RSSSubscriptionURLPrivacyReport,
    actionDescription: String
  ) -> String {
    let names = report.suspectedCredentialQueryParameterNames
      .prefix(8)
      .joined(separator: "、")
    let parameterSummary = names.isEmpty
      ? String(localized: "未识别具体参数名。")
      : String(localized: "疑似参数：\(names)。")
    return String(
      localized: "检测到 \(report.affectedSubscriptionCount) 个订阅可能包含访问凭证。\(parameterSummary)\n\n\(actionDescription)"
    )
  }
}
