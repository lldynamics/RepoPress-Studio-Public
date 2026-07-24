import PublishingWorkbenchCore

extension RepositoryTextEncoding {
  var localizedDisplayName: String {
    switch self {
    case .utf8: String(localized: "UTF-8")
    case .utf8WithBOM: String(localized: "UTF-8 BOM")
    case .utf16LittleEndian: String(localized: "UTF-16 LE")
    case .utf16BigEndian: String(localized: "UTF-16 BE")
    }
  }
}

extension RepositoryLineEnding {
  var localizedDisplayName: String {
    switch self {
    case .lf: String(localized: "LF")
    case .crlf: String(localized: "CRLF")
    case .cr: String(localized: "CR")
    }
  }
}

extension HTMLSourceDialect {
  var localizedDisplayName: String {
    switch self {
    case .html: String(localized: "HTML")
    case .liquid: String(localized: "Liquid")
    case .tera: String(localized: "Tera")
    case .goTemplate: String(localized: "Go Template")
    case .astro: String(localized: "Astro")
    }
  }
}
