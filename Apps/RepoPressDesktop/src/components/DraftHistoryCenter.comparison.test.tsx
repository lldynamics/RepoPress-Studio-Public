import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, DraftVersion, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { DraftHistoryCenter, type DraftHistoryCenterProps } from "./DraftHistoryCenter";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const ids = ["current", "version:{raw}", "third"];
const source = (id: string, index: number): DraftVersion => ({ versionId: id, relativePath: "content/{path}.md", reason: "beforeSave", createdAtEpochSeconds: 3 - index, byteSize: 50, contentSha256: `${id}-{sha}`, text: index === 0 ? '---\nunknown: "{name}"\n---\nSOURCE' : index === 1 ? '+++\ncustom = "<b>{raw}</b>"\n+++\nTARGET_B' : "TARGET_C" });
const details = new Map(ids.map((id, index) => [id, source(id, index)]));
const versions = { documentId: "doc", relativePath: "content/{path}.md", versions: [...details.values()] };
const repository: RepositorySessionSnapshot = { sessionId: "session", rootPath: "/repo/{path}", displayName: "对比目标", contentRoot: "content", siteKind: "zola", isGitRepository: true, warnings: [] };
const snapshot: DocumentSnapshot = { documentId: "doc", relativePath: "content/{path}.md", text: "---\ntitle: live\n---\nLIVE", baselineSha256: "baseline-{sha}", revision: 1, byteSize: 40, writable: true, readOnlyReason: null, lineEnding: "lf", encoding: "utf8" };
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function fixture() {
  const restored = { ...snapshot, text: "RESTORED" };
  const methods = {
    listDraftVersions: vi.fn(async () => versions), getDraftVersion: vi.fn(async (_session: string, _doc: string, id: string) => details.get(id)!),
    restoreDraftVersion: vi.fn(async () => restored), listRecycledDrafts: vi.fn(async () => ({ entries: [], total: 0, truncated: false })),
  };
  const props: DraftHistoryCenterProps = { open: true, onClose: vi.fn(), gateway: methods as unknown as RepositoryGateway, repository, document: snapshot, currentText: snapshot.text, onRestoreDocument: vi.fn() };
  return { methods, props, restored };
}
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let unmounted: boolean;
async function settle() { await act(async () => { for (let index = 0; index < 4; index += 1) await Promise.resolve(); }); }
async function render(props: DraftHistoryCenterProps, locale: "zh-CN" | "en-US" = "zh-CN") { await act(async () => root.render(<I18nProvider locale={locale}><DraftHistoryCenter {...props} /></I18nProvider>)); await settle(); }
const target = () => host.querySelector<HTMLSelectElement>("select")!;
const text = () => host.querySelector('.draft-version-comparison')?.textContent ?? "";
async function chooseTarget(id: string | null) { await act(async () => { target().value = id === null ? "current" : `version:${id}`; target().dispatchEvent(new Event("change", { bubbles: true })); }); await settle(); }
async function chooseSource(index: number) { await act(async () => host.querySelectorAll<HTMLButtonElement>('[role="option"]')[index].click()); await settle(); }
async function click(label: string) { const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find(value => value.textContent === label)!; await act(async () => button.click()); await settle(); }
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); unmounted = false; vi.spyOn(window, "requestAnimationFrame").mockReturnValue(1); vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => undefined); vi.spyOn(window, "confirm").mockReturnValue(true); });
afterEach(async () => { if (!unmounted) await act(async () => root.unmount()); host.remove(); vi.restoreAllMocks(); });

