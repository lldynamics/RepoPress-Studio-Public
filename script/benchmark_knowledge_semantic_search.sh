#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_OUTPUT:-$ROOT_DIR/.build/benchmarks/knowledge-semantic-search.json}"
ITERATIONS="${KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_ITERATIONS:-5}"
SIZES="${KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_SIZES:-1000,10000,50000}"
BUILD_CONFIGURATION="${KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_CONFIGURATION:-debug}"
SCRATCH_PATH="${KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_SCRATCH:-/private/tmp/repopress-knowledge-semantic-benchmark-$$}"

usage() {
  printf '%s\n' \
    "usage: script/benchmark_knowledge_semantic_search.sh [options]" \
    "" \
    "Runs the opt-in end-to-end KnowledgeDatabase.semanticSearch benchmark." \
    "  --configuration debug|release  SwiftPM build configuration (default: debug)" \
    "  --iterations count             measured queries per database (default: 5)" \
    "  --sizes n[,n...]               chunk counts (default: 1000,10000,50000)" \
    "  --output path                  JSON report path" \
    "  --scratch path                 isolated SwiftPM/cache/fixture root" \
    "" \
    "The benchmark populates a temporary SQLite database and excludes setup" \
    "from query samples. The normal test inventory skips this lane."
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
    --sizes)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      SIZES="$2"
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --scratch)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      SCRATCH_PATH="$2"
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

IFS=',' read -r -a SIZE_VALUES <<< "$SIZES"
[[ "${#SIZE_VALUES[@]}" -gt 0 ]] || {
  echo "sizes must contain at least one positive integer: $SIZES" >&2
  exit 2
}
for size in "${SIZE_VALUES[@]}"; do
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || {
    echo "sizes must contain positive integers: $SIZES" >&2
    exit 2
  }
done

case "$OUTPUT_PATH" in
  /*) ;;
  *) OUTPUT_PATH="$ROOT_DIR/$OUTPUT_PATH" ;;
esac
case "$SCRATCH_PATH" in
  /*) ;;
  *) SCRATCH_PATH="$ROOT_DIR/$SCRATCH_PATH" ;;
esac
[[ "$SCRATCH_PATH" != "$ROOT_DIR" ]] || {
  echo "scratch path must be isolated from the repository root" >&2
  exit 2
}

SWIFT_HOME="$SCRATCH_PATH/swift-home"
SWIFT_SCRATCH="$SCRATCH_PATH/swiftpm"
BENCHMARK_FIXTURES="$SCRATCH_PATH/fixtures"
PERFORMANCE_COMMIT="${PERFORMANCE_BENCHMARK_COMMIT:-$(git rev-parse HEAD 2>/dev/null || printf '%s' unknown)}"
PERFORMANCE_TOOLCHAIN="${PERFORMANCE_BENCHMARK_TOOLCHAIN:-$(swift --version | head -n 1)}"
PERFORMANCE_ARCHITECTURE="${PERFORMANCE_BENCHMARK_ARCHITECTURE:-$(uname -m)}"
PERFORMANCE_OPERATING_SYSTEM="${PERFORMANCE_BENCHMARK_OPERATING_SYSTEM:-$(sw_vers -productVersion 2>/dev/null || uname -sr)}"
PERFORMANCE_MACHINE="${PERFORMANCE_BENCHMARK_MACHINE:-$(sysctl -n hw.model 2>/dev/null || uname -n)}"
mkdir -p \
  "$SWIFT_HOME/.cache" \
  "$SWIFT_HOME/.swift-clang-cache" \
  "$SWIFT_HOME/.swift-module-cache" \
  "$SWIFT_SCRATCH" \
  "$BENCHMARK_FIXTURES" \
  "$(dirname "$OUTPUT_PATH")"

cd "$ROOT_DIR"
env \
  XDG_CACHE_HOME="$SWIFT_HOME/.cache" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-clang-cache" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_HOME/.swift-module-cache" \
  RUN_KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK=1 \
  KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_ITERATIONS="$ITERATIONS" \
  KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_SIZES="$SIZES" \
  KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_OUTPUT="$OUTPUT_PATH" \
  KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_CONFIGURATION="$BUILD_CONFIGURATION" \
  KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_SCRATCH_PATH="$BENCHMARK_FIXTURES" \
  PERFORMANCE_BENCHMARK_REQUIRED=1 \
  PERFORMANCE_BENCHMARK_COMMIT="$PERFORMANCE_COMMIT" \
  PERFORMANCE_BENCHMARK_TOOLCHAIN="$PERFORMANCE_TOOLCHAIN" \
  PERFORMANCE_BENCHMARK_ARCHITECTURE="$PERFORMANCE_ARCHITECTURE" \
  PERFORMANCE_BENCHMARK_OPERATING_SYSTEM="$PERFORMANCE_OPERATING_SYSTEM" \
  PERFORMANCE_BENCHMARK_MACHINE="$PERFORMANCE_MACHINE" \
  swift test \
    --configuration "$BUILD_CONFIGURATION" \
    --scratch-path "$SWIFT_SCRATCH" \
    --disable-sandbox \
    --filter KnowledgeSemanticSearchBenchmarkTests/testSemanticSearchBaseline

python3 - "$OUTPUT_PATH" "$ITERATIONS" "$SIZES" <<'PY'
import json
import math
import sys

path, iterations_text, sizes_text = sys.argv[1:]
iterations = int(iterations_text)
sizes = [int(value) for value in sizes_text.split(",")]
with open(path, encoding="utf-8") as handle:
    report = json.load(handle)

if not isinstance(report, dict) or report.get("benchmark") != "knowledge-database-semantic-search":
    raise SystemExit("benchmark report has an unexpected benchmark identifier")
if report.get("schemaVersion", 0) < 2 or report.get("sampleCount") != iterations:
    raise SystemExit("benchmark report schema/sample metadata is invalid")
if report.get("iterations") != iterations:
    raise SystemExit("benchmark report iteration count does not match the requested count")
scenarios = report.get("scenarios")
if not isinstance(scenarios, list) or [item.get("chunkCount") for item in scenarios] != sizes:
    raise SystemExit("benchmark report sizes do not match the requested sizes")
for scenario in scenarios:
    for lane in ("coldQuery", "hotQuery"):
        stats = scenario.get(lane)
        if not isinstance(stats, dict):
            raise SystemExit(f"benchmark report {lane} statistics are missing")
        raw = stats.get("rawSamplesMilliseconds")
        if not isinstance(raw, list) or len(raw) != iterations or not all(
            isinstance(value, (int, float)) and math.isfinite(value) and value >= 0 for value in raw
        ):
            raise SystemExit(f"benchmark report {lane} samples are invalid")
        if not all(
            isinstance(stats.get(field), (int, float)) and math.isfinite(stats[field])
            for field in ("minimumMilliseconds", "medianMilliseconds", "p95Milliseconds", "maximumMilliseconds")
        ):
            raise SystemExit(f"benchmark report {lane} statistics are invalid")
    correctness = scenario.get("correctness")
    if not isinstance(correctness, dict) or correctness.get("matchedExpectedChunk") is not True:
        raise SystemExit("benchmark semantic result correctness assertion failed")
print(f"knowledge semantic benchmark report: {path}")
PY
