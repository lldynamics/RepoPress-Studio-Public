import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot } from "./contracts/repository";
import type { MetadataBatchRequest, MetadataBatchResult } from "./contracts/metadataBatch";

const harness = vi.hoisted(() => {
  const text = '---\ntags: ["old"]\n---\nBody stays';
  const document: DocumentSnapshot = { documentId: "doc-1", relativePath: "article.md", text, encoding: "utf-8", lineEnding: "lf", byteSize: text.length, baselineSha256: "sha", revision: 1, writable: true, readOnlyReason: null };
  const capabilities = { localEdit: true, markdownPreview: true, metadataBatch: true };
  const openDocument = vi.fn(async () => document);
  const saveDocument = vi.fn();
  const planMetadataBatch = vi.fn(async (request: MetadataBatchRequest) => ({ ...request, planId: "plan-1", expiresAt: new Date(Date.now() + 300_000).toISOString(), previews: request.paths.map((relativePath) => ({ relativePath, originalValues: ["old"], proposedValues: ["old", "new"], status: "change", message: null })) }));
  const executeMetadataBatch = vi.fn(async (): Promise<MetadataBatchResult> => ({ results: [{ relativePath: "article.md", status: "applied", message: null }], summary: "更新完成" }));
  const gateway = new Proxy({
    getCapabilities: async () => capabilities,
    getWorkspaceState: async () => ({ lastRepositoryPath: "/repo", lastDocumentPath: "article.md", preferences: { restoreLastWorkspace: true, recoveryEnabled: false } }),
    openRepository: async () => ({ sessionId: "session-1", rootPath: "/repo", displayName: "Repo", siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] }),
    listMarkdownFiles: async () => ["article.md", "other.md"].map((relativePath) => ({ relativePath, displayName: relativePath, directory: "", byteSize: text.length })),
    openDocument, saveDocument, planMetadataBatch, executeMetadataBatch,
    gitStatus: async () => ({ available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] }),
    inspectSitePreview: async () => ({ siteKind: "none", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "", warning: null }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return { document, capabilities, openDocument, saveDocument, planMetadataBatch, executeMetadataBatch, gateway, change: (_value: string) => {} };
});

vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/MarkdownEditorSurface", () => ({ default: forwardRef(function MockEditor(props: { value: string; editable: boolean; onChange: (value: string) => void; onReady?: () => void }, ref) {
  harness.change = props.onChange;
  useImperativeHandle(ref, () => ({ view: { state: { doc: { toString: () => props.value, length: props.value.length } }, dispatch: vi.fn(), focus: vi.fn() } }));
  useEffect(() => { props.onReady?.(); }, [props.onReady]);
  return createElement("textarea", { "data-testid": "editor", value: props.value, readOnly: !props.editable, onChange: (event) => props.onChange((event.target as HTMLTextAreaElement).value) });
}) }));

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot> | null = null;
async function until(check: () => boolean) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (check()) return;
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
  }
  expect(check(), "Required App state did not render").toBe(true);
}
function editor() { const node = host.querySelector<HTMLTextAreaElement>("[data-testid='editor']"); if (!node) throw new Error("Missing editor"); return node; }
function button(label: string) { const node = [...host.querySelectorAll("button")].find((b) => b.textContent === label); if (!node) throw new Error(`Missing ${label}`); return node; }
async function click(node: HTMLElement) { await act(async () => { node.click(); }); }
async function mount() {
  const { default: App } = await import("./App");
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  await act(async () => { root!.render(createElement(App)); });
  await until(() => Boolean(host.querySelector("[data-testid='editor']")));
}
async function openBatch() { await click(button("批量标签与分类")); await until(() => Boolean(host.querySelector(".metadata-batch-files"))); }
async function preview() {
  await openBatch();
  const label = [...host.querySelectorAll(".metadata-batch-files label")].find((l) => l.textContent === "article.md");
  if (!label) throw new Error("Missing article selection"); await click(label.querySelector("input")!);
  const input = host.querySelector<HTMLInputElement>("input[placeholder='例如：技术']"); if (!input) throw new Error("Missing value input");
  await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "new"); input.dispatchEvent(new Event("input", { bubbles: true })); });
  await click(button("生成修改预览")); await until(() => Boolean(host.querySelector(".metadata-batch-plan")));
}

