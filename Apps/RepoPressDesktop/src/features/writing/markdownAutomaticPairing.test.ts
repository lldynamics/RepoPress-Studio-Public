import { describe, expect, it } from "vitest";
import { planMarkdownAutomaticPairing } from "./markdownAutomaticPairing";

const pair = (source: string, from: number, to: number, typed: string) => planMarkdownAutomaticPairing(source, { from, to }, typed);

describe("planMarkdownAutomaticPairing", () => {
  it("inserts pairs and places the caret inside", () => {
    expect(pair("", 0, 0, "(")).toEqual({ text: "()", selection: { from: 1, to: 1 } });
    expect(pair("hello", 1, 4, "[")).toEqual({ text: "h[ell]o", selection: { from: 2, to: 5 } });
  });
  it("supports Chinese delimiters and smart quotes", () => {
    expect(pair("", 0, 0, "【")).toEqual({ text: "【】", selection: { from: 1, to: 1 } });
    expect(pair("", 0, 0, "“")).toEqual({ text: "“”", selection: { from: 1, to: 1 } });
  });
  it("skips an existing closing symbol", () => {
    expect(pair(")", 0, 0, ")")).toEqual({ text: ")", selection: { from: 1, to: 1 } });
    expect(pair("`", 0, 0, "`")).toEqual({ text: "`", selection: { from: 1, to: 1 } });
  });
  it("does not pair straight quotes after a word", () => {
    expect(pair("can't", 5, 5, "'")).toBeNull();
    expect(pair("名字", 2, 2, "\"")).toBeNull();
  });
  it("creates empty and selected fences", () => {
    expect(pair("", 0, 0, "```")).toEqual({ text: "```\n\n```", selection: { from: 4, to: 4 } });
    expect(pair("text", 0, 4, "~~~")).toEqual({ text: "~~~\ntext\n~~~", selection: { from: 4, to: 8 } });
  });
  it("keeps UTF-16 offsets next to emoji", () => {
    expect(pair("😀", 2, 2, "(")).toEqual({ text: "😀()", selection: { from: 3, to: 3 } });
  });
  it("leaves front matter to the metadata editor", () => {
    const source = "---\ntitle: Post\n---\n正文";
    expect(pair(source, source.indexOf("Post"), source.indexOf("Post"), "(")).toBeNull();
    expect(pair(source, source.indexOf("正文"), source.length, "（")?.text).toContain("（正文）");
    expect(pair("---\ntitle: Post", 5, 5, "(")).toBeNull();
  });
  it("rejects invalid ranges and unsupported input", () => {
    expect(pair("x", -1, 0, "(")).toBeNull();
    expect(pair("x", 0, 0, "abc")).toBeNull();
    expect(pair("x", 0, 0, "\n")).toBeNull();
    expect(pair("x", 0, 0, "@")).toBeNull();
  });
});
