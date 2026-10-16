import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { MarkdownFileEntry, MarkdownSearchResult, MarkdownSearchSnapshot } from "../contracts/repository";
import { FileNavigator } from "./FileNavigator";

const files: MarkdownFileEntry[] = [{ relativePath: "docs/readme.md", displayName: "readme.md", directory: "docs", byteSize: 12 }];
const match = (kind: "path" | "content", path = "docs/readme.md"): MarkdownSearchResult => ({
  relativePath: path, displayName: "readme.md", directory: "docs", matchKind: kind, lineNumber: kind === "content" ? 7 : null, snippet: kind === "content" ? "needle in body" : "docs/readme.md",
});
const snapshot = (query: string, result: MarkdownSearchResult): MarkdownSearchSnapshot => ({ query, results: [result], truncated: false });

function inputFor(host: HTMLElement) { return host.querySelector("input.file-search") as HTMLInputElement; }
async function typeQuery(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => { setter.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); });
}

describe("FileNavigator", () => {
  afterEach(() => { vi.useRealTimers(); document.body.innerHTML = ""; });

  it("passes path and content matches with exact metadata and result query", async () => {
    vi.useFakeTimers();
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    const pathMatch = match("path"); const contentMatch = match("content", "posts/hello.md");
    const search = vi.fn(async (_session: string, query: string) => snapshot(query, query === "path" ? pathMatch : contentMatch));
    const onOpenSearchResult = vi.fn();
    await act(async () => { root.render(createElement(FileNavigator, { files, selectedPath: undefined, sessionId: "s1", onOpenFile: vi.fn(), onOpenSearchResult, search })); });
    await typeQuery(inputFor(host), " path "); await act(async () => { vi.advanceTimersByTime(250); await Promise.resolve(); });
    (host.querySelector(".search-results button") as HTMLButtonElement).click();
    expect(onOpenSearchResult).toHaveBeenCalledWith(pathMatch, "path");
    await typeQuery(inputFor(host), "content"); await act(async () => { vi.advanceTimersByTime(250); await Promise.resolve(); });
    (host.querySelector(".search-results button") as HTMLButtonElement).click();
    expect(onOpenSearchResult).toHaveBeenLastCalledWith(contentMatch, "content");
    expect(search).toHaveBeenNthCalledWith(1, "s1", "path", 100); expect(search).toHaveBeenNthCalledWith(2, "s1", "content", 100); root.unmount();
  });

  it("rejects late responses and does not expose results from another query or session", async () => {
    vi.useFakeTimers();
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    let resolveFirst!: (value: MarkdownSearchSnapshot) => void; let resolveSecond!: (value: MarkdownSearchSnapshot) => void;
    const search = vi.fn((_session: string, query: string) => new Promise<MarkdownSearchSnapshot>((resolve) => query === "first" ? (resolveFirst = resolve) : (resolveSecond = resolve)));
    await act(async () => { root.render(createElement(FileNavigator, { files, selectedPath: undefined, sessionId: "s1", onOpenFile: vi.fn(), onOpenSearchResult: vi.fn(), search })); });
    await typeQuery(inputFor(host), "first"); await act(async () => { vi.advanceTimersByTime(250); });
    await typeQuery(inputFor(host), "second"); await act(async () => { vi.advanceTimersByTime(250); });
    await act(async () => { resolveFirst(snapshot("first", match("content"))); await Promise.resolve(); });
    expect(host.textContent).not.toContain("needle in body"); expect(host.querySelector(".search-results button")).toBeNull();
    await act(async () => { resolveSecond(snapshot("second", match("path", "posts/second.md"))); await Promise.resolve(); });
    expect(host.textContent).toContain("posts/second.md");
    await act(async () => { root.render(createElement(FileNavigator, { files, selectedPath: undefined, sessionId: "s2", onOpenFile: vi.fn(), onOpenSearchResult: vi.fn(), search })); });
    expect(host.querySelector(".search-results button")).toBeNull(); root.unmount();
  });

  it("keeps ordinary tree file callbacks unchanged", async () => {
    const onOpenFile = vi.fn(); const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    const rootFile = { ...files[0], relativePath: "readme.md", displayName: "readme.md", directory: "" };
    await act(async () => { root.render(createElement(FileNavigator, { files: [rootFile], selectedPath: undefined, sessionId: undefined, onOpenFile, onOpenSearchResult: vi.fn(), search: vi.fn() })); });
    (host.querySelector("nav.file-tree button") as HTMLButtonElement).click(); expect(onOpenFile).toHaveBeenCalledWith(rootFile); root.unmount();
  });
});
