import AppKit
import Foundation
import PublishingWorkbenchCore

enum MarkdownScrollSyncSource: Equatable {
  case editor
  case preview
}

struct MarkdownScrollSyncUpdate: Equatable, Identifiable {
  let id: UUID
  let source: MarkdownScrollSyncSource
  let progress: Double

  init(source: MarkdownScrollSyncSource, progress: Double) {
    id = UUID()
    self.source = source
    self.progress = min(max(progress.isFinite ? progress : 0, 0), 1)
  }
}

@MainActor
final class MarkdownScrollViewSyncBridge: NSObject {
  private let source: MarkdownScrollSyncSource
  private let onProgressChanged: (Double) -> Void
  private let service = MarkdownScrollSynchronizationService()
  private weak var scrollView: NSScrollView?
  private var lastAppliedSynchronizationUpdateID: UUID?
  private var lastAppliedRestorationUpdateID: UUID?
  private var lastReportedProgress: Double?
  private var isApplyingUpdate = false

  private enum UpdatePurpose {
    case synchronization
    case restoration
  }

  init(
    source: MarkdownScrollSyncSource,
    onProgressChanged: @escaping (Double) -> Void
  ) {
    self.source = source
    self.onProgressChanged = onProgressChanged
    super.init()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func observe(_ scrollView: NSScrollView) {
    NotificationCenter.default.removeObserver(self)
    self.scrollView = scrollView
    lastAppliedSynchronizationUpdateID = nil
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
  }

  func apply(
    _ update: MarkdownScrollSyncUpdate?,
    includingOwnSource: Bool = false,
    allowDeferredRetry: Bool = true
  ) {
    apply(
      update,
      includingOwnSource: includingOwnSource,
      allowDeferredRetry: allowDeferredRetry,
      purpose: .synchronization
    )
  }

  func restore(_ update: MarkdownScrollSyncUpdate?) {
    apply(
      update,
      includingOwnSource: true,
      allowDeferredRetry: true,
      purpose: .restoration
    )
  }

  private func apply(
    _ update: MarkdownScrollSyncUpdate?,
    includingOwnSource: Bool,
    allowDeferredRetry: Bool,
    purpose: UpdatePurpose
  ) {
    guard let update,
          let scrollView,
          (includingOwnSource || update.source != source),
          update.id != lastAppliedUpdateID(for: purpose) else {
      return
    }

    scrollView.layoutSubtreeIfNeeded()
    let viewportLength = Double(scrollView.contentView.bounds.height)
    let contentLength = Double(scrollView.documentView?.frame.height ?? 0)
    let scrollableLength = max(0, contentLength - viewportLength)
    guard scrollableLength > 0 || update.progress == 0 else {
      guard allowDeferredRetry else { return }
      DispatchQueue.main.async { [weak self] in
        self?.apply(
          update,
          includingOwnSource: includingOwnSource,
          allowDeferredRetry: false,
          purpose: purpose
        )
      }
      return
    }

    setLastAppliedUpdateID(update.id, for: purpose)
    let y = service.contentOffset(
      progress: update.progress,
      viewportLength: viewportLength,
      contentLength: contentLength
    )
    isApplyingUpdate = true
    scrollView.contentView.scroll(
      to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    lastReportedProgress = update.progress
    DispatchQueue.main.async { [weak self] in
      self?.isApplyingUpdate = false
    }
  }

  private func lastAppliedUpdateID(for purpose: UpdatePurpose) -> UUID? {
    switch purpose {
    case .synchronization:
      return lastAppliedSynchronizationUpdateID
    case .restoration:
      return lastAppliedRestorationUpdateID
    }
  }

  private func setLastAppliedUpdateID(_ id: UUID, for purpose: UpdatePurpose) {
    switch purpose {
    case .synchronization:
      lastAppliedSynchronizationUpdateID = id
    case .restoration:
      lastAppliedRestorationUpdateID = id
    }
  }

  @objc
  private func scrollBoundsDidChange(_ notification: Notification) {
    guard !isApplyingUpdate,
          let scrollView,
          let changedClipView = notification.object as? NSClipView,
          changedClipView === scrollView.contentView else {
      return
    }

    let progress = service.progress(
      contentOffset: Double(scrollView.contentView.bounds.origin.y),
      viewportLength: Double(scrollView.contentView.bounds.height),
      contentLength: Double(scrollView.documentView?.frame.height ?? 0)
    )
    if let lastReportedProgress,
       abs(lastReportedProgress - progress) < 0.001 {
      return
    }
    lastReportedProgress = progress
    onProgressChanged(progress)
  }

}
