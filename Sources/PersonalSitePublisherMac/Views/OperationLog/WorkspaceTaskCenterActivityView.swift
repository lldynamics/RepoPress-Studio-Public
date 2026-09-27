import PublishingWorkbenchCore
import SwiftUI

/// The task center's activity page. The facade is the only Core boundary this
/// embedded surface observes; the parent owns sheet dismissal and workspace
/// navigation when a record asks to locate sync activity.
struct WorkspaceTaskCenterActivityView: View {
  @ObservedObject private var operationLog: WorkbenchOperationLogFeatureFacade
  private let openSyncWorkspace: () -> Void

  init(
    operationLog: WorkbenchOperationLogFeatureFacade,
    openSyncWorkspace: @escaping () -> Void
  ) {
    _operationLog = ObservedObject(wrappedValue: operationLog)
    self.openSyncWorkspace = openSyncWorkspace
  }

  var body: some View {
    let entries = presentationEntries
    OperationLogView(
      allEntries: entries,
      siteProfiles: siteProfiles(for: entries),
      retentionPolicy: OperationLogPresentation.RetentionPolicy(
        workbenchPolicy: operationLog.retentionPolicy
      ),
      statusMessage: operationLog.statusMessage,
      openSyncWorkspace: openSyncWorkspace,
      setRetentionPolicy: { policy in
        operationLog.setRetentionPolicy(policy.workbenchPolicy)
      },
      clearOperationLog: operationLog.clear,
      dismissStatusMessage: operationLog.dismissStatusMessage
    )
  }

  private var presentationEntries: [OperationLogPresentation.Entry] {
    operationLog.entries.map(OperationLogPresentation.Entry.init(operationLogEntry:))
  }

  private func siteProfiles(
    for entries: [OperationLogPresentation.Entry]
  ) -> [OperationLogPresentation.SiteProfileOption] {
    let loggedProfileIDs = Set(entries.compactMap(\.profileID))
    return operationLog.profiles
      .filter { loggedProfileIDs.contains($0.id) }
      .map { .init(id: $0.id, name: $0.name) }
      .sorted { lhs, rhs in
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }
}

extension OperationLogPresentation.Entry {
  init(operationLogEntry entry: WorkbenchOperationLogEntry) {
    let category: OperationLogPresentation.Category
    switch entry.category {
    case .publishing: category = .publishing
    case .maintenance: category = .maintenance
    case .automation: category = .automation
    case .ai: category = .ai
    case .deployment: category = .deployment
    case .importing: category = .importing
    case .images: category = .images
    case .backup: category = .backup
    }

    let outcome: OperationLogPresentation.Outcome
    switch entry.outcome {
    case .succeeded: outcome = .succeeded
    case .partial: outcome = .partial
    case .failed: outcome = .failed
    case .cancelled: outcome = .cancelled
    case .recorded: outcome = .recorded
    case .observed: outcome = .observed
    }

    let actor: OperationLogPresentation.Actor
    switch entry.actor {
    case .user: actor = .user
    case .automation: actor = .automation
    case .background: actor = .background
    }

    self.init(
      id: entry.id,
      sourceLabel: Self.sourceLabel(for: entry.sourceReference.kind),
      category: category,
      categoryDisplayName: category.title,
      outcome: outcome,
      outcomeDisplayName: outcome.title,
      actor: actor,
      actorDisplayName: actor.title,
      title: entry.title,
      summary: entry.summary,
      profileID: entry.profileID,
      targetLabel: entry.targetLabel,
      occurredAt: entry.occurredAt,
      systemImage: entry.systemImage
    )
  }

  private static func sourceLabel(for kind: WorkbenchOperationLogSourceKind) -> String {
    switch kind {
    case .releaseRecord: String(localized: "发布记录")
    case .maintenanceOperation: String(localized: "维护操作")
    case .automationRun: String(localized: "自动化运行")
    case .aiMetadataApplication: String(localized: "AI 元数据应用")
    case .deploymentStatus: String(localized: "部署状态")
    case .operationEvent: String(localized: "活动事件")
    }
  }
}

extension OperationLogPresentation.RetentionPolicy {
  init(workbenchPolicy: WorkbenchOperationLogRetentionPolicy) {
    switch workbenchPolicy {
    case .thirtyDays: self = .thirtyDays
    case .ninetyDays: self = .ninetyDays
    case .oneYear: self = .oneYear
    case .forever: self = .forever
    }
  }

  var workbenchPolicy: WorkbenchOperationLogRetentionPolicy {
    switch self {
    case .thirtyDays: .thirtyDays
    case .ninetyDays: .ninetyDays
    case .oneYear: .oneYear
    case .forever: .forever
    }
  }
}
