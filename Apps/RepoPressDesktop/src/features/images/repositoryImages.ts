import type { RepositorySessionSnapshot } from "../../contracts/repository";
import { insertMarkdownImage, type MarkdownImageInsertion } from "../writing/imageInsertion";
import type { TextRange } from "../writing/markdownWriting";

function pathParts(path: string): string[] {
  const parts = path.split("/");
  if (!path || /[\\\u0000-\u001f\u007f]/u.test(path) || parts.some((part) => !part || part === "." || part === ".." || part.toLowerCase() === ".git")) {
    throw new Error("图片或文章路径不是有效的仓库相对路径。");
  }
  return parts;
}

function encodePath(parts: string[]): string {
  return parts.map((part) => encodeURIComponent(part).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)).join("/");
}

/** Match the public asset roots used by the native image importer. Other images
 * use a document-relative path, so a local resource never becomes a remote URL. */
export function repositoryImageMarkdownPath(
  imagePath: string,
  repository: Pick<RepositorySessionSnapshot, "siteKind" | "contentRoot">,
  documentPath: string,
): string {
  const image = pathParts(imagePath);
  const document = pathParts(documentPath);
  const publicRoot = (() => {
    switch (repository.siteKind) {
      case "hugo": case "zola": return "static/";
      case "astro": case "nextjs": return "public/";
      case "vitepress": return "docs/public/";
      case "hexo": return "source/";
      case "jekyll": return "assets/";
      case "jekyll-or-hexo": return repository.contentRoot === "source/_posts" ? "source/" : "assets/";
      case "quartz": return "content/";
      case "foam": return "attachments/";
      default: return "static/";
    }
  })();
  if (imagePath.startsWith(publicRoot)) {
    const prefix = publicRoot === "assets/" ? ["assets"] : publicRoot === "attachments/" ? ["attachments"] : [];
    return `/${encodePath([...prefix, ...image.slice(publicRoot.split("/").length - 1)])}`;
  }
  const directory = document.slice(0, -1);
  let shared = 0;
  while (shared < directory.length && directory[shared] === image[shared]) shared += 1;
  const parent = "../".repeat(directory.length - shared);
  return `${parent || "./"}${encodePath(image.slice(shared))}`;
}

/** The Alt supplied in the image workbench takes precedence over selected text.
 * Only the selected buffer range changes; callers still control saving. */
export function insertRepositoryImage(source: string, selection: TextRange, markdownPath: string, altText: string): MarkdownImageInsertion {
  if (!Number.isInteger(selection.from) || !Number.isInteger(selection.to) || selection.from < 0 || selection.to < selection.from || selection.to > source.length) {
    throw new Error("文章选区已失效，请重新选择插入位置。");
  }
  const insertion = insertMarkdownImage("", { from: 0, to: 0 }, markdownPath, altText);
  return {
    text: source.slice(0, selection.from) + insertion.text + source.slice(selection.to),
    markdown: insertion.markdown,
    selection: { from: selection.from + insertion.selection.from, to: selection.from + insertion.selection.to },
  };
}
