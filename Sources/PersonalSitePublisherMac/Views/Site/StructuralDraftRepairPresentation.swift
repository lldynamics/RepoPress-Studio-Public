import Foundation

enum StructuralDraftRepairStep: Int, CaseIterable, Equatable, Identifiable {
  case preserveContent
  case restoreFiles
  case confirm

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .preserveContent: return String(localized: "保留旧内容")
    case .restoreFiles: return String(localized: "可选恢复文件")
    case .confirm: return String(localized: "确认并修复")
    }
  }

  var next: StructuralDraftRepairStep? {
    Self(rawValue: rawValue + 1)
  }

  var previous: StructuralDraftRepairStep? {
    Self(rawValue: rawValue - 1)
  }
}

struct StructuralDraftRepairSelection: Equatable {
  var draftIDs: Set<UUID> = []
  var paths: Set<String> = []

  static let empty = StructuralDraftRepairSelection()

  var canApply: Bool {
    !draftIDs.isEmpty || !paths.isEmpty
  }
}

struct StructuralDraftRepairDraftRecord: Identifiable, Equatable {
  let id: UUID
  let title: String
  let repositoryPath: String
}

struct StructuralDraftRepairDraftGroup: Identifiable, Equatable {
  var id: String { repositoryPath }
  let repositoryPath: String
  let records: [StructuralDraftRepairDraftRecord]
}

enum StructuralDraftRepairPresentation {
  static func groups(
    for records: [StructuralDraftRepairDraftRecord]
  ) -> [StructuralDraftRepairDraftGroup] {
    let grouped = Dictionary(grouping: records, by: \.repositoryPath)
    return grouped.keys.sorted().map { path in
      StructuralDraftRepairDraftGroup(repositoryPath: path, records: grouped[path] ?? [])
    }
  }

  static func nextStep(after step: StructuralDraftRepairStep) -> StructuralDraftRepairStep? {
    step.next
  }

  static func previousStep(before step: StructuralDraftRepairStep) -> StructuralDraftRepairStep? {
    step.previous
  }

  static func canAdvance(
    from step: StructuralDraftRepairStep,
    selection: StructuralDraftRepairSelection
  ) -> Bool {
    switch step {
    case .preserveContent, .restoreFiles:
      // File-only recovery remains a valid, deliberate operation.
      return true
    case .confirm:
      return selection.canApply
    }
  }
}
