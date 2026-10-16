import { describe, expect, it } from "vitest";
import { safePreviewUrl, siteArticlePreviewUrl } from "./SitePreview";
describe("safePreviewUrl", () => {
  it("only accepts a loopback HTTP URL with a port", () => {
    expect(safePreviewUrl("http://127.0.0.1:1313/")).toBe("http://127.0.0.1:1313/");
    expect(safePreviewUrl("http://localhost:1313/")).toBeNull();
    expect(safePreviewUrl("https://127.0.0.1:1313/")).toBeNull();
    expect(safePreviewUrl("http://127.0.0.1/")).toBeNull();
    expect(safePreviewUrl("http://127.0.0.1:0/")).toBeNull();
  });
});

describe("siteArticlePreviewUrl", () => {
  const previewRoot = "http://127.0.0.1:1313/";

  it("keeps the preview server origin and port for absolute or relative site paths", () => {
    expect(siteArticlePreviewUrl(previewRoot, "/posts/hello/")).toBe("http://127.0.0.1:1313/posts/hello/");
    expect(siteArticlePreviewUrl(previewRoot, "posts/hello/")).toBe("http://127.0.0.1:1313/posts/hello/");
    expect(siteArticlePreviewUrl("http://127.0.0.1:4567/preview/", "posts/hello/")).toBe("http://127.0.0.1:4567/posts/hello/");
  });

  it("encodes Unicode and spaces while dropping document query strings and fragments", () => {
    expect(siteArticlePreviewUrl(previewRoot, "/文章/带 空格/?draft=1#heading"))
      .toBe("http://127.0.0.1:1313/%E6%96%87%E7%AB%A0/%E5%B8%A6%20%E7%A9%BA%E6%A0%BC/");
  });

  it("rejects unsafe preview roots and unsafe article paths", () => {
    expect(siteArticlePreviewUrl("http://localhost:1313/", "/posts/ok/")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, null)).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "https://example.com/post")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "//example.com/post")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "/posts/../private/")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "/posts/%2e%2e/private/")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "/posts/%252e%252e/private/")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "/posts%5Cprivate/")).toBeNull();
    expect(siteArticlePreviewUrl(previewRoot, "/posts/%00private/")).toBeNull();
  });
});
