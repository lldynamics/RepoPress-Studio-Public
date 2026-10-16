import { act, createElement, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { MetadataBatchRequest, MetadataBatchPlan } from "../contracts/metadataBatch";
import { MetadataBatchCenter } from "./MetadataBatchCenter";

const files = ["a.md", "b.md"].map((relativePath) => ({ relativePath, displayName: relativePath, directory: "", byteSize: 1 }));
let root: Root | null = null; let host: HTMLDivElement; let props: ComponentProps<typeof MetadataBatchCenter>; let sequence = 0;
function preview(request: MetadataBatchRequest): MetadataBatchPlan { return { ...request, planId: `p${++sequence}`, previews: request.paths.map((relativePath) => ({ relativePath, originalValues: ["old"], proposedValues: ["old", "tech"], status: "change", message: null })), expiresAt: new Date(Date.now() + 300_000).toISOString() }; }
beforeAll(() => { Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true }); });
afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); });
async function mount(overrides: Partial<typeof props> = {}) {
  props = { open: true, onClose: vi.fn(), sessionId: "s1", files, enabled: true, plan: vi.fn(async (request) => preview(request)), execute: vi.fn(async () => ({ results: [], summary: "完成" })), ...overrides };
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  await rerender({});
}
async function rerender(changes: Partial<typeof props>) { props = { ...props, ...changes }; await act(async () => { root!.render(createElement(MetadataBatchCenter, props)); }); }
function button(label: string) { const element = [...host.querySelectorAll("button")].find((b) => b.textContent === label); if (!element) throw new Error(`Missing ${label}`); return element; }
async function click(element: HTMLElement) { await act(async () => { element.click(); }); }
async function setValue(value = "tech") { const input = host.querySelector<HTMLInputElement>("input[placeholder='例如：技术']"); if (!input) throw new Error("Missing value input"); await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); }); }
async function select(path = "a.md") { const label = [...host.querySelectorAll(".metadata-batch-files label")].find((l) => l.textContent === path); if (!label) throw new Error(`Missing selectable file ${path}`); await click(label.querySelector("input")!); }
async function prepare() { await select(); await setValue(); await click(button("生成修改预览")); }

describe("MetadataBatchCenter", () => {
  it("previews explicitly, confirms and consumes each plan once", async () => {
    await mount(); await select(); await setValue(); expect(props.plan).not.toHaveBeenCalled();
    await click(button("生成修改预览")); expect(host.textContent).toContain("old → old、tech");
    vi.spyOn(window, "confirm").mockReturnValue(true); await click(button("确认修改"));
    expect(props.execute).toHaveBeenCalledTimes(1); expect(host.querySelector(".metadata-batch-plan")).toBeNull();
    expect(host.textContent).toContain("完成");
  });
  it("disables demo mode and excludes the actual dirty file label", async () => {
    await mount({ enabled: false }); expect(host.textContent).toContain("当前环境不支持"); expect(host.querySelector("input[type='checkbox']")).toBeNull();
    await rerender({ enabled: true, excludedPath: "a.md" });
    expect([...host.querySelectorAll(".metadata-batch-files label")].map((l) => l.textContent)).toEqual(["b.md"]);
  });
  it("locks all controls and close while planning and rejects a late response after switching session", async () => {
    let finish!: (p: MetadataBatchPlan) => void; let captured!: MetadataBatchRequest;
    await mount({ plan: vi.fn((request: MetadataBatchRequest) => { captured = request; return new Promise<MetadataBatchPlan>((resolve) => { finish = resolve; }); }) });
    await prepare();
    expect([...host.querySelectorAll("fieldset input, fieldset select")].every((n) => n.matches(":disabled"))).toBe(true);
    await click(host.querySelector("button[aria-label='关闭']")!); expect(props.onClose).not.toHaveBeenCalled();
    await rerender({ sessionId: "s2" }); await act(async () => { finish(preview(captured)); });
    expect(host.querySelector(".metadata-batch-plan")).toBeNull(); expect(button("生成修改预览").disabled).toBe(true);
    await select(); await setValue(); expect(button("生成修改预览").disabled).toBe(false);
  });
  it("drops a plan when input or available files change", async () => {
    await mount(); await prepare(); await setValue("different"); expect(host.querySelector(".metadata-batch-plan")).toBeNull();
    await click(button("生成修改预览")); await rerender({ files: [files[1]] });
    expect(host.querySelector(".metadata-batch-plan")).toBeNull(); expect(button("生成修改预览").disabled).toBe(true);
  });
  it("consumes failed execution and can confirm a newly generated plan", async () => {
    const execute = vi.fn().mockRejectedValueOnce(new Error("uncertain")).mockResolvedValueOnce({ results: [], summary: "second succeeded" });
    await mount({ execute }); await prepare(); vi.spyOn(window, "confirm").mockReturnValue(true);
    await click(button("确认修改")); expect(host.textContent).toContain("可能已有部分文章写入");
    expect(host.querySelector(".metadata-batch-plan")).toBeNull(); await click(button("生成修改预览")); await click(button("确认修改"));
    expect(execute).toHaveBeenCalledTimes(2); expect(execute.mock.calls[0][1]).not.toBe(execute.mock.calls[1][1]);
    expect(host.textContent).toContain("second succeeded");
  });
  it("rejects invalid expiry and rechecks the clock at confirmation", async () => {
    await mount({ plan: vi.fn(async (request) => ({ ...preview(request), expiresAt: "invalid" })) }); await prepare();
    expect(button("确认修改").disabled).toBe(true);
    await rerender({ plan: vi.fn(async (request) => preview(request)) }); await click(button("生成修改预览"));
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 400_000); await click(button("确认修改"));
    expect(props.execute).not.toHaveBeenCalled(); expect(host.textContent).toContain("计划已过期");
  });
  it("inerts the App siblings while the drawer is open", async () => {
    await mount(); const background = document.createElement("button"); host.prepend(background);
    await rerender({ open: false }); await rerender({ open: true }); expect(background.inert).toBe(true);
    await rerender({ open: false }); expect(background.inert).toBe(false);
  });
});
