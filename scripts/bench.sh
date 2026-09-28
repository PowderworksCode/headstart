#!/usr/bin/env bash
# Time clean `cargo check` (or `cargo build`, with `-c build`) builds with and
# without headstart, alternating, with the same patched rustc and cargo
# (headstart off = upstream behavior):
#
#   scripts/bench.sh [-n runs] [-j jobs] [-c check|build] [-o out-dir] <project dir>...
#
# Each project is copied to <out-dir>/work first. Writes <out-dir>/runs.tsv
# (project, mode, run, seconds, exit status) and, for each build, the
# per-rustc schedule and the diagnostics under <out-dir>/schedules/. Prints
# a table of medians, and any project whose diagnostics differ between
# modes.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
runs=5 jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc) out=$root/results/$(date +%F) command=check
while getopts n:j:o:c: opt; do
  case $opt in
    n) runs=$OPTARG ;; j) jobs=$OPTARG ;; o) out=$OPTARG ;; c) command=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || { echo "usage: $0 [-n runs] [-j jobs] [-c check|build] [-o out-dir] <project dir>..." >&2; exit 2; }

export RUSTC=$root/rustc/build/host/stage1/bin/rustc
export RUSTC_WRAPPER=$root/scripts/log-rustc
cargo=$root/cargo/target/release/cargo
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

mkdir -p "$out/work" "$out/schedules"
out=$(cd "$out" && pwd)
[ -f "$out/runs.tsv" ] || printf 'project\tmode\trun\tseconds\tstatus\n' > "$out/runs.tsv"
for src in "$@"; do
  name=$(basename "$src")
  rsync -a --delete --exclude target "$src/" "$out/work/$name/"
  (cd "$out/work/$name" && "$cargo" fetch -q) || { echo "$name: fetch failed" >&2; continue; }
  for run in $(seq "$runs"); do
    for mode in off on; do
      rm -rf "$out/work/$name/target"
      log=$out/schedules/$name.$mode.$run.txt
      rm -f "$log"
      start=$(now)
      (cd "$out/work/$name" &&
        HEADSTART_LOG=$log CARGO_HEADSTART=$([ $mode = on ] && echo 1 || echo 0) \
          "$cargo" "$command" -q -j "$jobs" --offline --message-format=short >/dev/null 2>"${log%.txt}.err")
      status=$?
      secs=$(perl -e "printf '%.2f', $(now) - $start")
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$mode" "$run" "$secs" "$status" >> "$out/runs.tsv"
      echo "$name $mode #$run: ${secs}s (exit $status)"
    done
  done
done

python3 - "$out/runs.tsv" <<'PY'
import csv, os, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
sched = os.path.join(os.path.dirname(sys.argv[1]), "schedules")
def diagnostics(p, mode, run):
    try:
        return sorted(open(os.path.join(sched, f"{p}.{mode}.{run}.err")).read().splitlines())
    except FileNotFoundError:
        return None
differ = sorted({r["project"] for r in rows if r["mode"] == "on"
                 and diagnostics(r["project"], "on", r["run"]) != diagnostics(r["project"], "off", r["run"])})
times = {}
for r in rows:
    if r["status"] == "0":
        times.setdefault(r["project"], {}).setdefault(r["mode"], []).append(float(r["seconds"]))
print("\n| project | today (median) | headstart (median) | saved | runs |")
print("|---|--:|--:|--:|--:|")
for p, m in times.items():
    if "off" in m and "on" in m:
        off, on = statistics.median(m["off"]), statistics.median(m["on"])
        print(f"| {p} | {off:.2f} s | {on:.2f} s | {100 * (1 - on / off):.0f}% | {len(m['on'])} |")
if differ:
    print("\ndiagnostics differ between modes:", ", ".join(differ))
PY
