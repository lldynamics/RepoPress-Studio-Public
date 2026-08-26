#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="$ROOT_DIR/.build/benchmarks/markdown-syntax-baseline.json"
ITERATIONS="${MARKDOWN_SYNTAX_BENCHMARK_ITERATIONS:-20}"
BUILD_CONFIGURATION="${MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION:-debug}"

usage() {
  printf '%s\n' \
    "usage: script/benchmark_markdown_syntax_highlighting.sh [--configuration debug|release] [--iterations count] [--output path]" \
    "" \
    "Runs deterministic full-document and incremental Markdown syntax highlighting baselines." \
    "The default configuration is debug; use release for optimization comparisons." \
    "The JSON report defaults to .build/benchmarks/markdown-syntax-baseline.json."
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      BUILD_CONFIGURATION="$2"
      shift 2
      ;;
    --iterations)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      ITERATIONS="$2"
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || {
  echo "iterations must be a positive integer: $ITERATIONS" >&2
  exit 2
}
case "$BUILD_CONFIGURATION" in
  debug|release) ;;
  *)
    echo "configuration must be debug or release: $BUILD_CONFIGURATION" >&2
    exit 2
    ;;
esac

case "$OUTPUT_PATH" in
  /*) ;;
  *) OUTPUT_PATH="$ROOT_DIR/$OUTPUT_PATH" ;;
esac
VIEWPORT_OUTPUT_PATH="${MARKDOWN_VIEWPORT_BENCHMARK_OUTPUT:-${OUTPUT_PATH%.json}-viewport.json}"
case "$VIEWPORT_OUTPUT_PATH" in
  /*) ;;
  *) VIEWPORT_OUTPUT_PATH="$ROOT_DIR/$VIEWPORT_OUTPUT_PATH" ;;
esac

SWIFT_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
PERFORMANCE_COMMIT="${PERFORMANCE_BENCHMARK_COMMIT:-$(git rev-parse HEAD)}"
PERFORMANCE_TOOLCHAIN="${PERFORMANCE_BENCHMARK_TOOLCHAIN:-$(swift --version | head -n 1)}"
PERFORMANCE_ARCHITECTURE="${PERFORMANCE_BENCHMARK_ARCHITECTURE:-$(uname -m)}"
PERFORMANCE_OPERATING_SYSTEM="${PERFORMANCE_BENCHMARK_OPERATING_SYSTEM:-$(sw_vers -productVersion 2>/dev/null || uname -sr)}"
PERFORMANCE_MACHINE="${PERFORMANCE_BENCHMARK_MACHINE:-$(sysctl -n hw.model 2>/dev/null || uname -n)}"
mkdir -p \
  "$SWIFT_HOME" \
  "$SWIFT_HOME/.cache" \
  "$SWIFT_HOME/.swift-clang-cache" \
  "$SWIFT_HOME/.swift-module-cache" \
  "$(dirname "$OUTPUT_PATH")" \
  "$(dirname "$VIEWPORT_OUTPUT_PATH")"

cd "$ROOT_DIR"
env \
  XDG_CACHE_HOME="$SWIFT_HOME/.cache" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-clang-cache" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-module-cache" \
  RUN_MARKDOWN_SYNTAX_BENCHMARK=1 \
  MARKDOWN_SYNTAX_BENCHMARK_ITERATIONS="$ITERATIONS" \
  MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION="$BUILD_CONFIGURATION" \
  MARKDOWN_SYNTAX_BENCHMARK_OUTPUT="$OUTPUT_PATH" \
  PERFORMANCE_BENCHMARK_REQUIRED=1 \
  PERFORMANCE_BENCHMARK_COMMIT="$PERFORMANCE_COMMIT" \
  PERFORMANCE_BENCHMARK_TOOLCHAIN="$PERFORMANCE_TOOLCHAIN" \
  PERFORMANCE_BENCHMARK_ARCHITECTURE="$PERFORMANCE_ARCHITECTURE" \
  PERFORMANCE_BENCHMARK_OPERATING_SYSTEM="$PERFORMANCE_OPERATING_SYSTEM" \
  PERFORMANCE_BENCHMARK_MACHINE="$PERFORMANCE_MACHINE" \
  swift test \
    --configuration "$BUILD_CONFIGURATION" \
    --disable-sandbox \
    --filter MarkdownSyntaxHighlightBenchmarkTests/testGeneratedDocumentBaseline

env \
  XDG_CACHE_HOME="$SWIFT_HOME/.cache" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-clang-cache" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-module-cache" \
  RUN_MARKDOWN_VIEWPORT_BENCHMARK=1 \
  MARKDOWN_VIEWPORT_BENCHMARK_ITERATIONS="$ITERATIONS" \
  MARKDOWN_VIEWPORT_BENCHMARK_OUTPUT="$VIEWPORT_OUTPUT_PATH" \
  MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION="$BUILD_CONFIGURATION" \
  swift test \
    --configuration "$BUILD_CONFIGURATION" \
    --disable-sandbox \
    --filter MarkdownViewportHighlightBenchmarkTests/testIncrementalViewportPipelineDocumentSizeIndependence

echo "markdown syntax benchmark report: $OUTPUT_PATH"
echo "markdown viewport benchmark report: $VIEWPORT_OUTPUT_PATH"
