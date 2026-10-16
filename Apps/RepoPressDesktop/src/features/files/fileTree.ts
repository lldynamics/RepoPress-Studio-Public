import type { MarkdownFileEntry } from "../../contracts/repository";

export interface FileTreeDirectory { kind: "directory"; name: string; relativePath: string; children: FileTreeNode[]; }
export interface FileTreeFile { kind: "file"; file: MarkdownFileEntry; }
export type FileTreeNode = FileTreeDirectory | FileTreeFile;

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

/** Builds a stable hierarchy from repository-relative Markdown paths. */
export function buildMarkdownFileTree(files: MarkdownFileEntry[]): FileTreeNode[] {
  const root: FileTreeDirectory = { kind: "directory", name: "", relativePath: "", children: [] };
  for (const file of files) {
    const parts = file.relativePath.split("/").filter(Boolean);
    let parent = root;
    for (const part of parts.slice(0, -1)) {
      let directory = parent.children.find((node): node is FileTreeDirectory => node.kind === "directory" && node.name === part);
      if (!directory) {
        directory = { kind: "directory", name: part, relativePath: parent.relativePath ? `${parent.relativePath}/${part}` : part, children: [] };
        parent.children.push(directory);
      }
      parent = directory;
    }
    parent.children.push({ kind: "file", file });
  }
  sortTree(root.children);
  return root.children;
}

function sortTree(nodes: FileTreeNode[]): void {
  nodes.sort((left, right) => {
    if (left.kind !== right.kind) return left.kind === "directory" ? -1 : 1;
    const leftName = left.kind === "directory" ? left.name : left.file.displayName;
    const rightName = right.kind === "directory" ? right.name : right.file.displayName;
    return collator.compare(leftName, rightName);
  });
  for (const node of nodes) if (node.kind === "directory") sortTree(node.children);
}
