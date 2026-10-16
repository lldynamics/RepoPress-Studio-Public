import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot } from "./contracts/repository";
import type { ImageReferenceRepairEdit } from "./contracts/imageReferences";

const harness = vi.hoisted(() => {
  const baseline: DocumentSnapshot = { documentId: "original", relativePath: "article.md", text: "# Baseline\nOriginal", encoding: "utf-8", lineEnding: "lf", byteSize: 19, baselineSha256: "base", revision: 1, writable: true, readOnlyReason: null };
  const disk = { ...baseline, documentId: "disk", text: "# Disk\nExternal", baselineSha256: "disk-sha" };
  const openDocument = vi.fn(); const saveDocument = vi.fn(); const saveGeneralDraft = vi.fn(); const getGeneralDraft = vi.fn();
  const gateway = new Proxy({
    getCapabilities: async () => ({ localEdit: true, markdownPreview: true, imageWorkbench: true }),
    getWorkspaceState: async () => ({ lastRepositoryPath: "/repo", lastDocumentPath: "article.md", preferences: { restoreLastWorkspace: true, recoveryEnabled: false } }),
    openRepository: async () => ({ sessionId: "session", rootPath: "/repo", displayName: "Repo", siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] }),
    listMarkdownFiles: async () => [{ relativePath: "article.md", displayName: "article.md", directory: "", byteSize: 19 }],
    openDocument, saveDocument, saveGeneralDraft, getGeneralDraft,
    gitStatus: async () => ({ available: false, changedFiles: [], warnings: [] }),
    inspectSitePreview: async () => ({ supported: false, runtimeAvailable: false, reason: "" }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return { baseline, disk, gateway, openDocument, saveDocument, saveGeneralDraft, getGeneralDraft, change: (_text: string) => {}, repair: null as null | ((edit: ImageReferenceRepairEdit) => boolean), imageKey: "" };
});
vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/ImageWorkbench", () => ({ default: (props: { open: boolean; referenceDocumentKey: string; onRepair: (edit: ImageReferenceRepairEdit) => boolean }) => {
  harness.imageKey = props.referenceDocumentKey; harness.repair = props.onRepair;
  return props.open ? createElement("div", { "data-testid": "image-workbench" }, "Image workbench") : null;
} }));
vi.mock("./components/MarkdownEditorSurface", () => ({ default: forwardRef(function MockEditor(props: { value: string; editable: boolean; onChange: (value: string) => void; onReady?: () => void }, ref) {
  harness.change = props.onChange;
  useImperativeHandle(ref, () => ({ view: { state: { doc: { toString: () => props.value, length: props.value.length } }, dispatch: (transaction: { changes?: { insert: string } }) => { if (transaction.changes) props.onChange(transaction.changes.insert); }, focus: vi.fn() } }));
  useEffect(() => { props.onReady?.(); }, [props.onReady]);
  return createElement("textarea", { "data-testid": "editor", value: props.value, readOnly: !props.editable, onChange: (event) => props.onChange((event.target as HTMLTextAreaElement).value) });
}) }));

let host: HTMLDivElement; let root: ReturnType<typeof createRoot> | null = null;
async function until(check: () => boolean) {
  for (let n = 0; n < 100; n++) { if (check()) return; await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); }); }
  expect(check(), "App did not reach the expected state").toBe(true);
}
function editor() { return host.querySelector<HTMLTextAreaElement>("[data-testid='editor']")!; }
function button(label: string) { const found = [...host.querySelectorAll("button")].find((node) => node.textContent === label); if (!found) throw new Error(`Missing button ${label}`); return found; }
async function click(label: string) { await act(async () => button(label).click()); }
async function mount() {
  const { default: App } = await import("./App"); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  await act(async () => root!.render(createElement(App))); await until(() => Boolean(editor()));
}
const localText = "# Local\nUnsaved original";
async function conflict() {
  await mount(); await act(async () => harness.change(localText)); await click("保存");
  await until(() => Boolean(host.querySelector("[aria-label='保存冲突']")));
  await click("审阅保存冲突"); await until(() => Boolean(host.querySelector("[data-testid='conflict-disk']")));
}
async function mergeText(text = "# Merged\nBoth changes") {
  const field = host.querySelector<HTMLTextAreaElement>("textarea[aria-label='合并稿']")!;
  await act(async () => { Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(field, text); field.dispatchEvent(new Event("input", { bubbles: true })); });
}
async function apply() { await click("备份原稿并载入合并稿"); await click("确认：备份原稿并载入合并稿"); }

