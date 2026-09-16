#!/usr/bin/env bash
# A/B the terminal renderers on a fixed streaming workload.
#
# Runs TerminalRenderBench once per arm per repetition, interleaving the arms so
# thermal drift and background load hit both of them equally, then reports the
# median of each metric. Every arm replays a byte-identical workload.
#
# The harness needs a visible, unoccluded window: a Metal drawable comes from the
# window server. It takes over the screen for the duration - do not drive the
# machine while it runs, or the numbers measure you.
#
# Usage:
#   scripts/terminal-render-bench.sh [--reps N] [--bytes N] [--rate N]
#                                    [--workload stream|static|both]
#                                    [--out DIR]
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPS=3
BYTES=$((6 * 1024 * 1024))
RATE=$((512 * 1024))
WORKLOADS=("stream")
OUT_DIR="$ROOT_DIR/artifacts/terminal-render-bench"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps) REPS="$2"; shift 2 ;;
    --bytes) BYTES="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --workload)
      case "$2" in
        both) WORKLOADS=("stream" "static") ;;
        stream|static) WORKLOADS=("$2") ;;
        *) echo "unknown workload '$2'" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

BENCH="$ROOT_DIR/.build/release/TerminalRenderBench"
swift build --package-path "$ROOT_DIR" -c release --product TerminalRenderBench >/dev/null

mkdir -p "$OUT_DIR"
RUN_DIR="$OUT_DIR/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

# arm = label:renderer:buffering:env-assignment ("-" for none)
ARMS=(
  "cg:cg:perRow:-"
  "metal:metal:perRow:-"
  "metal-perframe:metal:perFrame:-"
)
if [[ -n "${BENCH_ARMS:-}" ]]; then
  IFS=',' read -r -a ARMS <<<"$BENCH_ARMS"
fi

for workload in "${WORKLOADS[@]}"; do
  for ((rep = 1; rep <= REPS; rep++)); do
    for arm in "${ARMS[@]}"; do
      IFS=':' read -r label renderer buffering arm_env <<<"$arm"
      echo "[$workload rep $rep] $label" >&2
      env ${arm_env/#-/} "$BENCH" \
        --renderer "$renderer" \
        --metal-buffering "$buffering" \
        --workload "$workload" \
        --bytes "$BYTES" \
        --rate "$RATE" \
        --label "$label" \
        --json >"$RUN_DIR/$workload-$label-$rep.json"
      # Let the machine settle so one arm does not inherit the other's heat.
      sleep 2
    done
  done
done

python3 - "$RUN_DIR" <<'PY'
import glob, json, os, statistics, sys

run_dir = sys.argv[1]
runs = []
for path in sorted(glob.glob(os.path.join(run_dir, "*.json"))):
    with open(path) as handle:
        runs.append(json.load(handle))

def median(values):
    return statistics.median(values) if values else 0.0

grouped = {}
for run in runs:
    grouped.setdefault((run["workload"], run["label"]), []).append(run)

print()
for workload in sorted({key[0] for key in grouped}):
    keys = [key for key in grouped if key[0] == workload]
    first = grouped[keys[0]][0]
    print(f"## workload: {workload}  ({first['cols']}x{first['rows']} cells, "
          f"{first['bytes'] / 1048576:.1f} MB at {first['bytesPerSecond'] / 1024:.0f} KB/s, "
          f"n={len(grouped[keys[0]])})")
    print()
    header = ("| arm | draw avg | draw p95 | draw p99 | frames | draw total | "
              "cpu total | cycles | wall |")
    print(header)
    print("|---|---|---|---|---|---|---|---|---|")
    for label in sorted({key[1] for key in keys}):
        group = grouped[(workload, label)]
        draw = [run["drawMS"] for run in group]
        cpu = [run["cpu"] for run in group]
        print("| {} | {:.2f} ms | {:.2f} ms | {:.2f} ms | {:.0f} | {:.0f} ms | {:.0f} ms | {:.2f} G | {:.2f} s |".format(
            label,
            median([d["avg"] for d in draw]),
            median([d["p95"] for d in draw]),
            median([d["p99"] for d in draw]),
            median([run["frames"] for run in group]),
            median([d["total"] for d in draw]),
            median([c["totalMS"] for c in cpu]),
            median([c["cycles"] for c in cpu]) / 1e9,
            median([run["wallSeconds"] for run in group]),
        ))
    print()

print(f"raw runs: {run_dir}")
PY
