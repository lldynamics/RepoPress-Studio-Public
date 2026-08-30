public enum BrowserExtensionProtocol {
  public static func allows(method: String, path: String) -> Bool {
    allowedRoutes[path]?.contains(method.uppercased()) == true
  }
}
