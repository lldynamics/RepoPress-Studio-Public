import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, GeneralDraft, GeneralDraftTransferOperation, GeneralDraftTransferPlan, GeneralDraftTransferResult, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { generalDraftMessages } from "../i18n/generalDraftMessages";
import { GeneralDraftCenter, type GeneralDraftCenterProps } from "./GeneralDraftCenter";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const seconds = 1_700_000_000;
const article: DocumentSnapshot = { documentId: "doc-raw", relativePath: "通用草稿库/{name}.md", text: "<script>raw article</script>", encoding: "utf8", lineEnding: "lf", byteSize: 40, baselineSha256: "original-sha", revision: 3, writable: true, readOnlyReason: null };
const repository = { sessionId: "session-raw", rootPath: "/repo/{name}", contentRoot: "content", displayName: "目标：{name}" } as RepositorySessionSnapshot;
const entry: GeneralDraft = { draftId: "draft-raw", title: "通用草稿库", text: "<script>raw draft {title}</script>", sourceRepositoryName: "目标：{name}", sourceRelativePath: "选择 {title}", createdAtEpochSeconds: seconds, updatedAtEpochSeconds: seconds, byteSize: 40, contentSha256: "draft-sha", revision: 7 };
const movePrompt = "这是移动操作：源内容会被移除，随后可使用本弹层的一次性撤销。确认继续吗？";
const undoPrompt = "撤销上一项转移？如果源或目标已被编辑，撤销会安全地拒绝覆盖。";
function planFixture(operation: GeneralDraftTransferOperation = "copyGeneralToRepository"): GeneralDraftTransferPlan {
  return { planId: "original-plan", operation, canApply: true, expiresAtEpochSeconds: seconds + 600,
    items: [{ draftId: entry.draftId, title: "通用草稿库", sourceLabel: "当前文章", sourceRelativePath: "选择 {title}", targetLabel: "通用草稿", targetRelativePath: "目标：{name}", contentSha256: "draft-sha", revision: 7, conflicts: [] }],
    conflicts: [], warnings: ["通用草稿库", "选择 {title}", "<img src=x onerror=unsafe()>"],
  };
}
function fixture() {
  const plan = planFixture();
  const receipt: GeneralDraftTransferResult = { operation: plan.operation, affectedGeneralDraftIds: [entry.draftId], affectedRelativePaths: ["目标：{name}"], undoId: "original-undo", summary: "计划已生成，请核对后确认执行。" };
  const undone = { restoredGeneralDraftIds: ["restored-raw"], restoredRelativePaths: ["选择 {title}"], summary: "通用草稿已保存。" };
  const methods = {
    listGeneralDrafts: vi.fn(async () => ({ entries: [entry], total: 1, truncated: false })), getGeneralDraft: vi.fn(async () => entry),
    saveGeneralDraft: vi.fn(async () => ({ ...entry, text: "saved raw", revision: 8 })), planGeneralDraftTransfer: vi.fn(async () => plan),
    executeGeneralDraftTransfer: vi.fn(async () => receipt), undoGeneralDraftTransfer: vi.fn(async () => undone),
  };
  const props: GeneralDraftCenterProps = { open: true, onClose: vi.fn(), gateway: methods as unknown as RepositoryGateway, repository, document: article, currentText: article.text, hasUnsavedChanges: false, onTransferApplied: vi.fn() };
  return { methods, props, plan, receipt, undone };
}
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let confirm: ReturnType<typeof vi.spyOn>;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });
async function render(props: GeneralDraftCenterProps, locale: "zh-CN" | "en-US" = "zh-CN") {
  await act(async () => root.render(<I18nProvider locale={locale}><GeneralDraftCenter {...props} /></I18nProvider>)); await settle();
}
function button(label: string) { const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find(item => item.textContent === label); if (!found) throw new Error(`Missing button: ${label}`); return found; }
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
function status() { return host.querySelector('[aria-live="polite"]')?.textContent; }
function alert() { return host.querySelector('[role="alert"]')?.textContent; }
async function change(control: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const prototype = control instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => { Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(control, value); control.dispatchEvent(new Event("input", { bubbles: true })); }); await settle();
}
async function selectDraft() { await act(async () => host.querySelector<HTMLInputElement>('input[type="checkbox"]')!.click()); await settle(); }
function target() { return host.querySelector<HTMLInputElement>('.general-draft-center__paths input')!; }
beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host); confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
  vi.spyOn(window, "requestAnimationFrame").mockImplementation(() => 1); vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => undefined);
});
afterEach(async () => { await act(async () => root.unmount()); host.remove(); vi.restoreAllMocks(); });

