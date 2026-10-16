import { exitActivity } from "./exitActivity";
import { invoke } from "@tauri-apps/api/core";
import { save as saveDialog } from "@tauri-apps/plugin-dialog";
import type { MarkdownDocumentExportPlan } from "../features/export/markdownDocumentExport";

export interface MarkdownDocumentExportWriteResult {
  status: "saved" | "cancelled";
  path?: string;
  byteSize?: number;
}

type SaveDialog = (options: {
  title: string;
  defaultPath: string;
  filters: { name: string; extensions: string[] }[];
}) => Promise<string | null>;
type Invoke = (command: string, args?: object) => Promise<unknown>;

/**
 * Bridges a deterministic export plan to the native save dialog and the narrow
 * core writer. Tests inject both boundaries; production uses Tauri directly.
 */
export function createMarkdownDocumentExportSaver(
  selectPath: SaveDialog = saveDialog,
  call: Invoke = (command, args) => invoke(command, args as never),
) {
  return async (plan: MarkdownDocumentExportPlan): Promise<MarkdownDocumentExportWriteResult> => exitActivity.run(async () => {
    const path = await selectPath({
      title: plan.format === "markdown" ? "导出 Markdown 文稿" : "导出 HTML 文稿",
      defaultPath: plan.suggestedFileName,
      filters: [{
        name: plan.format === "markdown" ? "Markdown 文稿" : "HTML 文稿",
        extensions: [plan.extension],
      }],
    });
    if (!path) return { status: "cancelled" };

    const result = await call("export_markdown_document", {
      path,
      contents: plan.text,
      format: plan.format,
    }) as { path: string; byteSize: number };
    return { status: "saved", path: result.path, byteSize: result.byteSize };
  });
}
