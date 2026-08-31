import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A UTF-8, safe-projection-only export used by the activity window. The
/// payload intentionally omits stable source identifiers and any raw record
/// fields so it remains safe to share outside the workspace.
struct OperationLogExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }

  let data: Data

  init(entries: [OperationLogPresentation.Entry]) {
    data = Self.exportData(for: entries)
  }

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }

  static func exportData(for entries: [OperationLogPresentation.Entry]) -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let payload = entries.map { entry in
      ExportEntry(
        occurredAt: formatter.string(from: entry.occurredAt),
        source: entry.sourceLabel,
        category: entry.categoryDisplayName,
        outcome: entry.outcomeDisplayName,
        actor: entry.actorDisplayName,
        title: entry.title,
        summary: entry.summary,
        target: entry.targetLabel
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(payload)) ?? Data("[]".utf8)
  }

  private struct ExportEntry: Codable, Equatable {
    let occurredAt: String
    let source: String
    let category: String
    let outcome: String
    let actor: String
    let title: String
    let summary: String
    let target: String?
  }
}
