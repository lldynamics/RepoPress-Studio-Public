import Foundation

/// Keeps App Store compliance decisions centralized instead of scattering
/// assumptions about the distribution channel across individual features.
public enum DistributionFeaturePolicy {
  /// Every distribution channel exposes the same free BYOK AI integration.
  /// Users configure and fund their own provider account; RepoPress does not
  /// meter AI requests or make provider access a Pro entitlement.
  public static var allowsExternalAIProviders: Bool {
    true
  }

  /// Browser capture uses an independently installed store extension and the
  /// app's sandboxed loopback bridge.
  public static var allowsBrowserCapture: Bool {
    true
  }

  public static var visiblePremiumFeatures: [PremiumFeature] {
    PremiumFeature.allCases.filter { $0 != .aiRequest }
  }

  public static var proUpgradeMessage: String {
    "Pro 解锁更多线上发布和批量发布能力。AI 使用用户自备的服务商 API Key，不按应用内次数收费。"
  }
}
