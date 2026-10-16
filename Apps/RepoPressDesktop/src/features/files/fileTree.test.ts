import { describe, expect, it } from "vitest";
import { buildMarkdownFileTree } from "./fileTree";

describe("buildMarkdownFileTree", () => {
  it("creates deterministic directories before files using natural ordering", () => {
    const tree = buildMarkdownFileTree([
      { relativePath: "zeta.md", displayName: "zeta.md", directory: "", byteSize: 1 },
      { relativePath: "docs/chapter10.md", displayName: "chapter10.md", directory: "docs", byteSize: 1 },
      { relativePath: "docs/chapter2.md", displayName: "chapter2.md", directory: "docs", byteSize: 1 },
      { relativePath: "alpha/note.md", displayName: "note.md", directory: "alpha", byteSize: 1 },
      { relativePath: "readme.md", displayName: "readme.md", directory: "", byteSize: 1 },
    ]);
    expect(tree.map((node) => node.kind === "directory" ? node.name : node.file.displayName)).toEqual(["alpha", "docs", "readme.md", "zeta.md"]);
    const docs = tree[1];
    expect(docs.kind === "directory" && docs.children.map((node) => node.kind === "file" ? node.file.displayName : node.name)).toEqual(["chapter2.md", "chapter10.md"]);
  });
});
