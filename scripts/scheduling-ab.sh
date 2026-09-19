#!/usr/bin/env bash
# A/B the CPU share a process tree gets, Banyan pane vs Terminal.app.
#
# Answers "is work started from a Banyan session scheduled worse than the same
# work started from Terminal.app?" by running byte-identical CPU-bound probes in
# both trees at the same moment and comparing the CPU *time* each arm is granted.
#
# Run it from inside a Banyan pane: the `banyan` arm is whatever tree this script
# is in, and the `terminal` arm is spawned through `open -g -a Terminal` so the
# comparison is between two process trees rooted in two different apps.
#
# Two traps this harness exists to avoid:
#
#   - zsh nices every `&` background job by +5 (the BG_NICE option, on by default
#     and equally on under Terminal.app). Probes are therefore launched from
#     /bin/sh, so both arms measure at nice 0 and the reading is about scheduling
#     rather than about which shell backgrounded the job.
#   - macOS hands CPU to process trees, not to processes. An arm whose tree is
#     already busy gets a smaller slice per probe, so comparing a loaded tree
#     against an idle one measures the load, not the host app. `--load N` injects
#     N extra busy threads into the Terminal arm to match what the Banyan tree is
#     already carrying; without it the comparison is not a comparison.
#
# Usage:
#   scripts/scheduling-ab.sh [--procs N] [--duration S] [--load N] [--out DIR]
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCS=12
DURATION=15
LOAD=0
OUT_DIR="$ROOT_DIR/artifacts/scheduling-ab"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --procs) PROCS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --load) LOAD="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
# Terminal.app runs the .command from its own working directory, so every path
# baked into it has to be absolute or the arm silently reports nothing.
OUT_DIR="$(cd -P "$OUT_DIR" && pwd)"
BANYAN_OUT="$OUT_DIR/banyan.txt"
TERMINAL_OUT="$OUT_DIR/terminal.txt"
RUNNER="$OUT_DIR/run-arm.sh"
LAUNCHER="$OUT_DIR/terminal-arm.command"
: >"$BANYAN_OUT"
: >"$TERMINAL_OUT"

# One arm: LOAD filler threads, then PROCS measured probes that all start at the
# same wall-clock second so the two arms overlap exactly.
cat >"$RUNNER" <<'RUNNER_EOF'
#!/bin/sh
# $1=label $2=procs $3=start_epoch $4=duration $5=outfile $6=load
LABEL="$1"; N="$2"; START="$3"; DUR="$4"; OUT="$5"; LOAD="${6:-0}"

PROBE='
my ($label, $start, $dur) = @ARGV;
select(undef, undef, undef, 0.05) while time() < $start;
my $t0 = time();
my $iters = 0;
$iters++ while (time() - $t0) < $dur;
my @t = times();
printf("%s nice=%d iters=%d cpu=%.2f\n", $label, getpriority(0, 0), $iters, $t[0] + $t[1]);
'
FILLER='
my $dur = shift;
my $t0 = time();
1 while (time() - $t0) < $dur;
'

: >"$OUT"
i=0
while [ "$i" -lt "$LOAD" ]; do
  perl -e "$FILLER" $((DUR + 20)) >/dev/null 2>&1 &
  i=$((i + 1))
done

i=0
while [ "$i" -lt "$N" ]; do
  perl -e "$PROBE" "$LABEL" "$START" "$DUR" >>"$OUT" 2>&1 &
  i=$((i + 1))
done
wait
RUNNER_EOF
chmod +x "$RUNNER"

# The Terminal arm needs a document to open; a .command file is the only way to
# get Terminal.app to root a process tree without driving it interactively.
START=$(($(date +%s) + 12))
cat >"$LAUNCHER" <<EOF
#!/bin/sh
/bin/sh "$RUNNER" terminal $PROCS $START $DURATION "$TERMINAL_OUT" $LOAD
exit 0
EOF
chmod +x "$LAUNCHER"

echo "cores: $(sysctl -n hw.ncpu)   load before: $(uptime | sed 's/.*load aver/load aver/')"
echo "arms:  $PROCS probes each, ${DURATION}s, +$LOAD filler threads in the terminal arm"

# -g keeps Terminal.app in the background: frontmost-ness is a variable we are
# deliberately holding still, not the one under test.
open -g -a Terminal "$LAUNCHER"
/bin/sh "$RUNNER" banyan "$PROCS" "$START" "$DURATION" "$BANYAN_OUT" 0

for _ in $(seq 1 30); do
  [[ "$(wc -l <"$TERMINAL_OUT")" -ge "$PROCS" ]] && break
  /bin/sleep 2
done

terminal_lines="$(wc -l <"$TERMINAL_OUT" | tr -d ' ')"
if [[ "$terminal_lines" -lt "$PROCS" ]]; then
  echo "terminal arm reported $terminal_lines/$PROCS probes — results below are incomplete" >&2
fi

echo
echo "--- CPU granted per arm (${DURATION}s window) ---"
cat "$BANYAN_OUT" "$TERMINAL_OUT" | awk -v dur="$DURATION" '
  { split($2, a, "="); split($3, b, "="); split($4, c, "=")
    nice[$1] = a[2]; iters[$1] += b[2]; cpu[$1] += c[2]; n[$1]++ }
  END {
    for (k in n)
      printf "  %-9s probes=%-3d nice=%-2d cores=%6.2f  cores/probe=%.3f  Miters/CPU-sec=%.2f\n",
        k, n[k], nice[k], cpu[k] / dur, cpu[k] / dur / n[k], iters[k] / cpu[k] / 1e6
  }' | sort

echo
echo "Equal Miters/CPU-sec across arms means both ran on comparable cores, so any"
echo "cores/probe gap is CPU time the scheduler withheld, not slower silicon."
echo "Raw samples: $BANYAN_OUT, $TERMINAL_OUT"
