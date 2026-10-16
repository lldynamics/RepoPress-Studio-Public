import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CapabilitySnapshot, CredentialStatusSnapshot, RepositorySessionSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import { PublishCenter } from "./PublishCenter";

vi.mock("./ReleaseLedgerPanel", () => ({ ReleaseLedgerPanel: () => null }));
vi.mock("./UnpublishImpactPanel", () => ({ UnpublishImpactPanel: () => null }));
vi.mock("./PublishRecordsPanel", () => ({ PublishRecordsPanel: () => null }));
vi.mock("./RemoteReviewRecordsPanel", () => ({ RemoteReviewRecordsPanel: () => null }));
vi.mock("./GitPushRetryPanel", () => ({ GitPushRetryPanel: () => null }));

const capabilities: CapabilitySnapshot = {
  localEdit: true, markdownPreview: true, gitStatus: true, siteRuntime: true,
  gitCommit: true, gitPush: true, gitFetch: true, gitIndex: true, remoteAuth: true,
  aiEditing: true, semanticSearch: true, pdfTextExtraction: true, ocrReadiness: true,
  knowledgeLibrary: true, contentHealth: true, imageWorkbench: true, operationLog: true, siteProfiles: true,
};
const credentialStatus: CredentialStatusSnapshot = {
  storage: "session_only", secretServiceAvailable: false, credentials: [], warning: null,
};
const repository = (sessionId: string): RepositorySessionSnapshot => ({
  sessionId, rootPath: `/repos/${sessionId}`, displayName: sessionId, siteKind: "generic",
  contentRoot: null, isGitRepository: true, warnings: [],
});

type InvokeCall = (name: string, args?: object) => Promise<unknown>;
let host: HTMLDivElement;
let root: Root;
let call: ReturnType<typeof vi.fn<InvokeCall>>;
let gateway: ReturnType<typeof createRepositoryGateway>;

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => { resolve = next; });
  return { promise, resolve };
}

function statusFor(sessionId: string) {
  return {
    available: true, branch: sessionId, upstream: null, ahead: 0, behind: 0, detached: false,
    changedFiles: [{ status: "??", relativePath: `${sessionId}.md`, sourcePath: null }], warnings: [],
  };
}

async function render(open: boolean, sessionId: string) {
  await act(async () => {
    root.render(createElement(I18nProvider, {
      locale: "zh-CN",
      children: createElement(PublishCenter, {
        open, onClose: vi.fn(), repository: repository(sessionId), capabilities, gateway, currentDocument: null,
      }),
    }));
    await Promise.resolve();
    await Promise.resolve();
  });
}

function defaultResponse(name: string, args?: object) {
  if (name === "credential_status") return credentialStatus;
  if (name === "git_status") return statusFor((args as { sessionId: string }).sessionId);
  if (name === "browser_protocol_status") return { configured: true, ready: true, summary: "browser ready", warning: null };
  if (name === "update_readiness") return { configured: true, ready: true, summary: "updater ready", warning: null };
  throw new Error(`Unexpected gateway call: ${name}`);
}

describe("PublishCenter request lifecycle", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
    call = vi.fn(async (name, args) => defaultResponse(name, args));
    gateway = createRepositoryGateway(async <T,>(name: string, args?: object) => await call(name, args) as T);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.restoreAllMocks();
  });

  it("does not read publish state while closed, including across session switches", async () => {
    await render(false, "closed-a");
    await render(false, "closed-b");
    expect(call).not.toHaveBeenCalled();
    expect(host.textContent).not.toContain("正在读取发布状态");
  });

  it("invalidates a pending read on close and reloads the same session on reopen", async () => {
    const firstCredential = deferred<CredentialStatusSnapshot>();
    let credentialReads = 0;
    call.mockImplementation(async (name, args) => {
      if (name === "credential_status") {
        credentialReads += 1;
        if (credentialReads === 1) return firstCredential.promise;
      }
      return defaultResponse(name, args);
    });

    await render(true, "same-session");
    expect(host.textContent).toContain("正在读取发布状态");
    await render(false, "same-session");
    expect(host.textContent).not.toContain("正在读取发布状态");
    await act(async () => {
      firstCredential.resolve(credentialStatus);
      await Promise.resolve();
      await Promise.resolve();
    });

    await render(true, "same-session");
    expect(credentialReads).toBe(2);
    expect(host.textContent).toContain("same-session.md");
    expect(host.textContent).not.toContain("正在读取发布状态");
  });

  it("ignores a previous session result that settles after the new session", async () => {
    const oldCredential = deferred<CredentialStatusSnapshot>();
    call.mockImplementation(async (name, args) => {
      const sessionId = (args as { sessionId?: string } | undefined)?.sessionId;
      if (name === "credential_status" && sessionId === "old-session") return oldCredential.promise;
      return defaultResponse(name, args);
    });

    await render(true, "old-session");
    await render(true, "new-session");
    expect(host.textContent).toContain("new-session.md");
    expect(host.textContent).not.toContain("old-session.md");

    await act(async () => {
      oldCredential.resolve(credentialStatus);
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(host.textContent).toContain("new-session.md");
    expect(host.textContent).not.toContain("old-session.md");
  });
});
