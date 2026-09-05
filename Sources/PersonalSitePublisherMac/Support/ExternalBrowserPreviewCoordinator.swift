import Combine
import Foundation
import PublishingWorkbenchCore

@MainActor
final class ExternalBrowserPreviewCoordinator: ObservableObject {
  enum Target: Equatable {
    case currentArticle
    case siteHome

    var progressMessage: String {
      switch self {
      case .currentArticle:
        String(localized: "正在准备当前文章预览…")
      case .siteHome:
        String(localized: "正在准备站点首页预览…")
      }
    }

    var readyMessage: String {
      switch self {
      case .currentArticle:
        String(localized: "当前文章已在浏览器中打开。")
      case .siteHome:
        String(localized: "站点首页已在浏览器中打开。")
      }
    }
  }

  private struct PendingOpen {
    let generation: UInt64
    let draftID: UUID
    let target: Target
    let preparation: LocalSiteExternalPreviewPreparation
    let executionFingerprint: String
    let previewGeneration: UInt64?

    var url: URL {
      switch target {
      case .currentArticle:
        preparation.articleURL
      case .siteHome:
        preparation.siteURL
      }
    }

    func recordingPreviewGeneration(_ previewGeneration: UInt64) -> PendingOpen {
      PendingOpen(
        generation: generation,
        draftID: draftID,
        target: target,
        preparation: preparation,
        executionFingerprint: executionFingerprint,
        previewGeneration: previewGeneration
      )
    }
  }

  typealias URLOpener = (URL, String, @escaping (String) -> Void) -> Bool

  @Published private(set) var isBusy = false
  @Published private(set) var message: String?
  @Published private(set) var errorMessage: String?
  @Published private(set) var pendingAuthorizationRequest: LocalSitePreviewAuthorizationRequest?

  private let store: WorkbenchStore
  private let previewState: WorkbenchLocalSitePreviewFeatureFacade
  private let readinessService: LocalSitePreviewPageReadinessService
  private let urlOpener: URLOpener
  private var openTask: Task<Void, Never>?
  private var pendingOpen: PendingOpen?
  private var generation: UInt64 = 0

  init(
    store: WorkbenchStore,
    readinessService: LocalSitePreviewPageReadinessService = .init(),
    urlOpener: @escaping URLOpener = { url, failureMessage, report in
      ExternalURLOpener.open(url, failureMessage: failureMessage, report: report)
    }
  ) {
    self.store = store
    previewState = WorkbenchLocalSitePreviewFeatureFacade(store: store)
    self.readinessService = readinessService
    self.urlOpener = urlOpener
  }

  func openCurrentArticle(for draftID: UUID) {
    beginOpen(target: .currentArticle, draftID: draftID)
  }

  func openSiteHome(for draftID: UUID) {
    beginOpen(target: .siteHome, draftID: draftID)
  }

  func authorizeAndContinue(_ request: LocalSitePreviewAuthorizationRequest) {
    guard let pendingOpen, pendingAuthorizationRequest == request else { return }
    pendingAuthorizationRequest = nil
    guard pendingOpen.generation == generation else { return }

    switch previewState.authorizeAndStart(request) {
    case .started:
      beginReadinessWait(for: pendingOpen)
    case .needsConfirmation(let replacementRequest):
      pendingAuthorizationRequest = replacementRequest
      message = String(localized: "请再次确认本地预览命令。")
    case .failed(let failureMessage):
      finishFailure(failureMessage, generation: pendingOpen.generation)
    }
  }

  func cancelPendingOpen() {
    generation &+= 1
    openTask?.cancel()
    openTask = nil
    pendingOpen = nil
    pendingAuthorizationRequest = nil
    isBusy = false
  }

  /// Scene and draft changes use this rather than waiting for a later page
  /// readiness callback. It keeps a former draft from opening after the user
  /// has already moved on, without surfacing a misleading failure alert.
  func cancelPendingOpen(ifDraftIsNoLongerCurrent draftID: UUID?) {
    guard let pendingOpen, pendingOpen.draftID != draftID else { return }
    cancelPendingOpen()
  }

  func dismissError() {
    errorMessage = nil
  }

