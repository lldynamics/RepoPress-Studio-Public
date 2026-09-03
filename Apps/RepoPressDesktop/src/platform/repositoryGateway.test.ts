import { describe, expect, it, vi } from "vitest";
import { createRepositoryGateway } from "./repositoryGateway";
describe("BrowserDemoRepositoryGateway", () => {
  it("never performs a demo save", async () => { const gateway = createRepositoryGateway(); await expect(gateway.saveDocument({ sessionId: "demo", documentId: "a", text: "x", expectedSha256: "hash" })).rejects.toMatchObject({ code: "read_only_demo" }); });
  it("keeps all unavailable publication-related capabilities false", async () => { const gateway = createRepositoryGateway(); const snapshot = await gateway.getCapabilities(); expect(snapshot).toMatchObject({ localEdit: false, gitCommit: false, gitPush: false, gitFetch: false, remoteAuth: false }); });
  it("uses fixed typed native command arguments", async () => { const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call); await gateway.openDocument("session-1", "content/a.md"); expect(call).toHaveBeenCalledWith("open_document", { sessionId: "session-1", relativePath: "content/a.md" }); });
  it("sends only session-bound CAS fields when saving", async () => {
    const call = vi.fn().mockResolvedValue({});
    const gateway = createRepositoryGateway(call);
    await gateway.saveDocument({ sessionId: "session-1", documentId: "document-1", text: "# 新内容\n", expectedSha256: "baseline" });
    expect(call).toHaveBeenCalledWith("save_document", { sessionId: "session-1", documentId: "document-1", text: "# 新内容\n", expectedSha256: "baseline" });
  });
});
