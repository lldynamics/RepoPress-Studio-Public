import AppKit
import ImageIO
import PublishingWorkbenchCore

final class MarkdownInlineAttachmentOverlayView: NSView {
  enum Content {
    case image(accessibilityText: String)
    case formula(
      source: String,
      displayMode: MarkdownFormulaDisplayMode,
      fontSize: CGFloat
    )
  }

  private let imageView = NSImageView()
  private let formulaLabel = NSTextField(labelWithString: "")
  private let placeholder = NSImageView(
    image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
  )

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = 10
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.86).cgColor

    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    placeholder.contentTintColor = .tertiaryLabelColor
    placeholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
    formulaLabel.alignment = .center
    formulaLabel.maximumNumberOfLines = 2
    formulaLabel.lineBreakMode = .byTruncatingTail

    for view in [imageView, placeholder, formulaLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
      formulaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      formulaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      formulaLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  /// Clears state that belongs to the previous attachment before this view is
  /// returned to the coordinator's bounded reuse pool.  In particular, an
  /// image task may finish after the view has left the viewport, so retaining
  /// its image or accessibility state would make a later formula/image
  /// attachment briefly display the previous content.
  override func prepareForReuse() {
    imageView.image = nil
    imageView.isHidden = true
    placeholder.isHidden = true
    formulaLabel.attributedStringValue = NSAttributedString(string: "")
    formulaLabel.isHidden = true
    setAccessibilityElement(false)
  }

  func configure(_ content: Content) {
    switch content {
    case .image(let accessibilityText):
      applyCardAppearance(cornerRadius: 10, backgroundAlpha: 0.86)
      imageView.isHidden = false
      placeholder.isHidden = imageView.image != nil
      formulaLabel.isHidden = true
      setAccessibilityElement(true)
      setAccessibilityRole(.image)
      setAccessibilityLabel(accessibilityText)
    case .formula(let source, let displayMode, let fontSize):
      applyCardAppearance(
        cornerRadius: displayMode == .inline ? 5 : 10,
        backgroundAlpha: displayMode == .inline ? 0.68 : 0.86
      )
      imageView.isHidden = true
      placeholder.isHidden = true
      formulaLabel.isHidden = false
      formulaLabel.attributedStringValue = MarkdownInlineFormulaPresentation.attributedString(
        for: source,
        fontSize: fontSize
      )
      setAccessibilityElement(true)
      setAccessibilityRole(.staticText)
      setAccessibilityLabel("数学公式")
      setAccessibilityValue(source)
    }
  }

  private func applyCardAppearance(cornerRadius: CGFloat, backgroundAlpha: CGFloat) {
    layer?.cornerRadius = cornerRadius
    layer?.backgroundColor = NSColor.textBackgroundColor
      .withAlphaComponent(backgroundAlpha)
      .cgColor
  }

  func setImage(_ image: NSImage?) {
    imageView.image = image
    placeholder.isHidden = image != nil
  }
}

