public enum MarkupEscaping {
  /// Escapes text-node content while leaving quotes untouched.
  public static func htmlText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// Escapes a double-quoted HTML attribute. Apostrophes remain readable.
  public static func htmlDoubleQuotedAttribute(_ value: String) -> String {
    htmlText(value)
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Conservative HTML escaping for content reused in text or attributes.
  public static func html(_ value: String) -> String {
    htmlDoubleQuotedAttribute(value)
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  /// Preserves the project's existing XML output convention.
  public static func xmlText(_ value: String) -> String {
    htmlDoubleQuotedAttribute(value)
  }
}
