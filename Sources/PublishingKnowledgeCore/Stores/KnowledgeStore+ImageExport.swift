import Foundation
import PublishingCoreSupport

@MainActor
extension KnowledgeStore {
  @discardableResult
  public func exportImages(
    _ documentIDs: Set<UUID>,
    to destinationDirectory: URL,
    mode: KnowledgeImageExportMode,
    progress: @escaping @MainActor @Sendable (_ completedCount: Int, _ totalCount: Int) -> Void = {
      _, _ in
    }
  ) async -> KnowledgeImageExportReport? {
    guard !documentIDs.isEmpty else { return nil }
    let busyOperationID = beginBusyOperation()
    statusMessage = CoreL10n.format("正在导出 %d 项中的图片…", documentIDs.count)
    progress(0, documentIDs.count)
    defer { finishBusyOperation(busyOperationID) }
    do {
      let report = try await service.exportImages(
        documentIDs: documentIDs,
        to: destinationDirectory,
        mode: mode,
        progress: { completedCount, totalCount in
          Task { @MainActor in
            progress(completedCount, totalCount)
          }
        }
      )
      statusMessage = imageExportStatusMessage(for: report)
      lastError = report.failedCount > 0 ? CoreL10n.text("部分图片未能导出。") : nil
      return report
    } catch {
      lastError = error.localizedDescription
      statusMessage = CoreL10n.format("图片导出失败：%@", error.localizedDescription)
      return nil
    }
  }

  private func imageExportStatusMessage(for report: KnowledgeImageExportReport) -> String {
    let shareCopy = report.mode == .privacySanitizedShareCopy
    let noun = shareCopy ? CoreL10n.text("分享副本") : CoreL10n.text("原图")
    if report.failedCount == 0, report.skippedCount == 0 {
      return CoreL10n.format("已导出 %d 张%@。", report.exportedCount, noun)
    }
    return CoreL10n.format(
      "图片导出完成：%d 张%@，跳过 %d 项，失败 %d 项。",
      report.exportedCount,
      noun,
      report.skippedCount,
      report.failedCount
    )
  }
}