  private func beginOpen(target: Target, draftID: UUID) {
    cancelPendingOpen()
    let currentGeneration = generation
    isBusy = true
    message = target.progressMessage
    errorMessage = nil

    openTask = Task { [weak self] in
      guard let self else { return }
      do {
        let preparation = try await self.store.prepareLocalSiteExternalPreview(for: draftID)
        guard self.isCurrent(currentGeneration) else { return }
        guard
          let executionFingerprint = self.store.localSitePreviewPlan?
            .executionIdentity?.fingerprint
        else {
          throw LocalSiteExternalPreviewPreparationError.previewUnavailable
        }
        let pendingOpen = PendingOpen(
          generation: currentGeneration,
          draftID: draftID,
          target: target,
          preparation: preparation,
          executionFingerprint: executionFingerprint,
          previewGeneration: nil
        )
        self.pendingOpen = pendingOpen

        if self.store.localSitePreviewRuntimeStatus.isRunning {
          self.beginReadinessWait(for: pendingOpen)
          return
        }

        switch self.previewState.start() {
        case .started:
          self.beginReadinessWait(for: pendingOpen)
        case .needsConfirmation(let request):
          guard self.isCurrent(currentGeneration) else { return }
          self.pendingAuthorizationRequest = request
          self.isBusy = false
          self.message = String(localized: "需要确认本地预览命令后才能打开浏览器。")
        case .failed(let failureMessage):
          self.finishFailure(failureMessage, generation: currentGeneration)
        }
      } catch is CancellationError {
        return
      } catch {
        self.finishFailure(error.localizedDescription, generation: currentGeneration)
      }
    }
  }

  private func beginReadinessWait(for pendingOpen: PendingOpen) {
    guard isCurrent(pendingOpen.generation) else { return }
    let pendingOpen = pendingOpen.recordingPreviewGeneration(
      store.localSitePreviewValidationGeneration
    )
    self.pendingOpen = pendingOpen
    isBusy = true
    message = String(localized: "正在等待预览页面就绪…")
    openTask = Task { [weak self] in
      guard let self else { return }
      let isReady = await self.readinessService.waitUntilReady(pendingOpen.url)
      guard !Task.isCancelled, self.isCurrent(pendingOpen.generation) else { return }
      guard isReady else {
        self.finishFailure(
          String(localized: "本地预览已启动，但目标页面尚未就绪。请稍后重试。"),
          generation: pendingOpen.generation
        )
        return
      }
      guard let previewGeneration = pendingOpen.previewGeneration,
        self.store.selectedDraftID == pendingOpen.draftID,
        self.store.draft(for: pendingOpen.draftID) != nil,
        await self.store.isLocalSiteExternalPreviewCurrent(
          pendingOpen.preparation,
          targetURL: pendingOpen.url,
          executionFingerprint: pendingOpen.executionFingerprint,
          previewGeneration: previewGeneration
        ),
        !Task.isCancelled,
        self.isCurrent(pendingOpen.generation)
      else {
        if self.isCurrent(pendingOpen.generation),
          self.store.selectedDraftID != pendingOpen.draftID
        {
          self.cancelPendingOpen()
        } else {
          self.finishFailure(
            String(localized: "文章或站点配置在预览准备期间已变更，请重新打开预览。"),
            generation: pendingOpen.generation
          )
        }
        return
      }

      let didOpen = self.urlOpener(
        pendingOpen.url,
        String(localized: "无法在默认浏览器中打开本地预览。")
      ) { [weak self] failureMessage in
        guard let self, self.isCurrent(pendingOpen.generation) else { return }
        self.message = failureMessage
        self.errorMessage = failureMessage
      }
      guard self.isCurrent(pendingOpen.generation) else { return }
      if didOpen {
        self.isBusy = false
        self.openTask = nil
        self.pendingOpen = nil
        self.message = pendingOpen.target.readyMessage
        EditorAccessibilityAnnouncementCenter.announce(self.message ?? "")
      } else {
        self.finishFailure(
          self.errorMessage
            ?? String(localized: "无法在默认浏览器中打开本地预览。"),
          generation: pendingOpen.generation
        )
      }
    }
  }

  private func finishFailure(_ failureMessage: String, generation: UInt64) {
    guard isCurrent(generation) else { return }
    isBusy = false
    openTask = nil
    pendingOpen = nil
    pendingAuthorizationRequest = nil
    message = failureMessage
    errorMessage = failureMessage
    EditorAccessibilityAnnouncementCenter.announce(failureMessage, priority: .high)
  }

  private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
    generation == expectedGeneration
  }
}
