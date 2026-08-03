/// Keeps non-commercial channel capabilities centralized instead of scattering
/// build-channel assumptions across individual features.
public enum DistributionFeaturePolicy {
  public static var allowsExternalAIProviders: Bool {
    true
  }

  public static var allowsBrowserCapture: Bool {
    true
  }
}
