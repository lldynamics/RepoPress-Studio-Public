import Combine
import Foundation
import PublishingWorkbenchCore
import UserNotifications

@MainActor
final class ArticlePublishReminderCoordinator: NSObject, UNUserNotificationCenterDelegate {
  static let shared = ArticlePublishReminderCoordinator()
  private var observation: AnyCancellable?
  private weak var store: WorkbenchStore?
  private var revision: UInt64 = 0
  private var reconcileTask: Task<Void, Never>?
  /// The plans last handed to reconciliation. The workbench changes for many
  /// unrelated reasons (RSS, library, repository polling); only a change in
  /// these plans needs a round trip to the notification center.
  private var requestedPlans: [ArticlePublishReminderPlan]?
  var openWorkbench: (() -> Void)?

  func install(store: WorkbenchStore) {
    guard self.store !== store else { return }
    self.store = store
    observation = store.objectWillChange
      .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.scheduleReconciliation() }
      }
    requestedPlans = nil
    scheduleReconciliation()
  }

  func configureLaunch(openWorkbench: @escaping () -> Void) {
    self.openWorkbench = openWorkbench
    UNUserNotificationCenter.current().delegate = self
  }

  func requestPermission() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional: return true
    case .notDetermined:
      return try await center.requestAuthorization(options: [.alert, .sound])
    default: return false
    }
  }

  private func scheduleReconciliation() {
    let plans = currentPlans()
    guard plans != requestedPlans else { return }
    requestedPlans = plans
    revision &+= 1
    guard reconcileTask == nil else { return }
    reconcileTask = Task { [weak self] in
      guard let self else { return }
      var processedRevision: UInt64?
      while processedRevision != self.revision {
        let requestedRevision = self.revision
        await self.reconcile(self.currentPlans(), revision: requestedRevision)
        processedRevision = requestedRevision
      }
      self.reconcileTask = nil
    }
  }

  private func currentPlans() -> [ArticlePublishReminderPlan] {
    ArticlePublishReminderPlan.plans(for: store?.drafts ?? [], now: Date())
  }

  private func reconcile(_ plans: [ArticlePublishReminderPlan], revision: UInt64) async {
    let center = UNUserNotificationCenter.current()
    let pending = await center.pendingNotificationRequests()
    guard self.revision == revision else { return }
    let wantedIDs = Set(plans.map(\.identifier))
    let obsoleteIDs = pending.map(\.identifier).filter {
      $0.hasPrefix(ArticlePublishReminderPlan.identifierPrefix) && !wantedIDs.contains($0)
    }
    center.removePendingNotificationRequests(withIdentifiers: obsoleteIDs)
    let settings = await center.notificationSettings()
    guard self.revision == revision,
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    else { return }
    let pendingByID = Dictionary(
      pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    for plan in plans {
      guard self.revision == revision else { return }
      guard plan.date > Date() else { continue }
      // Re-adding an unchanged request would only churn the notification
      // center; replace a request only when its date or title changed.
      if let existing = pendingByID[plan.identifier], Self.matches(existing, plan) { continue }
      let content = UNMutableNotificationContent()
      content.title = String(localized: "文章到期发布提醒")
      content.body = plan.title
      content.sound = .default
      content.userInfo = ["draftID": plan.draftID.uuidString]
      // A calendar trigger keeps the wall-clock time across sleep and clock
      // changes, unlike an interval measured from when it was scheduled.
      let components = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: plan.date)
      let request = UNNotificationRequest(
        identifier: plan.identifier, content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
      )
      do {
        try await center.add(request)
      } catch {
        // A stored reminder remains visible and may be reconciled on the next
        // edit or launch. Scheduling failure must never start a publication.
        NSLog("RepoPress publish reminder scheduling failed: %@", error.localizedDescription)
      }
    }
  }

  static func matches(
    _ request: UNNotificationRequest, _ plan: ArticlePublishReminderPlan
  ) -> Bool {
    guard request.content.body == plan.title,
      let trigger = request.trigger as? UNCalendarNotificationTrigger,
      let date = trigger.nextTriggerDate()
    else { return false }
    return abs(date.timeIntervalSince(plan.date)) < 1
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    guard notification.request.identifier.hasPrefix(ArticlePublishReminderPlan.identifierPrefix)
    else { return [] }
    return [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let rawID = response.notification.request.content.userInfo["draftID"] as? String,
      let draftID = UUID(uuidString: rawID)
    else { return }
    await MainActor.run {
      WorkbenchShortcutCoordinator.shared.enqueue(.openArticle(draftID))
      self.openWorkbench?()
    }
  }
}
