#!/usr/bin/env bash
# Peak memory of clean `cargo check` builds, headstart off and on: samples
# the total resident memory of all rustc processes every 100 ms.
#
#   scripts/bench-mem.sh [-n runs] [-o out.tsv] <project dir>...
#
# Projects are built in place (their target dir is deleted first). Extra
# rustc flags can be passed with RUSTFLAGS.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
runs=3 out=/dev/stdout
while getopts n:o: opt; do
  case $opt in n) runs=$OPTARG ;; o) out=$OPTARG ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
export RUSTC=$root/rustc/build/host/stage1/bin/rustc RUSTC_WRAPPER=
cargo=$root/cargo/target/release/cargo
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
rss_mb() { ps -A -o rss=,comm= | awk '$2 ~ /rustc$/ {s += $1} END {printf "%d", s / 1024}'; }
printf 'project\tmode\trun\tseconds\tpeak_rss_mb\n' > "$out"
for dir in "$@"; do
  name=$(basename "$dir")
  for run in $(seq "$runs"); do
    for mode in off on; do
      rm -rf "$dir/target"
      start=$(now)
      (cd "$dir" && CARGO_UNSTABLE_HEADSTART=$([ $mode = on ] && echo true || echo false) \
        "$cargo" check -q --offline >/dev/null 2>&1) &
      pid=$! peak=0
      while kill -0 $pid 2>/dev/null; do
        mb=$(rss_mb); [ "$mb" -gt "$peak" ] && peak=$mb
        sleep 0.1
      done
      wait $pid
      printf '%s\t%s\t%s\t%.2f\t%s\n' "$name" "$mode" "$run" "$(perl -e "print $(now) - $start")" "$peak" >> "$out"
    done
  done
done