describe("DraftHistoryCenter comparison targets", () => {
  it.each(["zh-CN", "en-US"] as const)("uses a fixed source, distinct raw IDs and bilingual sections in %s", async locale => {
    const { methods, props } = fixture(); await render(props, locale);
    expect(target().value).toBe("current"); expect([...target().options].map(option => option.value)).toEqual(["current", "version:version:{raw}", "version:third"]);
    expect(text()).toContain("LIVE"); expect(text()).toContain("SOURCE"); await chooseTarget(ids[1]); const node = target(); node.focus(); const calls = methods.getDraftVersion.mock.calls.length;
    expect(text()).toContain("TARGET_B"); expect(text()).toContain('custom = "<b>{raw}</b>"'); expect(host.querySelector("b")).toBeNull();
    expect(methods.getDraftVersion).toHaveBeenLastCalledWith("session", "doc", "version:{raw}");
    await render(props, locale === "en-US" ? "zh-CN" : "en-US"); expect(target()).toBe(node); expect(document.activeElement).toBe(node); expect(node.value).toBe("version:version:{raw}"); expect(methods.getDraftVersion).toHaveBeenCalledTimes(calls);
    await render(props, locale); expect(target()).toBe(node); expect(methods.listDraftVersions).toHaveBeenCalledTimes(1); expect(text()).toContain("SOURCE");
    expect(methods.restoreDraftVersion).not.toHaveBeenCalled();
  });

  it.each(["resolve", "reject"] as const)("ignores a late target %s after switching targets", async outcome => {
    const { methods, props } = fixture(); const first = deferred<DraftVersion>(); const second = deferred<DraftVersion>();
    methods.getDraftVersion.mockImplementation((_session, _doc, id) => id === ids[1] ? first.promise : id === ids[2] ? second.promise : Promise.resolve(details.get(id)!));
    await render(props); await chooseTarget(ids[1]); expect(text()).toBe(""); await chooseTarget(ids[2]); await act(async () => second.resolve({ ...details.get(ids[2])!, text: "FRESH_TARGET" })); await settle();
    if (outcome === "resolve") first.resolve({ ...details.get(ids[1])!, text: "STALE_TARGET" }); else first.reject(new Error("STALE_ERROR")); await settle();
    expect(text()).toContain("FRESH_TARGET"); expect(host.textContent).not.toContain("STALE"); expect(target().value).toBe("version:third"); expect(methods.getDraftVersion).toHaveBeenCalledTimes(3);
  });

  it("binds a pending target response to the source that requested it", async () => {
    const { methods, props } = fixture(); const old = deferred<DraftVersion>(); const fresh = deferred<DraftVersion>(); let reads = 0;
    methods.getDraftVersion.mockImplementation((_session, _doc, id) => id === ids[1] ? (++reads === 1 ? old.promise : fresh.promise) : Promise.resolve(details.get(id)!));
    await render(props); await chooseTarget(ids[1]); await chooseSource(2); expect(text()).toBe(""); expect(reads).toBe(2);
    fresh.resolve({ ...details.get(ids[1])!, text: "FRESH_PAIR" }); await settle(); old.resolve({ ...details.get(ids[1])!, text: "STALE_PAIR" }); await settle();
    expect(text()).toContain("TARGET_C"); expect(text()).toContain("FRESH_PAIR"); expect(text()).not.toContain("STALE_PAIR");
  });

  it("falls back to current synchronously when the target becomes the selected source", async () => {
    const { methods, props } = fixture(); await render(props); await chooseTarget(ids[1]); await chooseSource(1);
    expect(target().value).toBe("current"); expect([...target().options].map(option => option.value)).toContain("version:current"); expect(text()).toContain("LIVE"); expect(text()).toContain("TARGET_B");
    await chooseTarget(ids[0]); expect(target().value).toBe("version:current"); expect(methods.getDraftVersion).toHaveBeenLastCalledWith("session", "doc", "current"); expect(text()).toContain("SOURCE");
  });

  it.each(["document", "session", "tab", "close", "unmount"] as const)("invalidates target detail when changing %s", async kind => {
    const { methods, props } = fixture(); const pending = deferred<DraftVersion>(); methods.getDraftVersion.mockImplementation((_session, _doc, id) => id === ids[1] ? pending.promise : Promise.resolve(details.get(id)!));
    await render(props); await chooseTarget(ids[1]);
    if (kind === "document" || kind === "session") {
      methods.listDraftVersions.mockResolvedValue({ ...versions, versions: [] });
      await render(kind === "document" ? { ...props, document: { ...snapshot, documentId: "other" } } : { ...props, repository: { ...repository, sessionId: "other" } });
      expect(methods.getDraftVersion.mock.calls.filter(call => call[0] === "other" || call[1] === "other")).toHaveLength(0);
    } else if (kind === "tab") await click("回收站"); else if (kind === "close") await render({ ...props, open: false }); else { await act(async () => root.unmount()); unmounted = true; }
    pending.resolve({ ...details.get(ids[1])!, text: "STALE_CONTEXT" }); await settle(); expect(host.textContent).not.toContain("STALE_CONTEXT"); expect(host.querySelector('[role="alert"]')).toBeNull();
    if (kind === "tab") { await click("版本历史"); expect(target().value).toBe("current"); }
    if (kind === "close") { await render(props); expect(target().value).toBe("current"); }
  });

  it.each(["无法读取对比版本。", "{path} {{raw}}", "", null])("keeps target rejection %j provenance and recovers by choosing current", async reason => {
    const { methods, props } = fixture(); methods.getDraftVersion.mockImplementation((_session, _doc, id) => id === ids[1] ? Promise.reject(reason === null ? null : new Error(reason)) : Promise.resolve(details.get(id)!));
    await render(props, "en-US"); await chooseTarget(ids[1]); expect(host.querySelector('[role="alert"]')?.textContent ?? "").toBe(reason === null ? "Unable to read the comparison version." : reason); expect(host.textContent).toContain("Choose another comparison target.");
    const calls = methods.getDraftVersion.mock.calls.length; await render(props); expect(host.querySelector('[role="alert"]')?.textContent ?? "").toBe(reason === null ? "无法读取对比版本。" : reason); expect(methods.getDraftVersion).toHaveBeenCalledTimes(calls);
    await chooseTarget(null); expect(text()).toContain("LIVE"); expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("tracks live edits only for the current target without rereading snapshots", async () => {
    const { methods, props } = fixture(); await render(props); const changed = { ...props, currentText: "NEW_UNSAVED" }; await render(changed); expect(text()).toContain("NEW_UNSAVED");
    await chooseTarget(ids[1]); await render({ ...changed, currentText: "LATER_UNSAVED" }); expect(text()).toContain("TARGET_B"); expect(text()).not.toContain("LATER_UNSAVED");
    await chooseTarget(null); expect(text()).toContain("LATER_UNSAVED"); expect(methods.getDraftVersion).toHaveBeenCalledTimes(2); expect(methods.listDraftVersions).toHaveBeenCalledTimes(1); expect(methods.restoreDraftVersion).not.toHaveBeenCalled();
  });

  it("resets folds between equal-text targets and preserves expansion across language changes without rereading", async () => {
    const { methods, props } = fixture();
    const body = Array.from({ length: 12 }, (_, index) => `same ${index + 1} {raw}`).join("\n");
    methods.getDraftVersion.mockImplementation(async (_session, _doc, id) => ({ ...details.get(id)!, text: body }));
    const same = { ...props, currentText: body };
    await render(same); await chooseTarget(ids[1]); await click("展开全部未变化内容");
    const control = host.querySelector<HTMLButtonElement>('button[aria-expanded]')!;
    control.focus(); const calls = methods.getDraftVersion.mock.calls.length;
    await render(same, "en-US");
    expect(host.querySelector('button[aria-expanded]')).toBe(control); expect(control.getAttribute("aria-expanded")).toBe("true"); expect(document.activeElement).toBe(control);
    expect(methods.getDraftVersion).toHaveBeenCalledTimes(calls);
    const oldTable = host.querySelector('[role="table"]');
    await chooseTarget(null);
    expect(host.querySelector('[role="table"]')).not.toBe(oldTable); expect(host.querySelector('button[aria-expanded]')?.getAttribute("aria-expanded")).toBe("false");
    expect(methods.getDraftVersion).toHaveBeenCalledTimes(calls); expect(methods.restoreDraftVersion).not.toHaveBeenCalled();
  });

  it("resets folds on a live-text change without rereading the version", async () => {
    const { methods, props } = fixture();
    const body = Array.from({ length: 12 }, (_, index) => `same ${index + 1}`).join("\n");
    methods.getDraftVersion.mockImplementation(async (_session, _doc, id) => ({ ...details.get(id)!, text: body }));
    await render({ ...props, currentText: body }); await click("展开全部未变化内容");
    const calls = methods.getDraftVersion.mock.calls.length;
    await render({ ...props, currentText: `${body}\nunsaved` });
    expect(host.querySelector('button[aria-expanded]')?.getAttribute("aria-expanded")).toBe("false"); expect(text()).toContain("unsaved");
    expect(methods.getDraftVersion).toHaveBeenCalledTimes(calls); expect(methods.restoreDraftVersion).not.toHaveBeenCalled();
  });

  it("restores the source with its original SHA/receipt while the target is different and reloads comparison", async () => {
    const { methods, props, restored } = fixture(); const pending = deferred<DocumentSnapshot>(); methods.restoreDraftVersion.mockReturnValue(pending.promise);
    await render(props, "en-US"); await chooseTarget(ids[1]); await click("Restore selected version"); expect(methods.restoreDraftVersion).toHaveBeenCalledExactlyOnceWith("session", "doc", "current", "baseline-{sha}"); expect(target().disabled).toBe(true);
    const calls = methods.getDraftVersion.mock.calls.length; await render(props); expect(methods.getDraftVersion).toHaveBeenCalledTimes(calls); expect(target().value).toBe("version:version:{raw}");
    pending.resolve(restored); await settle(); expect(vi.mocked(props.onRestoreDocument).mock.calls[0][0]).toBe(restored); expect(props.onRestoreDocument).toHaveBeenCalledExactlyOnceWith(restored, "version"); expect(text()).toContain("SOURCE"); expect(text()).toContain("TARGET_B"); expect(target().disabled).toBe(false);
    expect(methods.listDraftVersions).toHaveBeenCalledTimes(2);
  });
});
