#!/usr/bin/env bash
# The whole timing suite in docs/results.md, resumably, for any machine:
#
#   scripts/bench-suite.sh [-j jobs] [-p projects-dir] <out-dir>
#
# - rust-analyzer, `cargo check` and `cargo build`, 5 runs;
# - the 21 rustc-perf benchmarks of results.md, check and build, 3 runs;
# - the other 12 real projects of scripts/real-projects.sh (cloned into
#   <projects-dir>, default ~/hs-real), check and build, 3 runs, with a
#   warm-up build each;
# - codex-rs (scripts/setup-codex.sh), the same way. Its `cargo build`
#   needs more than 15 GB of RAM.
#
# Each benchmark gets its own `bench.sh` out-dir under <out-dir>, and one
# that already has all its runs is skipped, so the suite can be rerun after
# an interruption and continues where it stopped. Writes <out-dir>/summary.md
# at the end, and appends progress, with the load average, to
# <out-dir>/progress.log. Run it on an otherwise idle machine.
#
# On 16 cores the full suite takes most of a day, and polars, zed and lemmy
# need tens of GB of disk each while they build.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc) projects=$HOME/hs-real
while getopts j:p: opt; do
  case $opt in
    j) jobs=$OPTARG ;; p) projects=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { echo "usage: $0 [-j jobs] [-p projects-dir] <out-dir>" >&2; exit 2; }
mkdir -p "$1"
out=$(cd "$1" && pwd)
perf=$root/rustc/src/tools/rustc-perf/collector/compile-benchmarks
[ -d "$perf" ] || { echo "needs the rustc-perf submodule: git -C rustc submodule update --init --depth 1 src/tools/rustc-perf" >&2; exit 2; }

mark() { echo "$(date '+%F %T') $* load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)" >> "$out/progress.log"; }

# bench <name> <runs> <command> <spec> [bench.sh options]
bench() {
  local name=$1 runs=$2 command=$3 spec=$4 dir=$out/$3/$1
  shift 4
  if [ -f "$dir/runs.tsv" ] && [ "$(tail -n +2 "$dir/runs.tsv" | wc -l)" -ge $((2 * runs)) ]; then
    return
  fi
  rm -rf "$dir"
  mkdir -p "$out/$command"
  mark "start $command $name"
  "$root/scripts/bench.sh" -n "$runs" -j "$jobs" -c "$command" -o "$dir" "$@" "$spec" > "$dir.txt" 2>&1
  rm -rf "$dir/work"
}

real=$("$root/scripts/real-projects.sh" "$projects")
for command in check build; do
  bench rust-analyzer 5 $command "$(echo "$real" | grep '/rust-analyzer$')" -w
done
for command in check build; do
  for name in ripgrep-14.1.1 serde_derive-1.0.219 piston-image eza-0.21.2 clap_derive-4.5.32 \
      unicode-normalization-0.1.24 tt-muncher image-0.25.6 html5ever hyper-1.6.0 nalgebra-0.33.0 \
      regex-automata-0.4.8 wg-grammar cargo-0.87.1 cargo html5ever-0.31.0 projection-caching \
      syn-2.0.101 diesel-2.2.10 cranelift-codegen-0.119.0 encoding; do
    bench "$name" 3 $command "$perf/$name"
  done
done
for command in check build; do
  echo "$real" | grep -v '/rust-analyzer$' | while read -r spec; do
    name=$(basename "${spec%%::*}")
    bench "$name" 3 $command "$spec" -w
  done
done
codex=$("$root/scripts/setup-codex.sh" "$projects")
for command in check build; do
  (source "$projects/codex/headstart.env" && bench codex-rs 3 $command "$codex" -w)
done
mark "done"

python3 - "$out" > "$out/summary.md" <<'PY'
import csv, glob, os, statistics, sys
out = sys.argv[1]
print(f"| benchmark | check today | check headstart | saved | build today | build headstart | saved |")
print("|---|--:|--:|--:|--:|--:|--:|")
def load(path):
    t = {}
    for r in csv.DictReader(open(path), delimiter="\t"):
        if r["status"] == "0":
            t.setdefault(r["mode"], []).append(float(r["seconds"]))
    if len(t.get("off", [])) and len(t.get("on", [])):
        off, on = statistics.median(t["off"]), statistics.median(t["on"])
        overlap = "" if max(t["on"]) < min(t["off"]) else "*"
        return f"{off:.2f} s | {on:.2f} s | {100 * (1 - on / off):.0f}%{overlap}"
    return "failed | | "
names = sorted({os.path.basename(os.path.dirname(p)) for p in glob.glob(f"{out}/*/*/runs.tsv")})
for name in names:
    cells = [load(f"{out}/{c}/{name}/runs.tsv") if os.path.exists(f"{out}/{c}/{name}/runs.tsv") else " | | " for c in ("check", "build")]
    print(f"| {name} | {cells[0]} | {cells[1]} |")
print("\n`*`: the off and on ranges overlap.")
PY
cat "$out/summary.md"
