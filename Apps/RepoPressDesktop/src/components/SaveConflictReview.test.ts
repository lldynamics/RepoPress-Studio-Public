import { act, createElement, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES, type SaveConflictReviewSnapshot } from "../features/workspace/saveConflictReview";
import { SaveConflictReview } from "./SaveConflictReview";

let root: Root | null = null;
let host: HTMLDivElement;
let props: ComponentProps<typeof SaveConflictReview>;
const review = (overrides: Partial<SaveConflictReviewSnapshot> = {}): SaveConflictReviewSnapshot => ({ documentKey: "document-1", relativePath: "posts/article.md", baselineText: "loaded", localText: "my unsaved edit", diskText: "changed on disk", diskSha256: "a".repeat(64), ...overrides });
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (error: unknown) => void; const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; }); return { promise, resolve, reject }; }
beforeAll(() => { Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true }); });
afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); });
async function mount(overrides: Partial<typeof props> = {}) { props = { open: true, review: review(), busy: false, error: undefined, onClose: vi.fn(), onReload: vi.fn(), onApply: vi.fn().mockResolvedValue(undefined), ...overrides }; host = document.createElement("div"); document.body.append(host); root = createRoot(host); await rerender({}); }
async function rerender(changes: Partial<typeof props>) { props = { ...props, ...changes }; await act(async () => { root!.render(createElement(SaveConflictReview, props)); }); }
function button(label: string) { const element = [...host.querySelectorAll("button")].find((entry) => entry.textContent === label); if (!element) throw new Error(`Missing button ${label}`); return element; }
async function click(element: HTMLElement) { await act(async () => { element.click(); }); }
async function setMerged(value: string) { const textarea = host.querySelector<HTMLTextAreaElement>("textarea[aria-label='合并稿']"); if (!textarea) throw new Error("Missing merge input"); await act(async () => { Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea, value); textarea.dispatchEvent(new Event("input", { bubbles: true })); }); }
async function requestApply() { await click(button("备份原稿并载入合并稿")); }

describe("SaveConflictReview", () => {
  it("renders all three complete texts as inert text and never executes source HTML", async () => {
    const source = `<img src=x onerror=alert(1)>\n${"内容".repeat(400)}`;
    await mount({ review: review({ baselineText: source, localText: `${source} local`, diskText: `${source} disk` }) });
    expect(host.querySelector("img")).toBeNull();
    expect(host.querySelector("[data-testid='conflict-baseline']")?.textContent).toBe(source);
    expect(host.querySelector("[data-testid='conflict-local']")?.textContent).toBe(`${source} local`);
    expect(host.querySelector("[data-testid='conflict-disk']")?.textContent).toBe(`${source} disk`);
  });

  it("requires the explicit confirmation and cancellation leaves the merge untouched", async () => {
    await mount(); await setMerged("careful merge"); await requestApply();
    expect(props.onApply).not.toHaveBeenCalled();
    await click(button("取消"));
    expect(props.onApply).not.toHaveBeenCalled();
    expect(host.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe("careful merge");
  });

  it("invalidates its draft and confirmation when review identity changes", async () => {
    await mount(); await setMerged("old merge"); await requestApply();
    await rerender({ review: review({ diskText: "a newer disk source", diskSha256: "b".repeat(64), localText: "new local source" }) });
    expect(host.querySelector("[role='alertdialog']")).toBeNull();
    expect(host.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe("new local source");
    expect(props.onApply).not.toHaveBeenCalled();
  });

  it("protects against double submit while the apply callback is pending", async () => {
    const pending = deferred<void>(); const onApply = vi.fn(() => pending.promise); const onClose = vi.fn();
    await mount({ onApply, onClose }); await requestApply();
    await act(async () => { button("确认：备份原稿并载入合并稿").click(); button("确认：备份原稿并载入合并稿").click(); });
    expect(onApply).toHaveBeenCalledTimes(1);
    expect(button("取消").disabled).toBe(true);
    await act(async () => { pending.resolve(); });
    expect(onClose).not.toHaveBeenCalled();
  });

  it("keeps the editable draft and focuses it after apply fails", async () => {
    const pending = deferred<void>(); const onApply = vi.fn(() => pending.promise);
    await mount({ onApply }); await setMerged("keep this merge"); await requestApply(); await click(button("确认：备份原稿并载入合并稿"));
    await act(async () => { pending.reject(new Error("not saved")); });
    const textarea = host.querySelector<HTMLTextAreaElement>("textarea[aria-label='合并稿']")!;
    expect(textarea.value).toBe("keep this merge");
    expect(host.textContent).toContain("not saved");
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
    expect(document.activeElement).toBe(textarea);
  });

  it("renders the exact apply failure message as text and retains the editable draft", async () => {
    const onApply = vi.fn().mockRejectedValue(new Error("磁盘内容再次变化；原稿备份已保留。"));
    await mount({ onApply }); await setMerged("keep this merge"); await requestApply(); await click(button("确认：备份原稿并载入合并稿"));
    expect(host.textContent).toContain("磁盘内容再次变化；原稿备份已保留。");
    expect(host.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe("keep this merge");
  });

  it("shows loading for an initially absent review and offers reload after a read failure", async () => {
    const onReload = vi.fn();
    await mount({ review: null, busy: true, onReload });
    expect(host.textContent).toContain("正在读取冲突内容");
    expect(host.textContent).not.toContain("无法读取冲突内容");
    await rerender({ busy: false, error: "读取磁盘内容失败" });
    expect(host.textContent).toContain("读取磁盘内容失败");
    await click(button("重新读取磁盘内容"));
    expect(onReload).toHaveBeenCalledTimes(1);
  });

  it("requires confirmation before rereading discards an uncommitted merge draft", async () => {
    const onReload = vi.fn();
    await mount({ onReload }); await setMerged("a temporary merge"); await click(button("重新读取磁盘内容"));
    expect(onReload).not.toHaveBeenCalled();
    expect(host.querySelector("[role='alertdialog']")?.textContent).toContain("丢弃尚未载入编辑缓冲区的合并草案");
    await click(button("取消"));
    expect(host.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe("a temporary merge");
    await click(button("重新读取磁盘内容")); await click(button("确认重新读取"));
    expect(onReload).toHaveBeenCalledTimes(1);
    expect(host.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe("my unsaved edit");
  });

  it("rejects an oversized merge before it can be confirmed", async () => {
    await mount(); await setMerged("x".repeat(SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES + 1)); await requestApply();
    expect(host.textContent).toContain("合并稿超过 256 KiB");
    expect(button("确认：备份原稿并载入合并稿").disabled).toBe(true);
    expect(props.onApply).not.toHaveBeenCalled();
  });

  it("rejects oversized source text without rendering a clipped review", async () => {
    await mount({ review: review({ diskText: "x".repeat(SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES + 1) }) });
    expect(host.textContent).toContain("256 KiB");
    expect(host.querySelector("pre, textarea")).toBeNull();
  });
});
