import Foundation
import XCTest

@testable import PublishingDomainContracts

final class SitePublishingContractsTests: XCTestCase {
  func testSiteValueTypesKeepStableRawValuesAndIDs() {
    XCTAssertEqual(
      SiteKind.allCases.map(\.rawValue),
      ["zola", "astro", "hugo", "vitePress", "nextJS", "quartz", "foam", "hexo", "jekyll"]
    )
    XCTAssertEqual(SiteKind.allCases.map(\.id), SiteKind.allCases.map(\.rawValue))

    XCTAssertEqual(
      FrontMatterStyle.allCases.map(\.rawValue),
      ["yaml", "toml"]
    )
    XCTAssertEqual(FrontMatterStyle.allCases.map(\.id), FrontMatterStyle.allCases.map(\.rawValue))

    XCTAssertEqual(
      SiteSlugValidationRule.allCases.map(\.rawValue),
      ["lowercaseKebab", "relaxed", "disabled"]
    )
    XCTAssertEqual(
      SiteSlugValidationRule.allCases.map(\.id),
      SiteSlugValidationRule.allCases.map(\.rawValue)
    )
  }

  func testEnumCodableRoundTripsPreserveEveryCase() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for value in SiteKind.allCases {
      XCTAssertEqual(
        try decoder.decode(SiteKind.self, from: encoder.encode(value)),
        value
      )
    }
    for value in FrontMatterStyle.allCases {
      XCTAssertEqual(
        try decoder.decode(FrontMatterStyle.self, from: encoder.encode(value)),
        value
      )
    }
    for value in SiteSlugValidationRule.allCases {
      XCTAssertEqual(
        try decoder.decode(SiteSlugValidationRule.self, from: encoder.encode(value)),
        value
      )
    }
  }

  func testPublishingDefaultsPreserveExistingSiteLayoutsAndValueSemantics() throws {
    let expected = [
      SitePublishingDefaults(
        siteKind: .zola,
        frontMatterStyle: .toml,
        contentRoot: "content",
        assetRoot: "static",
        markdownPathPattern: "content/posts/{year}/{slug}.md",
        imagePathPattern: "static/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
      SitePublishingDefaults(
        siteKind: .astro,
        frontMatterStyle: .yaml,
        contentRoot: "src/content/blog",
        assetRoot: "public",
        markdownPathPattern: "src/content/blog/{slug}.mdx",
        imagePathPattern: "public/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
      SitePublishingDefaults(
        siteKind: .hugo,
        frontMatterStyle: .yaml,
        contentRoot: "content",
        assetRoot: "static",
        markdownPathPattern: "content/posts/{slug}.md",
        imagePathPattern: "static/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
      SitePublishingDefaults(
        siteKind: .vitePress,
        frontMatterStyle: .yaml,
        contentRoot: "docs/posts",
        assetRoot: "docs/public",
        markdownPathPattern: "docs/posts/{slug}.md",
        imagePathPattern: "docs/public/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
      SitePublishingDefaults(
        siteKind: .nextJS,
        frontMatterStyle: .yaml,
        contentRoot: "content/posts",
        assetRoot: "public",
        markdownPathPattern: "content/posts/{slug}.mdx",
        imagePathPattern: "public/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
      SitePublishingDefaults(
        siteKind: .quartz,
        frontMatterStyle: .yaml,
        contentRoot: "content",
        assetRoot: "content",
        markdownPathPattern: "content/{slug}.md",
        imagePathPattern: "content/attachments/{filename}",
        publicImagePathPattern: "/attachments/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .relaxed
      ),
      SitePublishingDefaults(
        siteKind: .foam,
        frontMatterStyle: .yaml,
        contentRoot: ".",
        assetRoot: "attachments",
        markdownPathPattern: "{slug}.md",
        imagePathPattern: "attachments/{filename}",
        publicImagePathPattern: "/attachments/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .relaxed
      ),
      SitePublishingDefaults(
        siteKind: .hexo,
        frontMatterStyle: .yaml,
        contentRoot: "source/_posts",
        assetRoot: "source",
        markdownPathPattern: "source/_posts/{slug}.md",
        imagePathPattern: "source/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
      SitePublishingDefaults(
        siteKind: .jekyll,
        frontMatterStyle: .yaml,
        contentRoot: "_posts",
        assetRoot: "assets",
        markdownPathPattern: "_posts/{year}-{month}-{day}-{slug}.md",
        imagePathPattern: "assets/images/{year}/{filename}",
        publicImagePathPattern: "/assets/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd HH:mm:ss Z",
        includeDraftFlagInFrontMatter: false,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      ),
    ]

    XCTAssertEqual(expected.map(\.siteKind), SiteKind.allCases)

    let copied = expected[0]
    var changed = copied
    changed.contentRoot = "private-content"
    XCTAssertEqual(copied.contentRoot, "content")
    XCTAssertNotEqual(changed, copied)

    let encoded = try JSONEncoder().encode(copied)
    XCTAssertEqual(try JSONDecoder().decode(SitePublishingDefaults.self, from: encoded), copied)
  }
}
