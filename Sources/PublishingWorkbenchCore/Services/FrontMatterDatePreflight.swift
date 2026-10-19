import Foundation
import RepoPressCore

/// Checks the document that will be published, including preserved imported
/// metadata. The configured format controls new output, but valid ISO dates
/// and timestamps imported from a generator remain publishable.
enum FrontMatterDatePreflight {
  static func issue(draft: ArticleDraft, profile: SiteProfile) -> PreflightIssue? {
    let rendered = FrontMatterRenderer().render(draft: draft, profile: profile)
    guard let envelope = ImportedFrontMatter.split(rendered).frontMatter,
      let key = ["date", "published", "publishDate", "publishdate", "created"].first(where: {
        envelope.value(for: $0) != nil
      }),
      let value = envelope.string(for: key)
    else { return nil }
    let format = profile.dateFormat.trimmedForPublishing.nilIfEmpty ?? "yyyy-MM-dd"
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    formatter.isLenient = false
    if let date = formatter.date(from: value),
      format != "yyyy-MM-dd" || formatter.string(from: date) == value
    {
      return nil
    }
    // Zola and the other supported generators accept ISO dates/timestamps.
    // A preferred date-only output format must not reject a valid imported instant.
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    dateOnly.isLenient = false
    let prefix = String(value.prefix(10))
    if let date = dateOnly.date(from: prefix), dateOnly.string(from: date) == prefix {
      if value == prefix { return nil }
      let timestampPattern =
        #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#
      let iso = ISO8601DateFormatter()
      for options: ISO8601DateFormatter.Options in [
        [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
      ] {
        iso.formatOptions = options
        if value.range(of: timestampPattern, options: .regularExpression) != nil,
          iso.date(from: value) != nil
        {
          return nil
        }
      }
    }
    return PreflightIssue(
      severity: .error,
      title: CoreL10n.text("日期值无效"),
      message: CoreL10n.format(
        "字段 %@ 的值为 %@，不是有效日期。请使用有效的 ISO 日期、时间戳或站点格式 %@。",
        key, value, format),
      field: "date",
      ruleID: "frontmatter.date-format")
  }
}
