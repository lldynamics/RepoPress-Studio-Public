import Foundation
import PublishingWorkbenchCore
import SwiftUI

#if canImport(Translation)
import Translation
#endif

/// The small set of availability states that matters to RSS routing. Keeping
/// this independent from Apple's framework makes the automatic/manual policy
/// testable without pretending that Translation works in the simulator.
enum RSSAppleTranslationAvailabilityStatus: String, Equatable, Sendable {
  case installed
  case supported
  case unsupported
}

enum RSSArticleTranslationRoutingIssue: String, Equatable, Sendable {
  case requiresMacOS15
  case customTarget
  case languageDownloadRequired
  case unsupportedLanguagePair
  case availabilityUnknown

  var message: String {
    switch self {
    case .requiresMacOS15:
      return String(localized: "Apple 本机翻译需要 macOS 15 或更高版本；当前请求不会自动改发给 AI。")
    case .customTarget:
      return String(localized: "Apple 本机翻译不支持自定义目标语言，请选择系统预设语言或切换到当前 AI 服务。")
    case .languageDownloadRequired:
      return String(localized: "Apple 本机翻译的目标语言包尚未安装；手动翻译可请求系统下载，自动翻译不会弹出下载提示。")
    case .unsupportedLanguagePair:
      return String(localized: "Apple 本机翻译不支持当前语言组合，请选择其他系统语言或切换到当前 AI 服务。")
    case .availabilityUnknown:
      return String(localized: "暂时无法确认 Apple 本机翻译的语言支持状态，请稍后重试。")
    }
  }
}

enum RSSArticleTranslationRoutingDecision: Equatable, Sendable {
  case ai
  case apple
  case blocked(RSSArticleTranslationRoutingIssue)
}

/// Encodes the boundary between the user-selected backend and the system
/// language availability result. Automatic requests are deliberately stricter
/// than explicit requests: `.supported` means “download is possible”, not
/// “download silently while opening an article”.
enum RSSArticleTranslationRoutingPolicy {
  static func decision(
    backend: RSSArticleTranslationBackend,
    force: Bool,
    target: RSSArticleTranslationTarget,
    isAppleTranslationAvailable: Bool,
    availability: RSSAppleTranslationAvailabilityStatus?
  ) -> RSSArticleTranslationRoutingDecision {
    guard backend == .apple else { return .ai }
    guard isAppleTranslationAvailable else {
      return .blocked(.requiresMacOS15)
    }
    guard !target.languageCode.hasPrefix("custom:") else {
      return .blocked(.customTarget)
    }
    guard let availability else {
      return .blocked(.availabilityUnknown)
    }

    switch availability {
    case .installed:
      return .apple
    case .supported:
      return force ? .apple : .blocked(.languageDownloadRequired)
    case .unsupported:
      return .blocked(.unsupportedLanguagePair)
    }
  }
}

/// A view-bound request. The Translation framework may present download UI,
/// so the session must stay attached to the RSS reader view and must not be
/// put in a store or another long-lived object.
struct RSSAppleTranslationSessionRequest: Identifiable, Sendable {
  let id: UUID
  let articleID: String
  let target: RSSArticleTranslationTarget
  let plan: RSSArticleSystemTranslationPlan

  init(
    id: UUID,
    articleID: String,
    target: RSSArticleTranslationTarget,
    plan: RSSArticleSystemTranslationPlan
  ) {
    self.id = id
    self.articleID = articleID
    self.target = target
    self.plan = plan
  }
}

/// A no-op-compatible host on macOS 14 and a TranslationSession-backed host
/// on macOS 15+. `RSSReaderView` keeps this view in its tree for the full RSS
/// reader lifetime and drives it by replacing `request`.
struct RSSAppleTranslationSessionHost: View {
  let request: RSSAppleTranslationSessionRequest?
  let onCompletion: (UUID, RSSArticleTranslationResult) -> Void
  let onFailure: (UUID, String) -> Void

  var body: some View {
    if #available(macOS 15.0, *) {
      RSSAppleTranslationSessionHostAvailable(
        request: request,
        onCompletion: onCompletion,
        onFailure: onFailure
      )
      .id(request?.id)
    } else {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
    }
  }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct RSSAppleTranslationSessionHostAvailable: View {
  let request: RSSAppleTranslationSessionRequest?
  let onCompletion: (UUID, RSSArticleTranslationResult) -> Void
  let onFailure: (UUID, String) -> Void

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .accessibilityHidden(true)
      .translationTask(configuration) { session in
        guard let request else { return }

        do {
          let translationRequests = request.plan.requests.map {
            TranslationSession.Request(
              sourceText: $0.sourceText,
              clientIdentifier: $0.id
            )
          }
          var translatedTexts: [String: String] = [:]
          for try await response in session.translate(batch: translationRequests) {
            guard let clientIdentifier = response.clientIdentifier else { continue }
            translatedTexts[clientIdentifier] = response.targetText
          }
          let result = try request.plan.makeResult(
            translationsByRequestID: translatedTexts,
            providerName: RSSAppleTranslationSessionHost.providerName,
            model: RSSAppleTranslationSessionHost.model
          )
          await MainActor.run {
            onCompletion(request.id, result)
          }
        } catch is CancellationError {
          // Replacing or clearing the request intentionally cancels the
          // view-bound task. The caller has already invalidated its UUID.
        } catch {
          await MainActor.run {
            onFailure(request.id, error.localizedDescription)
          }
        }
      }
  }

  private var configuration: TranslationSession.Configuration? {
    guard let request else { return nil }
    return TranslationSession.Configuration(
      source: nil,
      target: Locale.Language(identifier: request.target.languageCode)
    )
  }
}
#endif

extension RSSAppleTranslationSessionHost {
  static var providerName: String { String(localized: "Apple 本机翻译") }
  static let model = "on-device/system"
}

enum RSSAppleTranslationAvailability {
  /// Checks a representative source sample without requesting downloads.
  /// The caller decides whether a `.supported` result is allowed to proceed.
  static func status(
    for sourceText: String,
    target: RSSArticleTranslationTarget
  ) async throws -> RSSAppleTranslationAvailabilityStatus {
#if canImport(Translation)
    if #available(macOS 15.0, *) {
      let availability = LanguageAvailability()
      let status = try await availability.status(
        for: sourceText,
        to: Locale.Language(identifier: target.languageCode)
      )
      switch status {
      case .installed:
        return .installed
      case .supported:
        return .supported
      case .unsupported:
        return .unsupported
      @unknown default:
        return .unsupported
      }
    }
#endif
    return .unsupported
  }
}