describe("App metadata batch integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, media: "", onchange: null, addEventListener() {}, removeEventListener() {} }));
    harness.capabilities.metadataBatch = true;
    harness.openDocument.mockReset().mockResolvedValue(harness.document);
    harness.saveDocument.mockReset(); harness.planMetadataBatch.mockClear();
    harness.executeMetadataBatch.mockReset().mockResolvedValue({ results: [{ relativePath: "article.md", status: "applied", message: null }], summary: "更新完成" });
    vi.spyOn(window, "confirm").mockReturnValue(true);
  });
  afterEach(async () => { await act(async () => { root?.unmount(); }); root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("disables the entry when the backend lacks the capability", async () => {
    harness.capabilities.metadataBatch = false; await mount(); expect(button("批量标签与分类").disabled).toBe(true);
  });
  it("excludes the dirty current buffer through the real App props", async () => {
    await mount(); await act(async () => { harness.change(`${harness.document.text}\nUnsaved`); }); await openBatch();
    expect([...host.querySelectorAll(".metadata-batch-files label")].map((l) => l.textContent)).toEqual(["other.md"]);
    expect(editor().value).toContain("Unsaved"); expect(harness.executeMetadataBatch).not.toHaveBeenCalled();
  });
  it("locks editing and saving until execution and disk refresh finish", async () => {
    await mount(); await preview();
    let resolve!: (value: MetadataBatchResult) => void;
    harness.executeMetadataBatch.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
    const refreshed = { ...harness.document, documentId: "doc-2", text: '---\ntags: ["old","new"]\n---\nLatest disk body' };
    harness.openDocument.mockResolvedValueOnce(refreshed);
    await click(button("确认修改")); expect(editor().readOnly).toBe(true);
    const primaryNavigation = host.querySelector('[aria-label="主导航"]')!;
    for (const control of primaryNavigation.querySelectorAll<HTMLButtonElement>("button")) {
      expect(control.disabled).toBe(true);
      await click(control);
    }
    expect(host.querySelector('[aria-labelledby="metadata-batch-title"]')).not.toBeNull();
    expect(host.querySelector('[aria-label="RepoPress 编辑工作区"]')).not.toBeNull();
    await act(async () => { harness.change("stale editor write"); window.dispatchEvent(new KeyboardEvent("keydown", { key: "s", ctrlKey: true, bubbles: true })); });
    expect(editor().value).toBe(harness.document.text); expect(harness.saveDocument).not.toHaveBeenCalled();
    await act(async () => { resolve({ results: [{ relativePath: "article.md", status: "applied", message: null }], summary: "更新完成" }); });
    await until(() => editor().value === refreshed.text);
    expect(editor().readOnly).toBe(false); expect(harness.openDocument).toHaveBeenLastCalledWith("session-1", "article.md");
    expect(harness.executeMetadataBatch).toHaveBeenCalledExactlyOnceWith("session-1", "plan-1");
  });
  it("refreshes the affected document even when the execution response fails", async () => {
    await mount(); await preview();
    harness.executeMetadataBatch.mockRejectedValueOnce(new Error("response lost"));
    const refreshed = { ...harness.document, text: '---\ntags: ["old","new"]\n---\nWritten before response loss' };
    harness.openDocument.mockResolvedValueOnce(refreshed);
    await click(button("确认修改")); await until(() => editor().value === refreshed.text);
    expect(host.textContent).toContain("可能已有部分文章写入"); expect(editor().readOnly).toBe(false);
    expect(host.querySelector(".metadata-batch-plan")).toBeNull();
  });
});
