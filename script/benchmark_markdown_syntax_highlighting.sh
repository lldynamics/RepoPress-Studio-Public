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

SWIFT_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
mkdir -p \
  "$SWIFT_HOME" \
  "$SWIFT_HOME/.cache" \
  "$SWIFT_HOME/.swift-clang-cache" \
  "$SWIFT_HOME/.swift-module-cache" \
  "$SWIFT_HOME/Library/org.swift.swiftpm/configuration" \
  "$SWIFT_HOME/Library/org.swift.swiftpm/security" \
  "$SWIFT_HOME/Library/Caches/org.swift.swiftpm" \
  "$(dirname "$OUTPUT_PATH")"

cd "$ROOT_DIR"
env \
  HOME="$SWIFT_HOME" \
  XDG_CACHE_HOME="$SWIFT_HOME/.cache" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-clang-cache" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-module-cache" \
  RUN_MARKDOWN_SYNTAX_BENCHMARK=1 \
  MARKDOWN_SYNTAX_BENCHMARK_ITERATIONS="$ITERATIONS" \
  MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION="$BUILD_CONFIGURATION" \
  MARKDOWN_SYNTAX_BENCHMARK_OUTPUT="$OUTPUT_PATH" \
  swift test \
    --configuration "$BUILD_CONFIGURATION" \
    --disable-sandbox \
    --filter MarkdownSyntaxHighlightBenchmarkTests/testGeneratedDocumentBaseline

echo "markdown syntax benchmark report: $OUTPUT_PATH"
