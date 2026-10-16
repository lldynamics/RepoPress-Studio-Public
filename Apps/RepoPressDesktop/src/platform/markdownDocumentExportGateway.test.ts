import { describe, expect, it, vi } from "vitest";
import { createMarkdownDocumentExportPlan } from "../features/export/markdownDocumentExport";
import { createMarkdownDocumentExportSaver } from "./markdownDocumentExportGateway";

describe("createMarkdownDocumentExportSaver", () => {
  it("treats cancelling the native dialog as a silent no-op", async () => {
    const selectPath = vi.fn(async () => null);
    const call = vi.fn();
    const save = createMarkdownDocumentExportSaver(selectPath, call);

    await expect(save(createMarkdownDocumentExportPlan({ markdown: "draft" }, "markdown"))).resolves.toEqual({ status: "cancelled" });
    expect(call).not.toHaveBeenCalled();
  });

  it("writes the exact current plan through the dedicated Tauri command", async () => {
    const selectPath = vi.fn(async () => "/tmp/文章.html");
    const call = vi.fn(async () => ({ path: "/tmp/文章.html", byteSize: 42 }));
    const save = createMarkdownDocumentExportSaver(selectPath, call);
    const plan = createMarkdownDocumentExportPlan({ markdown: "# 当前缓冲区", fileName: "draft.md" }, "html");

    await expect(save(plan)).resolves.toEqual({ status: "saved", path: "/tmp/文章.html", byteSize: 42 });
    expect(selectPath).toHaveBeenCalledWith(expect.objectContaining({
      defaultPath: "draft.html",
      filters: [{ name: "HTML 文稿", extensions: ["html"] }],
    }));
    expect(call).toHaveBeenCalledWith("export_markdown_document", {
      path: "/tmp/文章.html",
      contents: plan.text,
      format: "html",
    });
  });
});
