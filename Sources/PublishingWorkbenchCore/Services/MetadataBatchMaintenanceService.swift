import Foundation

/// An immutable, field-scoped plan for article metadata maintenance.  It
/// deliberately stores only the field it owns, so a later body or unrelated
/// Front Matter change is never replayed from an old whole-draft snapshot.
public enum MetadataBatchMaintenanceField: String, CaseIterable, Hashable, Sendable {
  case tags
  case categories

  public var localizedTitle: String {
    switch self {
    case .tags: CoreL10n.text("标签")
    case .categories: CoreL10n.text("分类")
    }
  }
}

public enum MetadataBatchMaintenanceOperation: Equatable, Sendable {
  case add(String)
  case remove(String)
  case rename(source: String, destination: String)
}

public struct MetadataBatchMaintenancePreview: Identifiable, Equatable, Sendable {
  public let documentID: UUID
  /// The ownership context captured with the field baseline. A plan must never
  /// cross a later site or general-draft ownership change.
  public let siteProfileID: UUID
  public let scope: ArticleDraftScope
  public let title: String
  public let originalValues: [String]
  public let proposedValues: [String]

  public var id: UUID { documentID }
  public var hasChange: Bool { originalValues != proposedValues }
}

public struct MetadataBatchMaintenancePlan: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let field: MetadataBatchMaintenanceField
  public let operation: MetadataBatchMaintenanceOperation
  public let previews: [MetadataBatchMaintenancePreview]

  public init(
    id: UUID = UUID(),
    field: MetadataBatchMaintenanceField,
    operation: MetadataBatchMaintenanceOperation,
    previews: [MetadataBatchMaintenancePreview]
  ) {
    self.id = id
    self.field = field
    self.operation = operation
    self.previews = previews
  }

  public var applicablePreviews: [MetadataBatchMaintenancePreview] {
    previews.filter(\.hasChange)
  }
}

public enum MetadataBatchMaintenanceApplyOutcome: Equatable, Sendable {
  case applied(changedCount: Int, versionCount: Int)
  case conflicts([UUID])
  case unavailable([UUID])
  case noChanges
  /// Existing pending work could not be durably flushed, so this batch did
  /// not create versions or mutate metadata.
  case preflightPersistenceFailed
  /// Recovery versions were created in memory but their synchronous save
  /// failed, so metadata was not mutated.
  case recoveryVersionPersistenceFailed
  case insufficientRecoveryVersions
  /// Metadata may have reached some project files before the final flush
  /// failed. The recovery versions were already durably saved and remain
  /// available for an explicit restore.
  case persistenceFailed(recoveryVersionCount: Int)
}

public struct MetadataBatchMaintenanceService: Sendable {
  public init() {}

  public func plan(
    drafts: [ArticleDraft],
    field: MetadataBatchMaintenanceField,
    operation: MetadataBatchMaintenanceOperation
  ) -> MetadataBatchMaintenancePlan {
    MetadataBatchMaintenancePlan(
      field: field,
      operation: operation,
      previews: drafts.map { draft in
        let original = values(for: draft, field: field)
        return MetadataBatchMaintenancePreview(
          documentID: draft.id,
          siteProfileID: draft.siteProfileID,
          scope: draft.scope,
          title: draft.title,
          originalValues: original,
          proposedValues: applying(operation, to: original)
        )
      }
    )
  }

  public func values(
    for draft: ArticleDraft,
    field: MetadataBatchMaintenanceField
  ) -> [String] {
    switch field {
    case .tags: draft.tags
    case .categories: draft.categories
    }
  }

  public func applying(
    _ operation: MetadataBatchMaintenanceOperation,
    to original: [String]
  ) -> [String] {
    switch operation {
    case .add(let rawValue):
      return deduplicating(original + normalizedInputValues(rawValue))
    case .remove(let rawValue):
      let removed = normalizedInputValues(rawValue)
      return original.filter { !contains(removed, value: $0) }
    case .rename(let source, let destination):
      let sources = normalizedInputValues(source)
      let destinations = normalizedInputValues(destination)
      guard !sources.isEmpty, !destinations.isEmpty else { return original }
      return deduplicating(
        original.flatMap { value in
          contains(sources, value: value) ? destinations : [value]
        })
    }
  }

  private func normalizedInputValues(_ rawValue: String) -> [String] {
    rawValue
      .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func deduplicating(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { value in
      let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      return seen.insert(key).inserted
    }
  }

  private func contains(_ values: [String], value: String) -> Bool {
    let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return values.contains {
      $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
    }
  }
}