@MainActor
enum MarkdownInlineFormulaPresentation {
  private static let cache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 128
    return cache
  }()

  static func attributedString(
    for formula: String,
    fontSize: CGFloat = 19
  ) -> NSAttributedString {
    let normalizedFormula = formula.trimmingCharacters(in: .whitespacesAndNewlines)
    let cacheKey = "\(fontSize):\(normalizedFormula)" as NSString
    if let cached = cache.object(forKey: cacheKey) {
      return cached
    }
    let font =
      NSFont(name: "STIX Two Math", size: fontSize)
      ?? NSFont.systemFont(ofSize: fontSize, weight: .medium)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    var renderer = FormulaRenderer(
      source: normalizedFormula,
      baseFont: font
    )
    let rendered = renderer.render()
    let presentationAttributes: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle,
    ]
    rendered.addAttributes(
      presentationAttributes,
      range: NSRange(location: 0, length: rendered.length)
    )
    let immutable = NSAttributedString(attributedString: rendered)
    cache.setObject(immutable, forKey: cacheKey)
    return immutable
  }

  private struct FormulaRenderer {
    private static let commands = [
      "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
      "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π",
      "sigma": "σ", "phi": "φ", "omega": "ω", "times": "×",
      "cdot": "·", "pm": "±", "leq": "≤", "geq": "≥",
      "neq": "≠", "infty": "∞", "sum": "∑", "prod": "∏",
      "int": "∫", "to": "→", "rightarrow": "→", "approx": "≈",
    ]

    let source: String
    let baseFont: NSFont
    private var index: String.Index

    init(source: String, baseFont: NSFont) {
      self.source = source
      self.baseFont = baseFont
      index = source.startIndex
    }

    mutating func render() -> NSMutableAttributedString {
      parseSequence(until: nil)
    }

    private mutating func parseSequence(until terminator: Character?) -> NSMutableAttributedString {
      let result = NSMutableAttributedString()
      while index < source.endIndex {
        let character = source[index]
        if character == terminator {
          index = source.index(after: index)
          break
        }
        switch character {
        case "\\":
          appendCommand(to: result)
        case "^":
          index = source.index(after: index)
          appendScript(to: result, isSuperscript: true)
        case "_":
          index = source.index(after: index)
          appendScript(to: result, isSuperscript: false)
        case "{":
          index = source.index(after: index)
          result.append(parseSequence(until: "}"))
        case "}":
          if terminator == nil {
            append("}", to: result)
            index = source.index(after: index)
          } else {
            return result
          }
        case "\n", "\r":
          append(" ", to: result)
          index = source.index(after: index)
        default:
          append(String(character), to: result)
          index = source.index(after: index)
        }
      }
      return result
    }

    private mutating func appendCommand(to result: NSMutableAttributedString) {
      index = source.index(after: index)
      let commandStart = index
      while index < source.endIndex, source[index].isLetter {
        index = source.index(after: index)
      }
      let command = String(source[commandStart..<index])
      switch command {
      case "frac":
        let numerator = parseRequiredGroup()
        let denominator = parseRequiredGroup()
        applyScriptAttributes(to: numerator, baselineOffset: baseFont.pointSize * 0.34)
        applyScriptAttributes(to: denominator, baselineOffset: -baseFont.pointSize * 0.20)
        result.append(numerator)
        append("⁄", to: result)
        result.append(denominator)
      case "sqrt":
        append("√", to: result)
        result.append(parseRequiredGroup())
      case "text", "mathrm", "mathbf":
        let group = parseRequiredGroup()
        if command == "mathbf", group.length > 0 {
          group.addAttribute(
            .font,
            value: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask),
            range: NSRange(location: 0, length: group.length)
          )
        }
        result.append(group)
      case "quad":
        append("  ", to: result)
      case "qquad":
        append("    ", to: result)
      case ",", ";", ":", "!":
        append(command == "!" ? "" : " ", to: result)
      case "left", "right":
        break
      default:
        if let replacement = Self.commands[command] {
          append(replacement, to: result)
        } else if command.isEmpty, index < source.endIndex {
          append(String(source[index]), to: result)
          index = source.index(after: index)
        } else {
          append("\\\(command)", to: result)
        }
      }
    }

    private mutating func parseRequiredGroup() -> NSMutableAttributedString {
      guard index < source.endIndex, source[index] == "{" else {
        return parseSingleAtom()
      }
      index = source.index(after: index)
      return parseSequence(until: "}")
    }

    private mutating func parseSingleAtom() -> NSMutableAttributedString {
      guard index < source.endIndex else { return NSMutableAttributedString() }
      if source[index] == "\\" {
        let result = NSMutableAttributedString()
        appendCommand(to: result)
        return result
      }
      let result = NSMutableAttributedString()
      append(String(source[index]), to: result)
      index = source.index(after: index)
      return result
    }

    private mutating func appendScript(
      to result: NSMutableAttributedString,
      isSuperscript: Bool
    ) {
      let script = parseRequiredGroup()
      applyScriptAttributes(
        to: script,
        baselineOffset: baseFont.pointSize * (isSuperscript ? 0.38 : -0.18)
      )
      result.append(script)
    }

    private func applyScriptAttributes(
      to value: NSMutableAttributedString,
      baselineOffset: CGFloat
    ) {
      guard value.length > 0 else { return }
      value.addAttributes(
        [
          .font: NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize * 0.72),
          .baselineOffset: baselineOffset,
        ],
        range: NSRange(location: 0, length: value.length)
      )
    }

    private func append(_ string: String, to result: NSMutableAttributedString) {
      guard !string.isEmpty else { return }
      result.append(NSAttributedString(string: string, attributes: [.font: baseFont]))
    }
  }
}

