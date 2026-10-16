import { describe, expect, it } from "vitest";
import { insertRepositoryImage, repositoryImageMarkdownPath } from "./repositoryImages";

describe("repository image reuse", () => {
  it.each([
    ["hugo", "static/images/a.png", "/images/a.png"],
    ["zola", "static/cover.png", "/cover.png"],
    ["astro", "public/images/a.webp", "/images/a.webp"],
    ["nextjs", "public/images/a.webp", "/images/a.webp"],
    ["vitepress", "docs/public/images/a.png", "/images/a.png"],
    ["hexo", "source/images/a.png", "/images/a.png"],
    ["jekyll", "assets/images/a.png", "/assets/images/a.png"],
    ["quartz", "content/attachments/a.png", "/attachments/a.png"],
    ["foam", "attachments/a.png", "/attachments/a.png"],
  ])("maps %s public images consistently with native imports", (siteKind, image, expected) => {
    expect(repositoryImageMarkdownPath(image, { siteKind, contentRoot: null }, "content/article.md")).toBe(expected);
  });

  it("keeps page-local and other repository assets relative to the article", () => {
    expect(repositoryImageMarkdownPath("content/posts/cover.png", { siteKind: "hugo", contentRoot: "content" }, "content/posts/article.md")).toBe("./cover.png");
    expect(repositoryImageMarkdownPath("media/a.png", { siteKind: "markdown", contentRoot: null }, "docs/posts/article.md")).toBe("../../media/a.png");
    expect(repositoryImageMarkdownPath("source/images/a.png", { siteKind: "jekyll-or-hexo", contentRoot: "source/_posts" }, "source/_posts/article.md")).toBe("/images/a.png");
  });

  it("encodes Unicode, punctuation, percent signs and URL delimiters exactly once", () => {
    expect(repositoryImageMarkdownPath("static/images/封面 (1)#a?b%20.png", { siteKind: "hugo", contentRoot: "content" }, "content/a.md"))
      .toBe("/images/%E5%B0%81%E9%9D%A2%20%281%29%23a%3Fb%2520.png");
    expect(repositoryImageMarkdownPath("https:evil.png", { siteKind: "markdown", contentRoot: null }, "a.md")).toBe("./https%3Aevil.png");
  });

  it.each(["/tmp/a.png", "../a.png", "static/../a.png", "static//a.png", "static/./a.png", ".git/a.png", "static\\a.png", "static/a\n.png"])("rejects unsafe relative path %s", (path) => {
    expect(() => repositoryImageMarkdownPath(path, { siteKind: "hugo", contentRoot: "content" }, "content/a.md")).toThrow();
  });

  it("honors the explicitly entered Alt while replacing only the selection", () => {
    const result = insertRepositoryImage("before OLD after", { from: 7, to: 10 }, "/images/a.png", "新说明 ]\\\n下一行");
    expect(result.text).toBe("before ![新说明 \\]\\\\ 下一行](/images/a.png) after");
    expect(result.text.slice(result.selection.from, result.selection.to)).toBe("新说明 \\]\\\\ 下一行");
    expect(() => insertRepositoryImage("x", { from: 0, to: 2 }, "/a.png", "alt")).toThrow();
  });
});
