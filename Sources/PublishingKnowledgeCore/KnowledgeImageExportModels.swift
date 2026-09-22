import Foundation

/// The explicit output the person chose for image files from the knowledge library.
public enum KnowledgeImageExportMode: String, Hashable, Sendable {
  /// Copies the managed original byte-for-byte without decoding it.
  case originalFile
  /// Produces a separate image with identifying metadata removed.
  case privacySanitizedShareCopy
}

public enum KnowledgeImageExportItemOutcome: Hashable, Sendable {
  case exported(destinationURL: URL)
  case skipped(reason: String)
  case failed(reason: String)
}

public struct KnowledgeImageExportItemResult: Hashable, Sendable, Identifiable {
  public let documentID: UUID
  public let sourceName: String
  public let outcome: KnowledgeImageExportItemOutcome

  public var id: UUID { documentID }

  public init(
    documentID: UUID,
    sourceName: String,
    outcome: KnowledgeImageExportItemOutcome
  ) {
    self.documentID = documentID
    self.sourceName = sourceName
    self.outcome = outcome
  }
}

public struct KnowledgeImageExportReport: Hashable, Sendable {
  public let destinationDirectory: URL
  public let mode: KnowledgeImageExportMode
  public let items: [KnowledgeImageExportItemResult]

  public init(
    destinationDirectory: URL,
    mode: KnowledgeImageExportMode,
    items: [KnowledgeImageExportItemResult]
  ) {
    self.destinationDirectory = destinationDirectory
    self.mode = mode
    self.items = items
  }

  public var exportedCount: Int {
    items.reduce(into: 0) { count, item in
      if case .exported = item.outcome { count += 1 }
    }
  }

  public var skippedCount: Int {
    items.reduce(into: 0) { count, item in
      if case .skipped = item.outcome { count += 1 }
    }
  }

  public var failedCount: Int {
    items.reduce(into: 0) { count, item in
      if case .failed = item.outcome { count += 1 }
    }
  }
}