describe("App safety workflow integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} }));
    harness.openDocument.mockReset().mockResolvedValue(harness.disk).mockResolvedValueOnce(harness.baseline);
    harness.saveDocument.mockReset().mockRejectedValue({ code: "save_conflict" });
    harness.saveGeneralDraft.mockReset().mockResolvedValue({ draftId: "backup", text: localText });
    harness.getGeneralDraft.mockReset().mockResolvedValue({ draftId: "backup", text: localText });
    harness.repair = null;
  });
  afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("shows all three versions without replacing the unsaved buffer and cancels unchanged", async () => {
    await conflict();
    expect(host.querySelector("[data-testid='conflict-baseline']")?.textContent).toBe(harness.baseline.text);
    expect(host.querySelector("[data-testid='conflict-local']")?.textContent).toBe(localText);
    expect(host.querySelector("[data-testid='conflict-disk']")?.textContent).toBe(harness.disk.text);
    expect(editor().value).toBe(localText); expect(editor().readOnly).toBe(true);
    await act(async () => host.querySelector<HTMLButtonElement>("[aria-label='关闭保存冲突审阅']")!.click());
    expect(editor().value).toBe(localText); expect(harness.saveGeneralDraft).not.toHaveBeenCalled();
  });
  it("backs up and revalidates before loading a merge; the later save uses the fresh disk baseline", async () => {
    await conflict(); await mergeText(); await apply();
    await until(() => editor().value === "# Merged\nBoth changes");
    expect(harness.saveGeneralDraft).toHaveBeenCalledExactlyOnceWith({ draftId: null, text: localText, expectedRevision: null, expectedSha256: null });
    expect(harness.getGeneralDraft).toHaveBeenCalledWith("backup"); expect(harness.saveDocument).toHaveBeenCalledTimes(1);
    harness.saveDocument.mockResolvedValueOnce({ ...harness.disk, text: editor().value, revision: 2 }); await click("保存");
    expect(harness.saveDocument).toHaveBeenLastCalledWith({ sessionId: "session", documentId: "disk", text: "# Merged\nBoth changes", expectedSha256: "disk-sha" });
  });
  it("does not replace the buffer when the disk changes again before confirmation", async () => {
    await conflict(); await mergeText(); harness.openDocument.mockResolvedValueOnce({ ...harness.disk, text: "Later disk", baselineSha256: "later" });
    await apply(); expect(editor().value).toBe(localText); expect(harness.saveGeneralDraft).not.toHaveBeenCalled();
    expect(host.querySelector<HTMLTextAreaElement>("textarea[aria-label='合并稿']")?.value).toBe("# Merged\nBoth changes");
  });
  it("preserves the original on a backup failure", async () => {
    await conflict(); await mergeText(); harness.saveGeneralDraft.mockRejectedValueOnce(new Error("backup unavailable")); await apply();
    expect(editor().value).toBe(localText); expect(harness.getGeneralDraft).not.toHaveBeenCalled(); expect(harness.saveDocument).toHaveBeenCalledTimes(1);
  });
  it("rejects a backup with different stored text", async () => {
    await conflict(); harness.getGeneralDraft.mockResolvedValueOnce({ draftId: "backup", text: "wrong" }); await apply();
    expect(editor().value).toBe(localText); expect(harness.saveDocument).toHaveBeenCalledTimes(1);
  });
  it("rejects disk drift during backup and retains the backup", async () => {
    await conflict(); harness.openDocument.mockResolvedValueOnce(harness.disk).mockResolvedValueOnce({ ...harness.disk, baselineSha256: "changed" }); await apply();
    expect(editor().value).toBe(localText); expect(harness.saveGeneralDraft).toHaveBeenCalledTimes(1);
  });
  it("blocks late editor writes and shortcuts while the backup is pending", async () => {
    await conflict(); let finish!: (value: unknown) => void;
    harness.saveGeneralDraft.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    await apply(); await act(async () => { harness.change("late edit"); window.dispatchEvent(new KeyboardEvent("keydown", { key: "s", ctrlKey: true, bubbles: true })); });
    expect(editor().value).toBe(localText); expect(harness.saveDocument).toHaveBeenCalledTimes(1);
    await act(async () => finish({ draftId: "backup", text: localText })); await until(() => !host.querySelector("[aria-label='合并稿']"));
  });
  it("shows a disk read failure while keeping the original buffer", async () => {
    await mount(); await act(async () => harness.change(localText)); await click("保存");
    harness.openDocument.mockRejectedValueOnce(new Error("read failed")); await click("审阅保存冲突");
    await until(() => host.textContent!.includes("read failed")); expect(editor().value).toBe(localText); expect(host.querySelector("[data-testid='conflict-disk']")).toBeNull();
  });
  it("accepts image repair only for the matching document and complete buffer", async () => {
    await mount(); await click("图片工作台"); await until(() => Boolean(host.querySelector("[data-testid='image-workbench']")));
    const edit = { documentKey: harness.imageKey, relativePath: "article.md", expectedText: harness.baseline.text, nextText: "# Repaired", selection: { from: 0, to: 0 } };
    let accepted = true; await act(async () => { accepted = harness.repair!({ ...edit, documentKey: "other-doc" }); }); expect(accepted).toBe(false);
    await act(async () => { accepted = harness.repair!(edit); }); expect(accepted).toBe(true); expect(editor().value).toBe("# Repaired");
    await act(async () => { accepted = harness.repair!(edit); }); expect(accepted).toBe(false); expect(harness.saveDocument).not.toHaveBeenCalled();
  });
});
