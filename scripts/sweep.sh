#!/usr/bin/env bash
# Correctness sweep: builds every rustc-perf compile benchmark (53, not
# counting the -new-solver, -nll, -tiny and -threads4 variants of others)
# once with headstart off and on, with -Zearly-metadata-verify, and checks that every
# build succeeds in both modes with the same diagnostics, and that verify
# reports nothing.
#
#   scripts/sweep.sh [-c check|build] [-r] [-t] [-o out-dir]
#
#   -r  release profile (optimized dependencies, proc macros, build scripts)
#   -t  parallel front end (-Zthreads=8)
#   -o  output directory, replaced if it exists (default results/sweep-...)
#
# stm32f4 needs a device feature and fails in both modes; it's reported but
# doesn't fail the sweep. Needs the rustc-perf submodule:
#   git -C rustc submodule update --init --depth 1 src/tools/rustc-perf
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command=check release= threads= out=
while getopts c:rto: opt; do
  case $opt in
    c) command=$OPTARG ;; r) release=1 ;; t) threads=1 ;; o) out=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
usage="usage: $0 [-c check|build] [-r] [-t] [-o out-dir]"
[ $# -eq 0 ] || { echo "$usage" >&2; exit 2; }
case $command in check|build) ;; *) echo "$usage" >&2; exit 2 ;; esac
name=sweep-$command${release:+-release}${threads:+-threads}
out=${out:-$root/results/$name}
rm -rf "$out"
mkdir -p "$out"

benchmarks=$root/rustc/src/tools/rustc-perf/collector/compile-benchmarks
specs=()
for d in "$benchmarks"/*/; do
  d=${d%/}
  # Variants of other benchmarks that only change compiler flags.
  basename "$d" | grep -qE -- '-new-solver$|-nll$|-tiny$|-threads4$' && continue
  [ -f "$d/Cargo.toml" ] || continue
  specs+=("$d${release:+::--release}")
done
[ ${#specs[@]} -gt 0 ] || { echo "no benchmarks under $benchmarks" >&2; exit 2; }

RUSTFLAGS="-Zearly-metadata-verify${threads:+ -Zthreads=8}" \
  "$root/scripts/bench.sh" -n 1 -c "$command" -o "$out" "${specs[@]}" > "$out.log" 2>&1

failed=$(awk -F'\t' 'NR > 1 && $5 != 0 && $1 !~ /^stm32f4/' "$out/runs.tsv" | wc -l)
differ=$(grep '^diagnostics differ' "$out.log" | sed 's/.*: //' | tr ',' '\n' | tr -d ' ' |
  grep -v '^stm32f4' | paste -sd, -)
verify=$(cat "$out"/schedules/*.err 2>/dev/null | grep -c '^early-metadata-verify')
echo "$name: $(($(wc -l < "$out/runs.tsv") - 1)) builds, $failed failed, diagnostics differ: ${differ:-none}, verify reports: $verify"
[ "$failed" = 0 ] && [ -z "$differ" ] && [ "$verify" = 0 ]
