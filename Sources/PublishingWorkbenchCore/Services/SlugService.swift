import Foundation

public enum SlugService {
  public static func fallbackSlug(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: date)
  }

  public static func slug(from text: String) -> String {
    let trimmed = text
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9\p{Han}\p{Hiragana}\p{Katakana}]+"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return trimmed.isEmpty ? fallbackSlug() : trimmed
  }

  public static func isValid(_ slug: String, rule: SiteSlugValidationRule) -> Bool {
    let value = slug.trimmedForPublishing
    guard !value.isEmpty else { return false }

    switch rule {
    case .disabled:
      return true
    case .relaxed:
      return value.range(
        of: #"^[A-Za-z0-9\p{Han}\p{Hiragana}\p{Katakana}_-]+$"#,
        options: .regularExpression
      ) != nil
    case .lowercaseKebab:
      return value.range(
        of: #"^[a-z0-9\p{Han}\p{Hiragana}\p{Katakana}]+(-[a-z0-9\p{Han}\p{Hiragana}\p{Katakana}]+)*$"#,
        options: .regularExpression
      ) != nil
    }
  }
}
