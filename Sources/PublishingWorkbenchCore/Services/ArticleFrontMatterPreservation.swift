import Foundation
import PublishingCoreSupport
import RepoPressCore

/// Keeps an imported document's source envelope authoritative. Only explicit
/// changes to structured fields become replacements; defaults are not inserted.
/// A field already present in the source always tracks the draft. A missing field
/// is added only where `FrontMatterRenderer` would also write it for the profile.
enum ArticleFrontMatterPreservation {
  /// Marks a cover that belongs in an `extra` mapping the source scanner cannot edit.
  static let unavailableExtraField = "extra-field-unavailable"

  static func values(from source: ImportedFrontMatter, profile: SiteProfile) -> [String: [String]] {
    let scalarKeys = [
      "title", "date", "published", "publishDate", "publishdate", "created", "slug", "description",
      "summary", "excerpt", "socialDescription", "socialdescription", "draft", "publish", "status",
      "visibility", "private", "permalink", "translationKey", "translationkey", "cover", "image",
      "socialImage", "socialimage", "og_preview_img",
    ]
    var values: [String: [String]] = [:]
    for key in scalarKeys {
      // Source paths are case-sensitive. Prefer each canonical spelling while
      // retaining the lowercase aliases read by older importer snapshots.
      if values[key.lowercased()] == nil, let value = source.string(for: key) {
        values[key.lowercased()] = [value]
      }
    }
    for key in ["authors", "author", "aliases", "alias", "tags", "tag", "categories", "category"] {
      let path = taxonomyPath(key, source: source, profile: profile)
      guard let raw = source.value(for: path) else { continue }
      values[key] =
        raw.hasPrefix("[") ? source.strings(for: path) : source.string(for: path).map { [$0] }
    }
    for key in ["cover", "image", "socialimage", "og_preview_img"] {
      if let value = source.string(for: "extra." + key) { values[key] = [value] }
    }
    return values
  }

  static func capturing(_ source: ImportedFrontMatter, draft: ArticleDraft, profile: SiteProfile)
    -> ImportedFrontMatter
  {
    var source = source
    // The shared splitter excludes LF after the closing delimiter. Exclude
    // its CR counterpart here too, without modifying the pinned shared copy.
    if source.rawBlock.hasSuffix("+++\r") || source.rawBlock.hasSuffix("---\r") {
      source.rawBlock.removeLast()
    }
    source.baseline = editableValues(draft: draft, profile: profile, source: source)
    return source
  }

  static func rendered(draft: ArticleDraft, profile: SiteProfile) throws -> String? {
    guard let source = draft.importedFrontMatter else { return nil }
    let current = editableValues(draft: draft, profile: profile, source: source)
    var replacements = current.filter { source.baseline[$0.key] != $0.value }
    // A missing taxonomy table can safely be introduced as one root value.
    if profile.siteKind == .zola,
      source.value(for: "taxonomies") == nil,
      source.value(for: "taxonomies.tags") == nil,
      source.value(for: "taxonomies.categories") == nil,
      !source.rawBlock.contains("[taxonomies]")
    {
      let additions = replacements.filter { $0.key.hasPrefix("taxonomies.") }
      if !additions.isEmpty {
        let separator = source.syntax == .toml ? " = " : ": "
        replacements["taxonomies"] =
          "{ "
          + additions.sorted { $0.key < $1.key }.map {
            String($0.key.dropFirst("taxonomies.".count)) + separator + $0.value
          }.joined(separator: ", ") + " }"
        for key in additions.keys { replacements.removeValue(forKey: key) }
      }
    }
    let extraAdditions = replacements.filter {
      $0.key.hasPrefix("extra.") && source.value(for: $0.key) == nil
    }
    for key in extraAdditions.keys { replacements.removeValue(forKey: key) }
    let rendered = try source.replacing(replacements)
    guard !extraAdditions.isEmpty else { return rendered }
    return try addingExtraFields(extraAdditions, to: rendered, syntax: source.syntax)
  }

