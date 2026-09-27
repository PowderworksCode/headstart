#!/usr/bin/env bash
# Incremental `cargo check` after an edit, headstart off and on: the dev
# loop. Each run appends a unique marker to a function body in <file> (so
# the crate and everything depending on it re-checks), then times
# `cargo check` in a warm target dir per mode.
#
#   scripts/bench-incremental.sh [-n runs] <project dir> <file> <fn signature prefix>
#
# e.g. scripts/bench-incremental.sh cargo crates/cargo-util/src/paths.rs "pub fn normalize_path"
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
runs=5
while getopts n: opt; do
  case $opt in n) runs=$OPTARG ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
dir=$(cd "$1" && pwd) file=$2 fn=$3
export RUSTC=$root/rustc/build/host/stage1/bin/rustc RUSTC_WRAPPER= CARGO_INCREMENTAL=1
cargo=$root/cargo/target/release/cargo
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
cp "$dir/$file" "$dir/$file.orig"
trap 'mv "$dir/$file.orig" "$dir/$file"' EXIT
check() { # <mode>
  (cd "$dir" && CARGO_TARGET_DIR="$dir/target-hs$1" CARGO_HEADSTART=$1 "$cargo" check -q --offline >/dev/null 2>&1)
}
check 0; check 1 # warm both target dirs
for run in $(seq "$runs"); do
  # A body-only edit: a new statement at the start of the function.
  perl -0pi -e "s/(\Q$fn\E[^{]*\{)/\$1 let _headstart_edit = $run;/" "$dir/$file"
  for mode in 0 1; do
    start=$(now); check $mode; status=$?
    printf '%s\t%s\t%s\t%.2f\t%s\n' "$(basename "$dir"):$file" "$([ $mode = 1 ] && echo on || echo off)" "$run" "$(perl -e "print $(now) - $start")" "$status"
  done
done
