import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { ImageReferenceFinding } from "../contracts/imageReferences";

const finding = vi.hoisted<ImageReferenceFinding>(() => ({ id: "repair", documentPath: "content/a.md", line: 4, offset: 0, alt: "alt", target: "broken.png", resolvedPath: "content/broken.png", status: "unverified", source: "editor", repairTarget: { from: 0, to: 0, expectedText: "broken.png" } }));
vi.mock("./ImageReferenceCheckPanel", async () => {
  const React = await import("react");
  return { ImageReferenceCheckPanel: ({ repairEnabled, onRepair }: { repairEnabled?: boolean; onRepair?: (item: ImageReferenceFinding) => void }) => repairEnabled ? React.createElement("button", { type: "button", onClick: () => onRepair?.(finding) }, "打开单引用修复") : null };
});
import { ImageWorkbench } from "./ImageWorkbench";

let root: Root | null = null;
let host: HTMLDivElement | null = null;
const repository: RepositorySessionSnapshot = { sessionId: "session-a", rootPath: "/repo", displayName: "repo", siteKind: "hugo", contentRoot: "content", isGitRepository: false, warnings: [] };
const pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const pngBytes = Uint8Array.from(atob(pngBase64), (char) => char.charCodeAt(0));
const image = { relativePath: "static/images/替换 (1).png", fileName: "替换.png", byteSize: pngBytes.byteLength, mimeType: "image/png", width: 1, height: 1, sha256: "" };
const snapshot = { images: [image], scannedEntries: 1, scannedBytes: image.byteSize, omittedFiles: 0, truncated: false, warnings: [] };
async function digest(bytes: Uint8Array) { const result = await crypto.subtle.digest("SHA-256", bytes); return [...new Uint8Array(result)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
async function click(label: string) { const button = [...host!.querySelectorAll("button")].find((item) => item.textContent?.includes(label)); expect(button).toBeTruthy(); await act(async () => { button!.click(); await Promise.resolve(); }); }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
function mount(source: string, gateway: RepositoryGateway, onRepair = vi.fn().mockReturnValue(true)) {
  const target = "broken.png"; const start = source.indexOf(target, source.indexOf("![alt]")); finding.repairTarget = { from: start, to: start + target.length, expectedText: target };
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  act(() => root!.render(createElement(ImageWorkbench, { open: true, onClose: vi.fn(), gateway, repository, enabled: true, canInsert: true, onInsert: vi.fn().mockResolvedValue(true), referenceCheckEnabled: true, referenceOverlay: { relativePath: "content/a.md", text: source }, referenceDocumentKey: "session-a:a:1", onRepair })));
  return onRepair;
}
beforeAll(async () => { (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true; image.sha256 = await digest(pngBytes); });
afterEach(() => { if (root) act(() => root!.unmount()); root = null; host?.remove(); host = null; vi.restoreAllMocks(); });

describe("ImageWorkbench single-reference repair", () => {
  it("revalidates the selected image and changes only the selected inline target", async () => {
    const source = "---\ncover: broken.png\n---\n![alt](broken.png \"title\")\n![again](broken.png)";
    const read = vi.fn().mockResolvedValue({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: image.sha256 });
    const onRepair = mount(source, { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: read } as unknown as RepositoryGateway);
    await click("扫描图片"); await click("打开单引用修复"); await click("替换.png");
    await vi.waitFor(async () => { await act(async () => { await Promise.resolve(); }); expect(host!.querySelector("img")).toBeTruthy(); });
    expect(host!.textContent).toContain("替换前目标broken.png");
    expect(host!.textContent).toContain("替换后目标/images/%E6%9B%BF%E6%8D%A2%20%281%29.png");
    await click("确认验证并应用此预览");
    await vi.waitFor(async () => { await act(async () => { await Promise.resolve(); }); expect(onRepair).toHaveBeenCalledTimes(1); });
    expect(read).toHaveBeenCalledTimes(2);
    expect(onRepair).toHaveBeenCalledWith(expect.objectContaining({
      documentKey: "session-a:a:1", relativePath: "content/a.md", expectedText: source,
      nextText: "---\ncover: broken.png\n---\n![alt](/images/%E6%9B%BF%E6%8D%A2%20%281%29.png \"title\")\n![again](broken.png)",
    }));
  });

  it("refuses a changed image response before the editor callback", async () => {
    const source = "![alt](broken.png)";
    const read = vi.fn().mockResolvedValueOnce({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: image.sha256 }).mockResolvedValueOnce({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: "0".repeat(64) });
    const onRepair = mount(source, { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: read } as unknown as RepositoryGateway);
    await click("扫描图片"); await click("打开单引用修复"); await click("替换.png");
    await vi.waitFor(async () => { await act(async () => { await Promise.resolve(); }); expect(host!.querySelector("img")).toBeTruthy(); });
    await click("确认验证并应用此预览");
    expect(onRepair).not.toHaveBeenCalled(); expect(host!.textContent).toContain("预览响应与所选图片不匹配");
  });

  it("cancels a pending repair when the editor context changes and unlocks scanning", async () => {
    const source = "![alt](broken.png)";
    const pending = deferred<{ relativePath: string; mimeType: string; dataBase64: string; sha256: string }>();
    const read = vi.fn().mockResolvedValueOnce({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: image.sha256 }).mockReturnValueOnce(pending.promise);
    const gateway = { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: read } as unknown as RepositoryGateway;
    const onRepair = mount(source, gateway);
    await click("扫描图片"); await click("打开单引用修复"); await click("替换.png");
    await vi.waitFor(async () => { await act(async () => { await Promise.resolve(); }); expect(host!.querySelector("img")).toBeTruthy(); });
    await click("确认验证并应用此预览");
    await vi.waitFor(() => expect(read).toHaveBeenCalledTimes(2));
    act(() => root!.render(createElement(ImageWorkbench, { open: true, onClose: vi.fn(), gateway, repository, enabled: true, canInsert: false, onInsert: vi.fn().mockResolvedValue(true), referenceCheckEnabled: true, referenceOverlay: { relativePath: "content/a.md", text: `${source}\nchanged` }, referenceDocumentKey: "session-a:a:2", onRepair })));
    expect((([...host!.querySelectorAll("button")].find((button) => button.textContent === "重新扫描")) as HTMLButtonElement).disabled).toBe(false);
    pending.resolve({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: image.sha256 });
    await act(async () => { await pending.promise; await Promise.resolve(); });
    expect(onRepair).not.toHaveBeenCalled();
  });
});