describe("GeneralDraftCenter mounted localization", () => {
  it("keeps editing, selection, paths, focus, plans and undo receipts across zh/en/zh with original requests and callbacks", async () => {
    const { methods, props, receipt, undone } = fixture(); await render(props); await selectDraft();
    const textarea = host.querySelector<HTMLTextAreaElement>("textarea")!; const checkbox = host.querySelector<HTMLInputElement>('input[type="checkbox"]')!; const path = target();
    await change(textarea, "edited {title} <b>draft</b>"); await change(path, "content/custom/{name}"); path.focus(); await click("复制所选草稿");
    expect(methods.planGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, operation: "copyGeneralToRepository", documentId: article.documentId, expectedSha256: article.baselineSha256, targetItems: [{ draftId: entry.draftId, relativePath: "content/custom/{name}.md" }] });
    const planNode = host.querySelector('.general-draft-center__plan'); await render(props, "en-US");
    expect(host.querySelector('.general-draft-center__plan')).toBe(planNode); expect(host.querySelector("textarea")).toBe(textarea); expect(textarea.value).toBe("edited {title} <b>draft</b>");
    expect(target()).toBe(path); expect(path.value).toBe("content/custom/{name}"); expect(document.activeElement).toBe(path); expect(checkbox.checked).toBe(true);
    expect(path.getAttribute("aria-label")).toBe("Destination Markdown path for 通用草稿库"); expect(checkbox.getAttribute("aria-label")).toBe("Select 通用草稿库");
    expect(host.textContent).toContain(new Date(seconds * 1000).toLocaleString("en-US")); expect(host.textContent).toContain("Review transfer plan: Copy general drafts to the current repository"); expect(status()).toBe("Plan generated. Review it before confirming execution.");
    await render(props); expect(status()).toBe("计划已生成，请核对后确认执行。"); expect(document.activeElement).toBe(path); await click("确认执行");
    expect(methods.executeGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, planId: "original-plan" }); expect(confirm).not.toHaveBeenCalled();
    expect(vi.mocked(props.onTransferApplied).mock.calls[0][0]).toBe(receipt); await render(props, "en-US"); const undoNode = host.querySelector('.general-draft-center__undo'); expect(status()).toBe(receipt.summary); expect(undoNode?.textContent).toContain(receipt.summary);
    await render(props); expect(host.querySelector('.general-draft-center__undo')).toBe(undoNode); expect(checkbox.checked).toBe(true); expect(path.value).toBe("content/custom/{name}"); expect(textarea.value).toBe("edited {title} <b>draft</b>");
    await click("撤销上一项转移"); expect(confirm).toHaveBeenCalledWith(undoPrompt); expect(methods.undoGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, undoId: "original-undo" });
    expect(vi.mocked(props.onTransferApplied).mock.calls[1][0]).toEqual({ operation: receipt.operation, affectedGeneralDraftIds: undone.restoredGeneralDraftIds, affectedRelativePaths: undone.restoredRelativePaths, undoId: "", summary: undone.summary }); expect(vi.mocked(props.onTransferApplied).mock.calls[1][0].affectedRelativePaths).toBe(undone.restoredRelativePaths);
    await render(props, "en-US"); expect(status()).toBe(undone.summary); expect(methods.listGeneralDrafts).toHaveBeenCalledTimes(3); expect(methods.getGeneralDraft).toHaveBeenCalledTimes(1); expect(methods.saveGeneralDraft).not.toHaveBeenCalled();
  });

  it("renders raw full-key titles, labels, warnings, conflict messages and codes verbatim, with markup as text", async () => {
    const { methods, props, plan } = fixture(); const conflict = { id: "targetPathOccupied", kind: "targetPathOccupied" as const, draftId: entry.draftId, title: "通用草稿库", message: "保存通用草稿失败；内容没有被覆盖。" };
    plan.canApply = false; plan.conflicts = [conflict]; plan.items[0].conflicts = [{ ...conflict, id: "sourceChanged", kind: "sourceChanged", message: "sourceChanged {title}" }];
    await render(props); await selectDraft(); await click("复制所选草稿"); await render(props, "en-US");
    expect(host.querySelector('.general-draft-center__plan li strong')?.textContent).toBe("通用草稿库"); expect(host.querySelector('.general-draft-center__plan li span')?.textContent).toBe("当前文章 / 选择 {title} → 通用草稿 / 目标：{name}"); expect(host.querySelector('.general-draft-center__plan em')?.textContent).toBe("sourceChanged {title}"); expect(host.querySelector('.general-draft-center__conflicts p')?.textContent).toBe(conflict.message);
    expect([...host.querySelectorAll('.general-draft-center__warnings p')].map(item => item.textContent)).toEqual(plan.warnings); expect(host.querySelector('script, img')).toBeNull(); expect(button("Confirm execution").disabled).toBe(true); expect(methods.executeGeneralDraftTransfer).not.toHaveBeenCalled();
  });

  it("interpolates envelopes once and keeps raw brace tokens and literal bodies", async () => {
    const { methods, props } = fixture(); const raw = { ...entry, title: "选择 {title}", sourceRepositoryName: "源：{source}", sourceRelativePath: "目标：{name}" };
    methods.listGeneralDrafts.mockResolvedValue({ entries: [raw], total: 1, truncated: true }); methods.getGeneralDraft.mockResolvedValue(raw); await render(props, "en-US"); await selectDraft();
    expect(host.querySelector('input[type="checkbox"]')?.getAttribute("aria-label")).toBe("Select 选择 {title}"); expect(target().getAttribute("aria-label")).toBe("Destination Markdown path for 选择 {title}"); expect(host.textContent).toContain("Source: 源：{source} / 目标：{name}"); expect(host.textContent).toContain("Destination: 目标：{name}"); expect(host.querySelector('textarea')?.value).toBe(entry.text); expect(status()).toBe("Showing only the 1 most recent general drafts."); await render(props); expect(status()).toBe("仅显示最近 1 篇通用草稿。"); expect(methods.getGeneralDraft).toHaveBeenCalledTimes(1);
  });

  it.each(["moveCurrentToGeneral", "moveGeneralToRepository"] as const)("preserves cancel/accept confirms and payload for %s", async operation => {
    const { methods, props, receipt } = fixture(); methods.planGeneralDraftTransfer.mockResolvedValue(planFixture(operation)); receipt.operation = operation;
    await render(props, "en-US"); if (operation === "moveGeneralToRepository") await selectDraft(); await click(operation === "moveCurrentToGeneral" ? "Move to general drafts" : "Move selected drafts");
    expect(methods.planGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, operation, documentId: article.documentId, expectedSha256: article.baselineSha256, targetItems: operation === "moveCurrentToGeneral" ? undefined : [{ draftId: entry.draftId, relativePath: "content/drafts/通用草稿库.md" }] });
    confirm.mockReturnValueOnce(false); await click("Confirm execution"); expect(confirm).toHaveBeenLastCalledWith(generalDraftMessages[movePrompt]); expect(methods.executeGeneralDraftTransfer).not.toHaveBeenCalled();
    await render(props); await click("确认执行"); expect(confirm).toHaveBeenLastCalledWith(movePrompt); expect(methods.executeGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, planId: "original-plan" });
    await render(props, "en-US"); confirm.mockReturnValueOnce(false); await click("Undo previous transfer"); expect(confirm).toHaveBeenLastCalledWith(generalDraftMessages[undoPrompt]); expect(methods.undoGeneralDraftTransfer).not.toHaveBeenCalled(); await click("Undo previous transfer"); expect(methods.undoGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, undoId: "original-undo" });
  });

  it("keeps pending operations busy across language switches and preserves close guards", async () => {
    const { methods, props, plan, receipt, undone } = fixture(); const pendingPlan = deferred<GeneralDraftTransferPlan>(); const pendingExecute = deferred<GeneralDraftTransferResult>(); const pendingUndo = deferred<typeof undone>();
    methods.planGeneralDraftTransfer.mockReturnValueOnce(pendingPlan.promise); methods.executeGeneralDraftTransfer.mockReturnValueOnce(pendingExecute.promise); methods.undoGeneralDraftTransfer.mockReturnValueOnce(pendingUndo.promise);
    await render(props); await click("复制到通用草稿"); await render(props, "en-US"); expect(status()).toBe("Checking transfer plan…"); expect(button("Close").disabled).toBe(true); expect(host.querySelector('[role="dialog"]')?.getAttribute('aria-busy')).toBe("true");
    await act(async () => { button("Close").click(); host.querySelector('.general-draft-scrim')!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })); host.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); }); expect(props.onClose).not.toHaveBeenCalled(); expect(methods.planGeneralDraftTransfer).toHaveBeenCalledTimes(1);
    await act(async () => pendingPlan.resolve(plan)); await settle(); await click("Confirm execution"); await render(props); expect(status()).toBe("正在执行已核对的转移…"); expect(button("确认执行").disabled).toBe(true);
    await act(async () => pendingExecute.resolve(receipt)); await settle(); await click("撤销上一项转移"); await render(props, "en-US"); expect(status()).toBe("Undoing transfer…"); expect(button("Undo previous transfer").disabled).toBe(true);
    await act(async () => pendingUndo.resolve(undone)); await settle(); await click("Close"); expect(props.onClose).toHaveBeenCalledTimes(1); expect(methods.planGeneralDraftTransfer).toHaveBeenCalledTimes(1); expect(methods.executeGeneralDraftTransfer).toHaveBeenCalledTimes(1); expect(methods.undoGeneralDraftTransfer).toHaveBeenCalledTimes(1);
  });

  it.each(["path", "selection", "text", "document", "repository"])("invalidates a plan only on a real %s context change", async kind => {
    const { methods, props } = fixture(); await render(props); await selectDraft(); await click("复制所选草稿"); await render(props, "en-US"); expect(button("Confirm execution").disabled).toBe(false);
    if (kind === "path") await change(target(), "changed.md"); else if (kind === "selection") await selectDraft(); else if (kind === "text") await render({ ...props, currentText: "changed" }, "en-US"); else if (kind === "document") await render({ ...props, document: { ...article, revision: 4 } }, "en-US"); else await render({ ...props, repository: { ...repository, sessionId: "other-session" } }, "en-US");
    expect(host.querySelector('.general-draft-center__plan')).toBeNull(); expect(status()).toBe("The plan became invalid because the article, selection, paths, or destination repository changed. Generate it again. "); expect(methods.executeGeneralDraftTransfer).not.toHaveBeenCalled(); expect(methods.planGeneralDraftTransfer).toHaveBeenCalledTimes(1);
  });

  it("keeps local cancellation and empty-summary fallbacks bilingual without changing receipts", async () => {
    const { methods, props, receipt, undone } = fixture(); receipt.summary = ""; undone.summary = ""; await render(props); await click("复制到通用草稿"); await click("取消计划"); await render(props, "en-US"); expect(status()).toBe("Pending plan canceled. ");
    await click("Copy to general drafts"); await click("Confirm execution"); expect(status()).toBe("Transfer completed. You can undo it once in this dialog."); expect(host.querySelector('.general-draft-center__undo p')?.textContent).toBe("Completed: Copy general drafts to the current repository."); expect(vi.mocked(props.onTransferApplied).mock.calls[0][0]).toBe(receipt); expect(receipt.summary).toBe("");
    await render(props); expect(status()).toBe("转移已完成，可在本弹层中撤销一次。"); await click("撤销上一项转移"); await render(props, "en-US"); expect(status()).toBe("Previous transfer undone."); expect(methods.executeGeneralDraftTransfer).toHaveBeenCalledTimes(1); expect(vi.mocked(props.onTransferApplied).mock.calls[1][0].summary).toBe("");
  });

  it.each(["无法读取通用草稿库。", "选择 {title}", "", "<script>raw</script>"])("keeps Error.message %j verbatim, with no empty alert", async message => {
    const { methods, props } = fixture(); methods.listGeneralDrafts.mockRejectedValue(new Error(message)); await render(props, "en-US"); expect(alert()).toBe(message || undefined); expect(host.querySelector('script')).toBeNull(); await render(props); expect(alert()).toBe(message || undefined); expect(methods.listGeneralDrafts).toHaveBeenCalledTimes(1);
  });

  it.each([["list", "无法读取通用草稿库。"], ["detail", "无法读取通用草稿。"], ["save", "保存通用草稿失败；内容没有被覆盖。"], ["plan", "无法生成转移计划。"], ["execute", "转移未完成；已保留当前界面。"], ["undo", "撤销失败；为了避免覆盖新内容，未修改当前草稿。"]])("translates the controlled %s fallback at render time", async (stage, fallback) => {
    const { methods, props } = fixture();
    if (stage === "list") methods.listGeneralDrafts.mockRejectedValue(null); if (stage === "detail") methods.getGeneralDraft.mockRejectedValue(null); if (stage === "save") methods.saveGeneralDraft.mockRejectedValue(null); if (stage === "plan") methods.planGeneralDraftTransfer.mockRejectedValue(null); if (stage === "execute") methods.executeGeneralDraftTransfer.mockRejectedValue(null); if (stage === "undo") methods.undoGeneralDraftTransfer.mockRejectedValue(null);
    await render(props); if (stage === "save") { await change(host.querySelector<HTMLTextAreaElement>('textarea')!, "changed raw"); await click("保存通用草稿"); } if (["plan", "execute", "undo"].includes(stage)) await click("复制到通用草稿"); if (["execute", "undo"].includes(stage)) await click("确认执行"); if (stage === "undo") await click("撤销上一项转移");
    expect(alert()).toBe(fallback); await render(props, "en-US"); expect(alert()).toBe(generalDraftMessages[fallback]); await render(props); expect(alert()).toBe(fallback); if (stage === "save") expect(methods.saveGeneralDraft).toHaveBeenCalledExactlyOnceWith({ draftId: entry.draftId, text: "changed raw", expectedRevision: entry.revision, expectedSha256: entry.contentSha256 });
  });

  it("keeps save-pending text and focus stable and translates completion without a second write", async () => {
    const { methods, props } = fixture(); const pending = deferred<GeneralDraft>(); methods.saveGeneralDraft.mockReturnValueOnce(pending.promise); await render(props); const textarea = host.querySelector<HTMLTextAreaElement>('textarea')!; await change(textarea, "edited"); textarea.focus(); await click("保存通用草稿");
    await render(props, "en-US"); expect(status()).toBe("Saving general draft…"); expect(textarea.value).toBe("edited"); expect(document.activeElement).toBe(textarea); await act(async () => pending.resolve({ ...entry, text: "edited", revision: 8 })); await settle(); expect(status()).toBe("General draft saved."); await render(props); expect(status()).toBe("通用草稿已保存。"); expect(methods.saveGeneralDraft).toHaveBeenCalledTimes(1); expect(methods.getGeneralDraft).toHaveBeenCalledTimes(1);
  });

  it("preserves dirty/read-only gating and raw reasons, including empty reasons", async () => {
    const { methods, props } = fixture(); for (const reason of ["请切换到可写文章。", "{reason}", "", null]) { await render({ ...props, document: { ...article, writable: false, readOnlyReason: reason } }, "en-US"); expect(host.textContent).toContain(`The current article is read-only: ${reason ?? "Switch to a writable article."}`); expect(button("Copy to general drafts").disabled).toBe(true); expect(button("Move to general drafts").disabled).toBe(true); }
    await render({ ...props, hasUnsavedChanges: true }, "en-US"); expect(host.textContent).toContain("Save the current article first"); expect(button("Copy to general drafts").disabled).toBe(true); await render({ ...props, document: null }, "en-US"); expect(host.textContent).toContain("No article open"); expect(host.textContent).toContain("Open a writable article first."); await render({ ...props, repository: null }, "en-US"); expect(button("Copy to general drafts").disabled).toBe(true); expect(host.textContent).toContain("No destination repository selected"); expect(methods.planGeneralDraftTransfer).not.toHaveBeenCalled(); expect(methods.saveGeneralDraft).not.toHaveBeenCalled();
  });

  it("formats invalid timestamps with the canonical bilingual unknown-time label", async () => {
    const { methods, props } = fixture(); methods.listGeneralDrafts.mockResolvedValue({ entries: [{ ...entry, updatedAtEpochSeconds: NaN }], total: 1, truncated: false }); await render(props); expect(host.textContent).toContain("时间未知 · r7"); await render(props, "en-US"); expect(host.textContent).toContain("Unknown time · r7"); expect(methods.listGeneralDrafts).toHaveBeenCalledTimes(1);
  });

  it("preserves workspace-refresh catch behavior when the later library refresh clears its error", async () => {
    const { methods, props, receipt } = fixture(); vi.mocked(props.onTransferApplied).mockRejectedValue(new Error("raw callback error")); methods.listGeneralDrafts.mockResolvedValueOnce({ entries: [entry], total: 1, truncated: false }).mockRejectedValueOnce(new Error("")); await render(props); await click("复制到通用草稿"); await click("确认执行");
    // loadDrafts clears the callback refresh error, and its empty raw error stays empty.
    expect(alert()).toBeUndefined(); expect(status()).toBe(receipt.summary); expect(props.onTransferApplied).toHaveBeenCalledWith(receipt); await render(props, "en-US"); expect(alert()).toBeUndefined(); expect(host.querySelector('.general-draft-center__undo p')?.textContent).toBe(receipt.summary);
  });
  it.each(["detail", "save", "plan", "execute", "undo"])("keeps raw full-key and brace errors from %s untranslated", async stage => {
    const { methods, props } = fixture(); const message = "无法生成转移计划。";
    if (stage === "detail") methods.getGeneralDraft.mockRejectedValue(new Error(message));
    if (stage === "save") methods.saveGeneralDraft.mockRejectedValue(new Error(message));
    if (stage === "plan") methods.planGeneralDraftTransfer.mockRejectedValue(new Error(message));
    if (stage === "execute") methods.executeGeneralDraftTransfer.mockRejectedValue(new Error(message));
    if (stage === "undo") methods.undoGeneralDraftTransfer.mockRejectedValue(new Error(message));
    await render(props);
    if (stage === "save") { await change(host.querySelector<HTMLTextAreaElement>('textarea')!, "changed"); await click("保存通用草稿"); }
    if (["plan", "execute", "undo"].includes(stage)) await click("复制到通用草稿");
    if (["execute", "undo"].includes(stage)) await click("确认执行");
    if (stage === "undo") await click("撤销上一项转移");
    await render(props, "en-US"); expect(alert()).toBe(message); await render(props); expect(alert()).toBe(message);
  });

  it("keeps brace summaries raw and copies the current article with its original payload", async () => {
    const { methods, props, receipt, undone } = fixture(); receipt.summary = "选择 {title}"; undone.summary = "目标：{name}";
    receipt.operation = "copyCurrentToGeneral"; methods.planGeneralDraftTransfer.mockResolvedValue(planFixture(receipt.operation));
    await render(props, "en-US"); await click("Copy to general drafts");
    expect(methods.planGeneralDraftTransfer).toHaveBeenCalledExactlyOnceWith({ sessionId: repository.sessionId, operation: "copyCurrentToGeneral", documentId: article.documentId, expectedSha256: article.baselineSha256, targetItems: undefined });
    expect(host.querySelector('.general-draft-center__plan h3')?.textContent).toBe("Review transfer plan: Copy current article to general drafts");
    await click("Confirm execution"); expect(status()).toBe(receipt.summary); expect(host.querySelector('.general-draft-center__undo p')?.textContent).toBe(receipt.summary);
    await render(props); expect(status()).toBe(receipt.summary); await click("撤销上一项转移"); await render(props, "en-US"); expect(status()).toBe(undone.summary);
    expect(vi.mocked(props.onTransferApplied).mock.calls[0][0]).toBe(receipt); expect(vi.mocked(props.onTransferApplied).mock.calls[1][0].summary).toBe(undone.summary);
  });

  it("translates the loading and empty branches without rereading on language changes", async () => {
    const { methods, props } = fixture(); const pending = deferred<{ entries: GeneralDraft[]; total: number; truncated: boolean }>();
    methods.listGeneralDrafts.mockReturnValueOnce(pending.promise); await render(props); expect(host.textContent).toContain("正在读取通用草稿库…");
    await render(props, "en-US"); expect(host.textContent).toContain("Loading general draft library…"); expect(button("Refresh").disabled).toBe(true);
    await act(async () => pending.resolve({ entries: [], total: 0, truncated: false })); await settle();
    expect(host.textContent).toContain("0 available drafts"); expect(host.textContent).toContain("The general draft library is empty.");
    await render(props); expect(host.textContent).toContain("通用草稿库为空。"); expect(methods.listGeneralDrafts).toHaveBeenCalledTimes(1); expect(methods.getGeneralDraft).not.toHaveBeenCalled();
  });

  it("translates unbound source copy and canonical title while preserving raw empty repository names", async () => {
    const { methods, props } = fixture(); methods.getGeneralDraft.mockResolvedValue({ ...entry, sourceRepositoryName: null, sourceRelativePath: null });
    await render(props, "en-US"); expect(host.querySelector('h2')?.textContent).toBe("General drafts library"); expect(host.textContent).toContain("Not bound to any repository");
    expect(host.querySelector('.general-draft-center__close')?.getAttribute('aria-label')).toBe("Close general draft library");
    await render(props); expect(host.textContent).toContain("不绑定任何仓库"); expect(methods.getGeneralDraft).toHaveBeenCalledTimes(1);
  });

});
