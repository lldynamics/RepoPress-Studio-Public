import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ImageReferenceReport } from "../contracts/imageReferences";
import ImageReferenceReportView from "./ImageReferenceReport";

const finding = (id: string, status: "matched" | "unverified" = "matched") => ({ id, documentPath: `docs/${id}.md`, line: 4, offset: 0, alt: id === "empty" ? "" : "alt", target: `<img src="${id}.png">`, resolvedPath: status === "matched" ? `${id}.png` : null, status, source: "disk" as const });
const report: ImageReferenceReport = { references: [finding("one"), finding("empty"), finding("missing", "unverified")], scannedDocuments: 2, omittedDocuments: 0, imageCount: 3, imagesWithoutReferences: ["unused.png"], partial: true, truncated: false, warnings: ["有文章未能扫描"] };

describe("ImageReferenceReportView", () => {
  afterEach(() => { document.body.innerHTML = ""; });
  it("filters with real input and empty-alt checkbox", async () => {
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(ImageReferenceReportView, { report, selectedImagePath: "one.png", onSelectImage: vi.fn() })); });
    expect(host.textContent).toContain("扫描或分析结果不完整");
    expect(host.querySelector("img")).toBeNull();
    const input = host.querySelector("input:not([type='checkbox'])") as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    await act(async () => { setter.call(input, "missing"); input.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(host.textContent).toContain("missing.md");
    await act(async () => { setter.call(input, ""); input.dispatchEvent(new Event("input", { bubbles: true })); });
    const checkbox = host.querySelectorAll("input[type='checkbox']")[0] as HTMLInputElement;
    await act(async () => { checkbox.click(); });
    expect(host.textContent).toContain("empty.md"); expect(host.textContent).not.toContain("one.md"); root.unmount();
  });
  it("paginates, resets page after search, and calls matched selection", async () => {
    const many = { ...report, references: Array.from({ length: 51 }, (_, i) => finding(`item-${i}`)), warnings: [] }; const onSelect = vi.fn();
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(ImageReferenceReportView, { report: many, selectedImagePath: null, onSelectImage: onSelect })); });
    expect(host.textContent).toContain("item-0.png"); expect(host.textContent).not.toContain("item-50.png");
    await act(async () => { (Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "下一页") as HTMLButtonElement).click(); }); expect(host.textContent).toContain("item-50.png");
    const input = host.querySelector("input:not([type='checkbox'])") as HTMLInputElement; const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    await act(async () => { setter.call(input, "item-0"); input.dispatchEvent(new Event("input", { bubbles: true })); }); expect(host.textContent).toContain("第 1/1 页");
    await act(async () => { (Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "查看图片") as HTMLButtonElement).click(); }); expect(onSelect).toHaveBeenCalledWith("item-0.png"); root.unmount();
  });
  it("offers repair only for the current editor's exact inline target", async () => {
    const editable = { ...finding("editable", "unverified"), source: "editor" as const, repairTarget: { from: 8, to: 19, expectedText: "missing.png" } };
    const referenceStyle = { ...finding("reference", "unverified"), source: "editor" as const };
    const onRepair = vi.fn();
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(ImageReferenceReportView, { report: { ...report, references: [editable, referenceStyle] }, selectedImagePath: null, onSelectImage: vi.fn(), repairEnabled: true, onRepair })); });
    const repair = [...host.querySelectorAll("button")].find((button) => button.textContent === "修复此引用");
    expect(repair).toBeTruthy(); await act(async () => { repair!.click(); }); expect(onRepair).toHaveBeenCalledWith(editable);
    root.unmount();
  });
});