  /// `replacing` inserts only simple root keys. Zola keeps the cover under `extra`,
  /// so add it beneath a sole `[extra]` header or append a new final table, then
  /// re-scan to prove the value landed in that table before allowing a write.
  private static func addingExtraFields(
    _ additions: [String: String], to block: String, syntax: ImportedFrontMatter.Syntax
  ) throws -> String {
    let unavailable = FrontMatterPreservationError.unsafe(unavailableExtraField)
    let delimiter = syntax == .toml ? "+++" : "---"
    var block = block.isEmpty ? delimiter + "\n" + delimiter : block
    let newline = block.contains("\r\n") ? "\r\n" : "\n"
    let separator = syntax == .toml ? " = " : ": "
    var fields: [String] = []
    for (path, value) in additions.sorted(by: { $0.key < $1.key }) {
      let key = path.dropFirst("extra.".count)
      let isSimple = key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
      guard !key.isEmpty, isSimple else { throw unavailable }
      fields.append((syntax == .toml ? "" : "  ") + key + separator + value + newline)
    }
    let declarations = lineMatches(#"^[ \t]*[\[{]*[ \t]*["']?extra\b"#, in: block)
    let tableHeaders = lineMatches(#"^[ \t]*\[[ \t]*extra[ \t]*\][ \t]*(#.*)?\r?$"#, in: block)
    if declarations.isEmpty, let closing = block.range(of: "\n", options: .backwards) {
      let header = (syntax == .toml ? "[extra]" : "extra:") + newline
      block.insert(contentsOf: header + fields.joined(), at: closing.upperBound)
    } else if syntax == .toml, declarations.count == 1, let header = tableHeaders.first,
      let lineEnd = block.range(of: "\n", range: header.upperBound..<block.endIndex)
    {
      block.insert(contentsOf: fields.joined(), at: lineEnd.upperBound)
    } else {
      // A nested YAML mapping or an inline/dotted TOML `extra` cannot be scanned safely.
      throw unavailable
    }
    let check = ImportedFrontMatter(rawBlock: block, syntax: syntax)
    _ = try check.replacing([:])
    let landed =
      syntax == .toml
      ? additions.allSatisfy { check.value(for: $0.key) == $0.value }
      : check.value(for: "extra") != nil
    guard landed else { throw unavailable }
    return block
  }

  private static func lineMatches(_ pattern: String, in text: String) -> [Range<String.Index>] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .compactMap { Range($0.range, in: text) }
  }

  private static func dateValue(
    _ date: Date, source: ImportedFrontMatter, path: String, profile: SiteProfile
  ) -> String {
    let profileFormat = profile.dateFormat.nilIfEmpty ?? "yyyy-MM-dd"
    guard let raw = source.value(for: path), let original = source.string(for: path) else {
      return ImportedFrontMatter.quoted(
        FrontMatterRenderer.formattedDate(date, format: profileFormat))
    }
    // Keep the source style: a date-only value must not gain a time or UTC shift.
    let format: String
    if original.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
      format = "yyyy-MM-dd"
    } else if original.range(of: #"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}"#, options: .regularExpression)
      != nil
    {
      format = "yyyy-MM-dd'T'HH:mm:ssxxx"
    } else {
      return ImportedFrontMatter.quoted(
        FrontMatterRenderer.formattedDate(date, format: profileFormat))
    }
    let text = FrontMatterRenderer.formattedDate(date, format: format)
    // Both formats are valid bare TOML/YAML date literals, as Zola documents them.
    let isBare = !raw.hasPrefix("\"") && !raw.hasPrefix("'")
    return isBare ? text : ImportedFrontMatter.quoted(text)
  }

  static func requiresLegacyRecovery(draft: ArticleDraft) -> Bool {
    guard draft.importedFrontMatter == nil,
      draft.repositoryPath?.trimmedForPublishing.nilIfEmpty != nil,
      let binding = draft.repositoryBinding
    else { return false }
    if binding.projectFileContentDigest == nil,
      binding.projectFileRenderedContentDigest == nil
    {
      // A path-only binding is also created for a new draft before its first
      // write. Require evidence of a previous import, write or remote result
      // before treating an absent source envelope as legacy data loss.
      return binding.renderedContentDigest != nil || binding.remoteRevision != nil
        || binding.pendingReviewContentDigest != nil || binding.verification == .verified
        || draft.repositoryImportFingerprint?.trimmedForPublishing.nilIfEmpty != nil
        || draft.repositorySHA?.trimmedForPublishing.nilIfEmpty != nil
    }
    guard let exact = binding.projectFileContentDigest else { return true }
    // The exact imported bytes and the old renderer disagree. Without the
    // source envelope it is impossible to prove that regeneration is lossless.
    return binding.projectFileRenderedContentDigest.map { $0 != exact } ?? true
  }

  private static func taxonomyPath(_ key: String, source: ImportedFrontMatter, profile: SiteProfile)
    -> String
  {
    guard profile.siteKind == .zola, key == "tags" || key == "categories" else { return key }
    if source.value(for: "taxonomies." + key) != nil { return "taxonomies." + key }
    return source.value(for: key) != nil ? key : "taxonomies." + key
  }

  private static func editableValues(
    draft: ArticleDraft, profile: SiteProfile, source: ImportedFrontMatter
  ) -> [String: String] {
    func path(_ candidates: [String]) -> String {
      candidates.first(where: { source.value(for: $0) != nil }) ?? candidates[0]
    }
    let quote = ImportedFrontMatter.quoted
    let array = ImportedFrontMatter.array
    let datePath = path(["date", "published", "publishDate", "publishdate", "created"])
    var values = [
      "title": quote(draft.title), "slug": quote(draft.slug),
      datePath: dateValue(draft.date, source: source, path: datePath, profile: profile),
      path(["description", "summary", "excerpt", "socialDescription", "socialdescription"]): quote(
        draft.summary),
      path(["authors", "author"]): array(draft.authors),
      path(["aliases", "alias"]): array(draft.aliases),
      "permalink": quote(draft.permalink ?? ""),
      taxonomyPath("tags", source: source, profile: profile): array(draft.tags),
      taxonomyPath("categories", source: source, profile: profile): array(draft.categories),
    ]
    let includesDraftFlag = profile.includeDraftFlagInFrontMatter
    if profile.siteKind == .foam {
      if includesDraftFlag || source.value(for: "status") != nil {
        values["status"] = quote(draft.draft ? "draft" : "published")
      }
    } else if source.value(for: "publish") != nil && source.value(for: "draft") == nil {
      values["publish"] = draft.draft ? "false" : "true"
    } else if includesDraftFlag || source.value(for: "draft") != nil {
      values["draft"] = draft.draft ? "true" : "false"
    }
    // The canonical renderer never writes visibility, so only edit an existing field.
    if source.value(for: "private") != nil {
      values["private"] = draft.isPrivate ? "true" : "false"
    } else if source.value(for: "visibility") != nil {
      values["visibility"] = quote(draft.visibility.rawValue)
    }
    if profile.siteKind == .hugo {
      values[path(["translationKey", "translationkey"])] = quote(draft.translationKey ?? "")
    }
    let coverPath = path(
      profile.siteKind == .zola
        ? ["extra.og_preview_img", "extra.cover", "cover", "image"]
        : [
          profile.siteKind.coverFrontMatterFieldName, "cover", "image", "socialImage",
          "socialimage",
        ])
    let cover =
      draft.coverAttachmentID.flatMap { id in
        draft.attachments.first(where: { $0.id == id })?.relativePublishPath
      } ?? ""
    if source.value(for: coverPath) != nil
      || (profile.includeCoverInFrontMatter && !draft.isPrivate)
    {
      values[coverPath] = quote(cover)
    }
    return values
  }
}

extension FrontMatterRenderer {
  public func preservationIssue(draft: ArticleDraft, profile: SiteProfile) -> PreflightIssue? {
    do {
      if ArticleFrontMatterPreservation.requiresLegacyRecovery(draft: draft) {
        throw FrontMatterPreservationError.unsafe("legacy")
      }
      _ = try ArticleFrontMatterPreservation.rendered(draft: draft, profile: profile)
      return nil
    } catch let FrontMatterPreservationError.unsafe(path)
      where path == ArticleFrontMatterPreservation.unavailableExtraField
    {
      return PreflightIssue(
        severity: .error,
        title: CoreL10n.text("封面字段需要在源码中添加"),
        message: CoreL10n.text(
          "原文的 extra 字段无法自动扩展。请在 Front Matter 源码的 extra 中手动添加封面字段，或移除封面后再保存。"),
        field: "cover", ruleID: "content.front-matter.preservation"
      )
    } catch {
      return PreflightIssue(
        severity: .error,
        title: CoreL10n.text("文章元数据需要恢复"),
        message: CoreL10n.text(
          "已停止保存和发布，以免丢失原文的分类、标签或自定义字段。请重新导入原始文章，或在源码中修正无法安全编辑的 Front Matter。"),
        field: "frontMatter", ruleID: "content.front-matter.preservation"
      )
    }
  }
}
