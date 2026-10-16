import { readFileSync, statSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const desktopRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_STARTUP_JAVASCRIPT_BUDGET_BYTES = 700 * 1024;
// This includes a lazy surface's static imports. Vite currently makes those imports
// reference the startup entry for shared React runtime code, so this is intentionally
// larger than the incremental request made after startup.
const DEFAULT_LAZY_SURFACE_JAVASCRIPT_BUDGET_BYTES = 1_300 * 1024;
const REQUIRED_LAZY_SURFACES = [
  "src/components/MarkdownEditorSurface.tsx",
  "src/components/PublishCenter.tsx",
  "src/components/AdvancedTools.tsx",
  "src/components/SettingsCenter.tsx",
  "src/components/KnowledgeLibrary.tsx",
  "src/components/RssReader.tsx",
  "src/components/ImageWorkbench.tsx",
  "src/components/OperationLogCenter.tsx",
  "src/components/SiteProfileCenter.tsx",
  "src/components/ArticleStatePanel.tsx",
  "src/components/SitePreview.tsx",
];

function assertManifestRecord(manifest, key) {
  const item = manifest[key];
  if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error(`manifest references missing or invalid chunk: ${key}`);
  return item;
}

function collectStaticClosure(manifest, startKeys) {
  const visited = new Set();
  const visit = (key) => {
    if (visited.has(key)) return;
    const item = assertManifestRecord(manifest, key);
    visited.add(key);
    if (item.imports !== undefined && !Array.isArray(item.imports)) throw new Error(`manifest imports are invalid for chunk: ${key}`);
    for (const next of item.imports ?? []) {
      if (typeof next !== "string") throw new Error(`manifest import is invalid for chunk: ${key}`);
      visit(next);
    }
  };
  for (const key of startKeys) visit(key);
  return visited;
}

function collectDynamicallyReachable(manifest, startupKeys) {
  const reachable = new Set();
  const queue = [];
  const enqueueDynamicImports = (key) => {
    const item = assertManifestRecord(manifest, key);
    if (item.dynamicImports !== undefined && !Array.isArray(item.dynamicImports)) throw new Error(`manifest dynamicImports are invalid for chunk: ${key}`);
    for (const next of item.dynamicImports ?? []) {
      if (typeof next !== "string") throw new Error(`manifest dynamic import is invalid for chunk: ${key}`);
      queue.push(next);
    }
  };

  for (const key of startupKeys) enqueueDynamicImports(key);
  while (queue.length) {
    const dynamicRoot = queue.shift();
    if (!dynamicRoot || reachable.has(dynamicRoot)) continue;
    const closure = collectStaticClosure(manifest, [dynamicRoot]);
    for (const key of closure) {
      if (reachable.has(key)) continue;
      reachable.add(key);
      enqueueDynamicImports(key);
    }
  }
  return reachable;
}

function javascriptFilesForClosure(manifest, closure, distRoot) {
  const files = new Set();
  for (const key of closure) {
    const file = assertManifestRecord(manifest, key).file;
    if (typeof file !== "string" || !file.endsWith(".js")) continue;
    const absolutePath = resolve(distRoot, file);
    const pathFromDist = relative(distRoot, absolutePath);
    if (!pathFromDist || pathFromDist === ".." || pathFromDist.startsWith(`..${sep}`) || isAbsolute(pathFromDist)) {
      throw new Error(`manifest file escapes dist: ${file}`);
    }
    files.add(absolutePath);
  }
  if (!files.size) throw new Error("chunk closure contains no JavaScript files");
  return files;
}

function totalBytes(files) {
  return [...files].reduce((total, file) => total + statSync(file).size, 0);
}

export function checkFrontendBundle({
  distRoot = resolve(desktopRoot, "dist"),
  manifestPath = resolve(distRoot, ".vite/manifest.json"),
  startupBudgetBytes = DEFAULT_STARTUP_JAVASCRIPT_BUDGET_BYTES,
  lazySurfaceBudgetBytes = DEFAULT_LAZY_SURFACE_JAVASCRIPT_BUDGET_BYTES,
  requiredLazySurfaces = REQUIRED_LAZY_SURFACES,
} = {}) {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) throw new Error("manifest is not an object");
  if (!Number.isFinite(startupBudgetBytes) || startupBudgetBytes <= 0 || !Number.isFinite(lazySurfaceBudgetBytes) || lazySurfaceBudgetBytes <= 0) throw new Error("bundle budgets must be positive finite numbers");

  const entryKeys = Object.entries(manifest).filter(([, item]) => item?.isEntry === true).map(([key]) => key);
  if (entryKeys.length !== 1) throw new Error(`expected exactly one startup entry, found ${entryKeys.length}`);

  const startupKeys = collectStaticClosure(manifest, entryKeys);
  const dynamicallyReachable = collectDynamicallyReachable(manifest, startupKeys);
  const startupFiles = javascriptFilesForClosure(manifest, startupKeys, distRoot);
  const startupBytes = totalBytes(startupFiles);
  if (startupBytes > startupBudgetBytes) {
    throw new Error(`startup JavaScript is ${(startupBytes / 1024).toFixed(1)} KiB; budget is ${(startupBudgetBytes / 1024).toFixed(0)} KiB`);
  }

  const lazySurfaceBytes = new Map();
  const lazyFiles = new Set();
  for (const surface of requiredLazySurfaces) {
    assertManifestRecord(manifest, surface);
    if (startupKeys.has(surface)) throw new Error(`required lazy surface is bundled in startup graph: ${surface}`);
    if (!dynamicallyReachable.has(surface)) throw new Error(`required lazy surface is not dynamically reachable: ${surface}`);
    const files = javascriptFilesForClosure(manifest, collectStaticClosure(manifest, [surface]), distRoot);
    const bytes = totalBytes(files);
    if (bytes > lazySurfaceBudgetBytes) {
      throw new Error(`lazy surface ${surface} and static imports are ${(bytes / 1024).toFixed(1)} KiB; budget is ${(lazySurfaceBudgetBytes / 1024).toFixed(0)} KiB`);
    }
    lazySurfaceBytes.set(surface, bytes);
    for (const file of files) lazyFiles.add(file);
  }
  const lazyOnlyFiles = new Set([...lazyFiles].filter((file) => !startupFiles.has(file)));
  if (lazyOnlyFiles.size < requiredLazySurfaces.length) throw new Error(`only ${lazyOnlyFiles.size} lazy JavaScript chunks found for ${requiredLazySurfaces.length} required surfaces`);

  return { startupBytes, startupFiles: startupFiles.size, lazyChunks: lazyOnlyFiles.size, lazySurfaceBytes };
}

function runCli() {
  try {
    const result = checkFrontendBundle();
    console.log(`Bundle budget passed: startup JavaScript ${(result.startupBytes / 1024).toFixed(1)} KiB across ${result.startupFiles} file(s); ${result.lazyChunks} lazy JavaScript chunk(s) detected.`);
  } catch (error) {
    console.error(`Bundle budget check failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) runCli();