actor MarkdownInlineAttachmentImageCache {
  struct Payload: @unchecked Sendable {
    let image: CGImage
    let decodedByteCount: Int64
  }

  static let defaultDecodedByteBudget: Int64 = 64 * 1_024 * 1_024
  static let defaultMaximumEntryCount = 24
  static let shared = MarkdownInlineAttachmentImageCache()

  private struct Key: Hashable {
    let path: String
    let modificationTime: Int64
    let byteCount: Int
  }

  private struct Entry {
    let payload: Payload
  }

  private let decodedByteBudget: Int64
  private let maximumEntryCount: Int
  private var values: [Key: Entry] = [:]
  private var order: [Key] = []
  private var retainedDecodedByteCount: Int64 = 0

  init(
    decodedByteBudget: Int64 = MarkdownInlineAttachmentImageCache.defaultDecodedByteBudget,
    maximumEntryCount: Int = MarkdownInlineAttachmentImageCache.defaultMaximumEntryCount
  ) {
    self.decodedByteBudget = max(1, decodedByteBudget)
    self.maximumEntryCount = max(1, maximumEntryCount)
  }

  var count: Int {
    values.count
  }

  var cachedDecodedByteCount: Int64 {
    retainedDecodedByteCount
  }

  func image(at sourceURL: URL, maximumPixelSize: Int = 1_024) -> Payload? {
    guard let source = sourceURLAndKey(for: sourceURL) else { return nil }
    if let cached = values[source.key] {
      touch(source.key)
      return cached.payload
    }

    guard let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(64, min(maximumPixelSize, 2_048)),
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
      )
    else { return nil }

    let payload = Payload(
      image: image,
      decodedByteCount: Self.decodedByteCount(for: image)
    )
    guard payload.decodedByteCount <= decodedByteBudget else {
      return payload
    }

    while (retainedDecodedByteCount > decodedByteBudget - payload.decodedByteCount
      || values.count >= maximumEntryCount),
      let evictedKey = order.first {
      removeValue(for: evictedKey)
    }

    values[source.key] = Entry(payload: payload)
    order.append(source.key)
    retainedDecodedByteCount += payload.decodedByteCount
    return payload
  }

  /// Returns whether the source's current version is retained without decoding it.
  /// This is intentionally side-effect free so tests can inspect eviction state.
  func containsCachedImage(at sourceURL: URL) -> Bool {
    guard let source = sourceURLAndKey(for: sourceURL) else { return false }
    return values[source.key] != nil
  }

  private struct SourceURLAndKey {
    let url: URL
    let key: Key
  }

  private func sourceURLAndKey(for sourceURL: URL) -> SourceURLAndKey? {
    let url = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    guard
      let resourceValues = try? url.resourceValues(forKeys: [
        .isRegularFileKey,
        .isReadableKey,
        .contentModificationDateKey,
        .fileSizeKey,
      ]),
      resourceValues.isRegularFile == true,
      resourceValues.isReadable != false,
      let byteCount = resourceValues.fileSize,
      byteCount > 0,
      byteCount <= 64 * 1_024 * 1_024
    else { return nil }

    return SourceURLAndKey(
      url: url,
      key: Key(
        path: url.path,
        modificationTime: Int64(
          (resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000
        ),
        byteCount: byteCount
      )
    )
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func removeValue(for key: Key) {
    guard let removed = values.removeValue(forKey: key) else { return }
    retainedDecodedByteCount = max(
      0,
      retainedDecodedByteCount - removed.payload.decodedByteCount
    )
    order.removeAll { $0 == key }
  }

  private static func decodedByteCount(for image: CGImage) -> Int64 {
    guard
      let bytesPerRow = Int64(exactly: image.bytesPerRow),
      let height = Int64(exactly: image.height),
      bytesPerRow > 0,
      height > 0
    else { return Int64.max }

    let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    return overflow ? Int64.max : max(1, byteCount)
  }
}
