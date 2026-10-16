import { describe, expect, it } from "vitest";
import { planMarkdownLineEdit } from "./markdownAdvancedEditing";

const edit = (text: string, from: number, to: number, command: Parameters<typeof planMarkdownLineEdit>[2]) => planMarkdownLineEdit(text, { from, to }, command);
describe("markdown advanced line editing", () => {
  it("moves and duplicates lines while retaining CRLF", () => {
    const moved = edit("one\r\ntwo\r\nthree", 5, 8, "moveUp");
    expect(moved?.text).toBe("two\r\none\r\nthree"); expect(moved?.selection).toEqual({ from: 0, to: 3 });
    const copied = edit("one\r\ntwo\r\nthree", 0, 3, "duplicateBelow");
    expect(copied?.text).toBe("one\r\none\r\ntwo\r\nthree"); expect(copied?.selection).toEqual({ from: 5, to: 8 });
    expect(edit("one\ntwo", 4, 7, "duplicateBelow")?.text).toBe("one\ntwo\ntwo");
    expect(edit("one\ntwo", 4, 7, "duplicateBelow")?.selection).toEqual({ from: 8, to: 11 });
    expect(edit("one\ntwo", 4, 7, "duplicateAbove")?.text).toBe("one\ntwo\ntwo");
    expect(edit("one\ntwo", 4, 7, "duplicateAbove")?.selection).toEqual({ from: 4, to: 7 });
    expect(edit("one\ntwo", 4, 7, "moveUp")?.text).toBe("two\none");
    expect(edit("one\ntwo", 0, 3, "moveDown")?.text).toBe("two\none");
    expect(edit("one\ntwo\nthree", 0, 3, "moveDown")?.text).toBe("two\none\nthree");
    expect(edit("one\ntwo\nthree\nfour", 4, 13, "moveDown")?.text).toBe("one\nfour\ntwo\nthree");
  });
  it("toggles selected tasks together and preserves non-task lines", () => {
    expect(edit("- [ ] a\nplain\n- [x] c", 0, 17, "toggleTaskCompletion")?.text).toBe("- [x] a\nplain\n- [x] c");
  });
  it("comments, removes common formatting, and deletes lines", () => {
    expect(edit("  hello\n", 0, 7, "toggleComment")?.text).toBe("  <!-- hello -->\n");
    expect(edit("## **hello**\n", 0, 12, "removeFormatting")?.text).toBe("hello\n");
    expect(edit("## **粗体** *斜体* _em_ ~~删~~ `code`\n", 0, 32, "removeFormatting")?.text).toBe("粗体 斜体 em 删 code\n");
    expect(edit("a\nb\n", 2, 3, "deleteLine")?.text).toBe("a\n");
    expect(edit("a\nb", 2, 3, "deleteLine")?.text).toBe("a");
    expect(edit("only", 0, 4, "deleteLine")?.text).toBe("");
  });
  it("rejects front matter and fenced code, including mixed ranges", () => {
    expect(edit("---\ntitle: x\n---\nbody", 0, 3, "deleteLine")).toBeNull();
    expect(edit("before\n```\ninside\n```\nafter", 8, 14, "toggleComment")).toBeNull();
    expect(edit("before\n```\ninside\nafter", 0, 20, "deleteLine")).toBeNull();
    expect(edit("before\n```\ninside\nafter", 0, 6, "deleteLine")?.text).toBe("```\ninside\nafter");
    expect(edit("before\n```\ninside\n```\nafter", 0, 6, "moveDown")).toBeNull();
    expect(edit("before\n```\ninside\n```\nafter", 22, 27, "moveUp")).toBeNull();
  });
});
