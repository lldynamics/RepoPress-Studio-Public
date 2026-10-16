import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ImageReferenceFinding } from "../contracts/imageReferences";
import { ImageReferenceRepairPanel } from "./ImageReferenceRepairPanel";

let root: Root | null = null;
let host: HTMLDivElement | null = null;
const image = { relativePath: "static/替换 (1).png", fileName: "替换", byteSize: 1, mimeType: "image/png", width: 1, height: 1, sha256: "a".repeat(64) };
const finding: ImageReferenceFinding = { id: "one", documentPath: "content/a.md", line: 3, offset: 5, alt: "保留", target: "missing.png", resolvedPath: "content/missing.png", status: "unverified", source: "editor", repairTarget: { from: 12, to: 23, expectedText: "missing.png" } };
function render(overrides: Partial<Parameters<typeof ImageReferenceRepairPanel>[0]> = {}) {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  const props = { finding, images: { images: [image], scannedEntries: 1, scannedBytes: 1, omittedFiles: 0, truncated: false, warnings: [] }, selectedImagePath: null, replacementTarget: null, disabled: false, onSelectImage: vi.fn(), onCancel: vi.fn(), onApply: vi.fn().mockResolvedValue(true), ...overrides };
  act(() => root!.render(createElement(ImageReferenceRepairPanel, props)));
  return props;
}
async function click(label: string) { const button = [...host!.querySelectorAll("button")].find((item) => item.textContent === label); expect(button).toBeTruthy(); await act(async () => { button!.click(); await Promise.resolve(); }); }
afterEach(() => { if (root) act(() => root!.unmount()); root = null; host?.remove(); host = null; });

describe("ImageReferenceRepairPanel", () => {
  it("requires a scanned replacement and submits only that inventory image", async () => {
    const props = render();
    expect(document.activeElement?.textContent).toBe("修复此图片引用");
    await click("确认验证并应用此预览"); expect(props.onApply).not.toHaveBeenCalled();
    const select = host!.querySelector("select") as HTMLSelectElement;
    await act(async () => { select.value = image.relativePath; select.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(props.onSelectImage).toHaveBeenCalledWith(image.relativePath);
    render({ selectedImagePath: image.relativePath, replacementTarget: "/%E6%9B%BF%E6%8D%A2.png", onApply: props.onApply });
    await click("确认验证并应用此预览");
    expect(props.onApply).toHaveBeenCalledWith(image, "/%E6%9B%BF%E6%8D%A2.png");
  });

  it("surfaces a rejected stale repair and lets the user cancel", async () => {
    const props = render({ selectedImagePath: image.relativePath, replacementTarget: "/%E6%9B%BF%E6%8D%A2.png", onApply: vi.fn().mockResolvedValue(false) });
    await click("确认验证并应用此预览"); expect(host!.textContent).toContain("未应用替换");
    await click("取消"); expect(props.onCancel).toHaveBeenCalledTimes(1);
  });

  it("drops a late rejection after the user has moved to another repair", async () => {
    let resolve!: (value: boolean) => void;
    const pending = new Promise<boolean>((done) => { resolve = done; });
    const props = render({ selectedImagePath: image.relativePath, replacementTarget: "/%E6%9B%BF%E6%8D%A2.png", onApply: vi.fn().mockReturnValue(pending) });
    await click("确认验证并应用此预览");
    const nextFinding = { ...finding, id: "two", target: "other.png", repairTarget: { from: 32, to: 41, expectedText: "other.png" } };
    act(() => root!.render(createElement(ImageReferenceRepairPanel, { ...props, finding: nextFinding, replacementTarget: "/%E5%85%B6%E4%BB%96.png" })));
    await act(async () => { resolve(false); await pending; await Promise.resolve(); });
    expect(host!.textContent).not.toContain("未应用替换");
    expect(host!.textContent).toContain("other.png");
  });
});
