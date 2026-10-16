import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { ImageWorkbench } from "./ImageWorkbench";

let root: Root | null = null;
let container: HTMLDivElement | null = null;
const repository: RepositorySessionSnapshot = { sessionId: "session-a", rootPath: "/repo", displayName: "repo", siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] };
const pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const pngBytes = Uint8Array.from(atob(pngBase64), (char) => char.charCodeAt(0));
const image = { relativePath: "assets/cover.png", fileName: "cover.png", mimeType: "image/png", sha256: "", byteSize: pngBytes.byteLength, width: 1, height: 1 };
const snapshot = { images: [image], scannedEntries: 1, scannedBytes: 42, omittedFiles: 0, truncated: false, warnings: [] };

beforeAll(() => { (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true; });
afterEach(() => { if (root) act(() => root?.unmount()); root = null; container?.remove(); container = null; vi.restoreAllMocks(); });
function mount(props: Partial<Parameters<typeof ImageWorkbench>[0]> = {}) {
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
  const defaultGateway = { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: vi.fn() } as unknown as RepositoryGateway;
  const gateway = props.gateway ?? defaultGateway;
  act(() => root?.render(createElement(ImageWorkbench, { open: true, onClose: vi.fn(), gateway, repository, enabled: true, canInsert: true, onInsert: vi.fn().mockResolvedValue(true), ...props })));
  return gateway;
}
async function click(label: string) { const button = [...(container?.querySelectorAll("button") ?? [])].find((item) => item.textContent?.includes(label)); expect(button).toBeTruthy(); await act(async () => { (button as HTMLButtonElement).click(); await Promise.resolve(); }); }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
async function sha256(bytes: Uint8Array) { const digest = await crypto.subtle.digest("SHA-256", bytes); return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }

describe("ImageWorkbench", () => {
  beforeAll(async () => { image.sha256 = await sha256(pngBytes); });
  it("waits for explicit scanning and shows partial results", async () => {
    const gateway = mount({ gateway: { inspectRepositoryImages: vi.fn().mockResolvedValue({ ...snapshot, truncated: true, warnings: ["warning"] }) } as unknown as RepositoryGateway });
    expect(gateway.inspectRepositoryImages).not.toHaveBeenCalled(); await click("扫描图片");
    expect(container?.textContent).toContain("cover.png"); expect(container?.textContent).toContain("部分结果");
  });
  it("does not call the gateway when capability is disabled", async () => {
    const gateway = mount({ enabled: false }); expect(gateway.inspectRepositoryImages).not.toHaveBeenCalled(); expect(container?.textContent).toContain("不可用");
  });
  it("filters the bounded list", async () => {
    const gateway = mount({ gateway: { inspectRepositoryImages: vi.fn().mockResolvedValue({ ...snapshot, images: [image, { ...image, relativePath: "docs/other.webp", fileName: "other.webp", mimeType: "image/webp" }] }) } as unknown as RepositoryGateway });
    await click("扫描图片"); const input = container?.querySelector('input[type="search"]') as HTMLInputElement; await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set?.call(input, "other"); input.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(container?.textContent).toContain("other.webp"); expect(container?.textContent).not.toContain("cover.png");
    expect(gateway.inspectRepositoryImages).toHaveBeenCalledWith("session-a");
  });

  it("drops a delayed scan after closing and after changing session", async () => {
    const first = deferred<typeof snapshot>(); const inspect = vi.fn().mockReturnValue(first.promise); const onClose = vi.fn();
    const props = { gateway: { inspectRepositoryImages: inspect, readRepositoryImage: vi.fn() } as unknown as RepositoryGateway, onClose };
    mount(props); await click("扫描图片"); expect(onClose).not.toHaveBeenCalled(); await click("×"); expect(onClose).toHaveBeenCalled();
    first.resolve(snapshot); await act(async () => { await first.promise; }); expect(container?.textContent).not.toContain("cover.png");
    const second = deferred<typeof snapshot>(); const gateway = { inspectRepositoryImages: vi.fn().mockReturnValue(second.promise), readRepositoryImage: vi.fn() } as unknown as RepositoryGateway;
    act(() => root?.render(createElement(ImageWorkbench, { open: true, onClose: vi.fn(), gateway, repository, enabled: true, canInsert: true, onInsert: vi.fn().mockResolvedValue(true) })));
    await click("扫描图片"); act(() => root?.render(createElement(ImageWorkbench, { open: true, onClose: vi.fn(), gateway, repository: { ...repository, sessionId: "session-b" }, enabled: true, canInsert: true, onInsert: vi.fn().mockResolvedValue(true) })));
    second.resolve(snapshot); await act(async () => { await second.promise; }); expect(container?.textContent).not.toContain("cover.png");
  });

  it("rejects mismatched preview path, mime, and sha without creating an image URL", async () => {
    const responses = [
      { relativePath: "wrong.png", mimeType: "image/png", dataBase64: pngBase64, sha256: image.sha256 },
      { relativePath: image.relativePath, mimeType: "text/plain", dataBase64: pngBase64, sha256: image.sha256 },
      { relativePath: image.relativePath, mimeType: "image/png", dataBase64: pngBase64, sha256: "0".repeat(64) },
    ];
    for (const response of responses) {
      const gateway = { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: vi.fn().mockResolvedValue(response) } as unknown as RepositoryGateway;
      mount({ gateway }); await click("扫描图片"); await click("cover.png"); await act(async () => { await Promise.resolve(); await Promise.resolve(); });
      expect(container?.querySelector("img")).toBeNull(); expect(container?.textContent).toContain("预览");
      act(() => root?.unmount()); root = null; container?.remove(); container = null;
    }
  });

  it("loads a verified preview and inserts the edited alt text", async () => {
    const onInsert = vi.fn().mockResolvedValue(true);
    const gateway = { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: vi.fn().mockResolvedValue({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: image.sha256 }) } as unknown as RepositoryGateway;
    mount({ gateway, onInsert }); await click("扫描图片"); await click("cover.png"); await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    await vi.waitFor(async () => { await act(async () => { await Promise.resolve(); }); expect(container?.querySelector("img")).toBeTruthy(); });
    const alt = container?.querySelector('input:not([type="search"])') as HTMLInputElement;
    await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set?.call(alt, "文章封面"); alt.dispatchEvent(new Event("input", { bubbles: true })); });
    await click("插入当前文章");
    expect(onInsert).toHaveBeenCalledWith(expect.objectContaining({ relativePath: image.relativePath }), "文章封面");
  });

  it("keeps selection stable while insertion is pending and unlocks after failure", async () => {
    const pending = deferred<boolean>();
    const gateway = { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: vi.fn().mockResolvedValue({ ...image, dataBase64: pngBase64 }) } as unknown as RepositoryGateway;
    mount({ gateway, onInsert: vi.fn().mockReturnValue(pending.promise) });
    await click("扫描图片"); await click("cover.png");
    await vi.waitFor(async () => { await act(async () => { await Promise.resolve(); }); expect(container?.querySelector("img")).toBeTruthy(); });
    await click("插入当前文章");
    expect(container?.querySelector<HTMLButtonElement>(".image-workbench-list button")?.disabled).toBe(true);
    expect(container?.querySelector<HTMLInputElement>('.image-workbench-detail input')?.disabled).toBe(true);
    await act(async () => { pending.resolve(false); await pending.promise; });
    expect(container?.querySelector<HTMLButtonElement>(".image-workbench-list button")?.disabled).toBe(false);
    expect(container?.textContent).toContain("文章没有改变");
  });

  it("allows browsing without a document and Escape while scanning", async () => {
    const pending = deferred<typeof snapshot>(); const onClose = vi.fn();
    const gateway = { inspectRepositoryImages: vi.fn().mockReturnValue(pending.promise), readRepositoryImage: vi.fn() } as unknown as RepositoryGateway;
    mount({ gateway, onClose, canInsert: false }); await click("扫描图片");
    act(() => container?.querySelector('[role="dialog"]')?.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => { pending.resolve(snapshot); await pending.promise; });
    expect(container?.textContent).not.toContain("cover.png");
  });

  it("drops a delayed preview after closing", async () => {
    const preview = deferred<{ relativePath: string; mimeType: string; dataBase64: string; sha256: string }>();
    const gateway = { inspectRepositoryImages: vi.fn().mockResolvedValue(snapshot), readRepositoryImage: vi.fn().mockReturnValue(preview.promise) } as unknown as RepositoryGateway;
    const onClose = vi.fn(); mount({ gateway, onClose }); await click("扫描图片"); await click("cover.png"); expect(gateway.readRepositoryImage).toHaveBeenCalled(); await click("×");
    preview.resolve({ relativePath: image.relativePath, mimeType: image.mimeType, dataBase64: pngBase64, sha256: image.sha256 }); await act(async () => { await preview.promise; await Promise.resolve(); });
    expect(onClose).toHaveBeenCalled(); expect(container?.querySelector("img")).toBeNull();
  });
});
