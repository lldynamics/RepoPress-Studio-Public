import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, RepositorySessionSnapshot } from "./contracts/repository";
import type { SitePreviewProps } from "./components/SitePreview";

const harness = vi.hoisted(() => {
  const draft = "---\ntitle: Article\ndraft: true\ndate: 2099-01-02T03:04:05+08:00\n---\n\nBody 中文";
  const repository: RepositorySessionSnapshot = { sessionId: "session-1", rootPath: "/repo", displayName: "Hugo", siteKind: "hugo", contentRoot: "content", isGitRepository: false, warnings: [] };
  const document: DocumentSnapshot = { documentId: "doc-1", relativePath: "content/a.md", text: draft, encoding: "utf-8", lineEnding: "lf", byteSize: new TextEncoder().encode(draft).byteLength, baselineSha256: "sha-1", revision: 1, writable: true, readOnlyReason: null };
  const capabilities = { localEdit: true, markdownPreview: true, gitStatus: false, siteRuntime: false, gitCommit: false, gitPush: false, gitFetch: false, gitIndex: false, remoteAuth: false, aiEditing: false, semanticSearch: false, pdfTextExtraction: false, ocrReadiness: false, knowledgeLibrary: false, contentHealth: false, imageWorkbench: false, operationLog: false, siteProfiles: false };
  const openDocument = vi.fn(async () => document);
  const saveDocument = vi.fn(async (_request: { text: string; expectedSha256: string }) => ({ ...document, revision: document.revision + 1 }));
  const dispatch = vi.fn(); const focus = vi.fn(); const capture = vi.fn();
  const workspace = { lastRepositoryPath: "/repo", lastDocumentPath: "content/a.md", preferences: { restoreLastWorkspace: true } as unknown };
  const gateway = new Proxy({
    getCapabilities: async () => capabilities, getWorkspaceState: async () => ({ ...workspace }), saveRecoveryDraft: async () => ({ ...workspace }),
    openRepository: async () => repository, listMarkdownFiles: async () => [{ relativePath: "content/a.md", displayName: "a.md", directory: "content", byteSize: document.byteSize }], openDocument, saveDocument,
    gitStatus: async () => ({ available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] }),
    inspectSitePreview: async () => ({ siteKind: "hugo", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "", warning: null }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return { document, capabilities, openDocument, saveDocument, dispatch, focus, capture, workspace, gateway };
});

vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/SitePreview", () => ({ SitePreview: (props: SitePreviewProps) => { harness.capture(props); return createElement("div", { "data-testid": "site-preview" }); } }));
vi.mock("./components/MarkdownEditorSurface", () => ({ default: forwardRef(function MockEditor(props: { value: string; onChange: (value: string) => void; onReady?: () => void }, ref) {
  useImperativeHandle(ref, () => ({ view: { state: { doc: { toString: () => props.value, length: props.value.length } }, dispatch: (transaction: { changes?: { from: number; to: number; insert: string }; selection?: unknown }) => {
    harness.dispatch(transaction);
    if (transaction.changes) { const { from, to, insert } = transaction.changes; props.onChange(props.value.slice(0, from) + insert + props.value.slice(to)); }
  }, focus: harness.focus } }));
  useEffect(() => { props.onReady?.(); }, [props.onReady]);
  return createElement("textarea", { "data-testid": "editor", value: props.value, onChange: (event) => props.onChange((event.target as HTMLTextAreaElement).value) });
}) }));

let host: HTMLDivElement; let root: ReturnType<typeof createRoot> | null = null;
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean) { for (let attempt = 0; attempt < 100; attempt += 1) { if (check()) return; await act(async () => { await pause(10); }); } expect(check()).toBe(true); }
function button(label: string) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label) ?? null; }
async function click(node: HTMLElement | null) { if (!node) throw new Error("control not found"); await act(async () => node.click()); }
function editor() { return host.querySelector<HTMLTextAreaElement>("textarea[data-testid='editor']")!; }
async function input(value: string) { await act(async () => { const node = editor(); Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(node, value); node.dispatchEvent(new Event("input", { bubbles: true })); }); }
async function mount(restoreDocument = true) { const { default: App } = await import("./App"); host = document.createElement("div"); document.body.append(host); root = createRoot(host); await act(async () => root!.render(createElement(App))); if (restoreDocument) await until(() => Boolean(host.querySelector("textarea[data-testid='editor']")) && harness.capture.mock.calls.length > 0); }

function preview() { return harness.capture.mock.calls[harness.capture.mock.calls.length - 1][0] as SitePreviewProps; }
describe("App preview context wiring", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, media: "", onchange: null, addEventListener() {}, removeEventListener() {} }));
    harness.openDocument.mockReset().mockResolvedValue(harness.document); harness.capture.mockReset();
    harness.saveDocument.mockReset().mockImplementation(async request => ({ ...harness.document, text: request.text, revision: 2, baselineSha256: "sha-2" }));
  });
  afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });
  it("binds the selected document revision and SHA and labels unsaved content", async () => {
    await mount(); const before = preview();
    expect(before.document).toEqual({ documentId: "doc-1", expectedSha256: "sha-1", revision: 1 });
    expect(before.articlePath).toBeTruthy(); expect(before.unsaved).toBe(false); expect(before.isContextCurrent!(before.contextKey)).toBe(true);
    await input(harness.document.text + " dirty"); const current = preview();
    expect(current.contextKey).not.toBe(before.contextKey); expect(current.unsaved).toBe(true);
    expect(current.document).toEqual(before.document); expect(current.isContextCurrent!(before.contextKey)).toBe(false);
  });
  it("invalidates a captured context immediately even when edits return to identical text in one batch", async () => {
    await mount(); await input(harness.document.text + " dirty"); const before = preview(); const value = editor().value;
    let stillCurrent = true;
    await act(async () => {
      const node = editor(); const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!;
      setter.call(node, value + " changed"); node.dispatchEvent(new Event("input", { bubbles: true }));
      setter.call(node, value); node.dispatchEvent(new Event("input", { bubbles: true }));
      stillCurrent = before.isContextCurrent!(before.contextKey);
    });
    expect(editor().value).toBe(value); expect(stillCurrent).toBe(false);
  });
  it("invalidates a preview while an article open is pending", async () => {
    await mount(); const before = preview(); let finish!: (value: DocumentSnapshot) => void;
    harness.openDocument.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    if (!host.querySelector(".file-button")) await click(host.querySelector(".tree-directory"));
    await click(host.querySelector(".file-button"));
    expect(before.isContextCurrent!(before.contextKey)).toBe(false);
    await act(async () => finish({ ...harness.document, revision: 2 }));
    expect(preview().document?.revision).toBe(2);
  });
  it("uses a new preview identity after Save advances the backend baseline", async () => {
    await mount(); await input(harness.document.text + " saved"); const before = preview();
    await click(button("保存")); await until(() => preview().document?.expectedSha256 === "sha-2");
    const current = preview(); expect(current.document?.revision).toBe(2); expect(current.unsaved).toBe(false);
    expect(current.contextKey).not.toBe(before.contextKey); expect(before.isContextCurrent!(before.contextKey)).toBe(false);
  });
});
