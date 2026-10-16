import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PublishCenter } from "./PublishCenter";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import type { CapabilitySnapshot, RepositorySessionSnapshot } from "../contracts/repository";

const repository: RepositorySessionSnapshot = { sessionId: "impact-session", rootPath: "/repo", displayName: "repo", siteKind: "generic", contentRoot: null, isGitRepository: true, warnings: [] };
const capabilities = { localEdit: true, contentHealth: true } as CapabilitySnapshot;
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let call = vi.fn<(name: string, args?: object) => Promise<unknown>>();
class WorkerMock {
  static instances: WorkerMock[] = [];
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror = null;
  onmessageerror = null;
  postMessage = vi.fn();
  terminate = vi.fn();
  constructor() { WorkerMock.instances.push(this); }
}
function render(open = true, caps = capabilities) {
  const gateway = createRepositoryGateway(async <T>(name: string, args?: object) => await call(name, args) as T);
  act(() => root.render(createElement(PublishCenter, { open, onClose: vi.fn(), repository, capabilities: caps, gateway,
    currentDocument: { relativePath: "post.md", text: "# unsaved target" } })));
}
const panel = () => host.querySelector('[aria-label="文章下线影响审阅"]')!;
describe("PublishCenter unpublish impact integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    WorkerMock.instances = []; vi.stubGlobal("Worker", WorkerMock);
    call = vi.fn(async (name: string) => {
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "list_publish_records" || name === "list_remote_review_records") return [];
      if (name === "inspect_content_health_sources") return { documents: [], totalFiles: 0, scannedFiles: 0, scannedBytes: 0, omittedFiles: 0, truncated: false, omissions: [], warnings: [] };
      return { configured: false, ready: false, summary: "" };
    });
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.unstubAllGlobals(); });

  it("wires explicit read-only scanning to the current session and editor snapshot", async () => {
    await act(async () => render());
    expect(panel()).not.toBeNull();
    expect(call.mock.calls.some(([name]) => name === "inspect_content_health_sources")).toBe(false);
    call.mockClear();
    await act(async () => panel().querySelector("button")!.click());
    expect(call.mock.calls).toEqual([["inspect_content_health_sources", { sessionId: "impact-session" }]]);
    expect(WorkerMock.instances[0].postMessage.mock.calls[0][0].input.target).toEqual({ relativePath: "post.md", text: "# unsaved target" });
    await act(async () => render(false));
    expect(panel()).toBeNull();
    expect(WorkerMock.instances[0].terminate).toHaveBeenCalledTimes(1);
  });

  it.each([false, true])("keeps unsupported or demo environments from reading (demo=%s)", async (demo) => {
    await act(async () => render(true, { ...capabilities, localEdit: !demo, contentHealth: demo }));
    expect(panel().querySelector("button")).toBeNull();
    expect(call.mock.calls.some(([name]) => name === "inspect_content_health_sources")).toBe(false);
    expect(WorkerMock.instances).toHaveLength(0);
  });
});
