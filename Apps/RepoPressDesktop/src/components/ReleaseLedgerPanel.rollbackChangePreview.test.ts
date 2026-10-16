import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerGateway, ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import type { RollbackChangePreview, RollbackChangePreviewGateway } from "../contracts/rollbackChangePreview";
import { ReleaseLedgerPanel } from "./ReleaseLedgerPanel";

const pushEntry: ReleaseLedgerSnapshot["entries"][number] = {
  source: "gitPush" as const,
  recordId: "push-1",
  revision: 3,
  operation: "push" as const,
  branch: "main",
  targetBranch: null,
  expectedSha: "a".repeat(40),
  remoteUrl: "https://example.test/repo.git",
  startedAtEpochMs: 1_700_000_000_000,
  checkedAtEpochMs: 1_700_000_100_000,
  status: "pushVerified" as const,
};

const snapshot = (sessionId = "session-1", entry: ReleaseLedgerSnapshot["entries"][number] = pushEntry): ReleaseLedgerSnapshot => ({
  sessionId,
  entries: [entry],
  partialSources: [],
  warnings: [],
  summary: { total: 1, verifiedPushes: entry.source === "gitPush" && entry.status === "pushVerified" ? 1 : 0, verifiedReviews: entry.source === "remoteReview" && entry.status === "reviewVerified" ? 1 : 0, needsAttention: 0 },
});

const side = (objectId: string, byteSize: number | null = 12) => ({ mode: "100644", objectId, byteSize });
const preview = (sessionId = "session-1", status: RollbackChangePreview["status"] = "complete"): RollbackChangePreview => ({
  sessionId,
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: pushEntry.remoteUrl,
  expectedSha: pushEntry.expectedSha,
  parentSha: "b".repeat(40),
  status,
  changes: [
    { path: "docs/readme.md", action: "delete", published: side("c".repeat(40), status === "partial" ? null : 12), restore: null, verification: status === "partial" ? "unavailable" : "verified", issues: status === "partial" ? ["objectMissing"] : [] },
    { path: "src/app.ts", action: "restore", published: null, restore: side("d".repeat(40)), verification: "verified", issues: [] },
  ],
  omittedPaths: status === "partial" ? 1 : 0,
  blockers: [],
  warnings: status === "partial" ? ["objectsUnavailable", "unsafePathsOmitted"] : [],
  summary: { visible: 2, deleteFiles: 1, restoreFiles: 1, replaceFiles: 0, unsupportedFiles: 0, verifiedFiles: status === "partial" ? 1 : 2 },
  checkedAtEpochMs: 1_700_000_200_000,
});

type Gateway = ReleaseLedgerGateway & { getReleaseLedger: ReturnType<typeof vi.fn> };
type PreviewGateway = RollbackChangePreviewGateway & { inspectRollbackChanges: ReturnType<typeof vi.fn> };

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: Gateway;
let previewGateway: PreviewGateway;

function render(props: Partial<React.ComponentProps<typeof ReleaseLedgerPanel>> = {}) {
  root.render(createElement(ReleaseLedgerPanel, { gateway, previewGateway, sessionId: "session-1", enabled: true, ...props }));
}

async function settle() { await act(async () => { await Promise.resolve(); }); }

function button(label: string) {
  return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement | undefined;
}

describe("ReleaseLedgerPanel rollback change preview integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = { getReleaseLedger: vi.fn(async (sessionId: string) => snapshot(sessionId)) };
    previewGateway = { inspectRollbackChanges: vi.fn(async (sessionId: string) => preview(sessionId)) };
  });
  afterEach(() => { act(() => { root.unmount(); }); host.remove(); });

  it("does not inspect on load, embeds only for a verified git push, and opens partial and complete previews explicitly", async () => {
    await act(async () => { render(); }); await settle();
    expect(previewGateway.inspectRollbackChanges).not.toHaveBeenCalled();
    expect(button("预览单提交逆向变更")).toBeTruthy();

    previewGateway.inspectRollbackChanges.mockResolvedValueOnce(preview("session-1", "partial"));
    await act(async () => { button("预览单提交逆向变更")!.click(); await Promise.resolve(); });
    expect(previewGateway.inspectRollbackChanges).toHaveBeenCalledWith("session-1", "push-1", 3);
    expect(host.textContent).toContain("docs/readme.md");
    expect(host.textContent).toContain("预览部分可用");

    previewGateway.inspectRollbackChanges.mockResolvedValueOnce(preview("session-1", "complete"));
    await act(async () => { button("预览单提交逆向变更")!.click(); await Promise.resolve(); });
    expect(host.textContent).toContain("src/app.ts");
    expect(host.textContent).toContain("预览完整");
  });

  it("does not embed the preview action for a remote review even when its verification is valid", async () => {
    const review = { ...pushEntry, source: "remoteReview" as const, targetBranch: "main", operation: "githubReview" as const, status: "reviewVerified" as const };
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot("session-1", review));
    await act(async () => { render(); }); await settle();
    expect(button("预览单提交逆向变更")).toBeUndefined();
    expect(previewGateway.inspectRollbackChanges).not.toHaveBeenCalled();
  });

  it("clears the preview on session refresh and drops a late response from the previous session", async () => {
    let resolvePreview!: (value: RollbackChangePreview) => void;
    previewGateway.inspectRollbackChanges.mockImplementationOnce(() => new Promise<RollbackChangePreview>((resolve) => { resolvePreview = resolve; }));
    await act(async () => { render(); }); await settle();
    await act(async () => { button("预览单提交逆向变更")!.click(); await Promise.resolve(); });
    expect(previewGateway.inspectRollbackChanges).toHaveBeenCalledTimes(1);

    await act(async () => { render({ sessionId: "session-2" }); }); await settle();
    expect(host.textContent).not.toContain("docs/readme.md");
    resolvePreview(preview("session-1", "complete")); await settle();
    expect(host.textContent).not.toContain("docs/readme.md");
    expect(host.textContent).not.toContain("src/app.ts");
  });
});
