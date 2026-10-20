#!/usr/bin/env bash
# Build headstart's rustc the way rustup's nightly is built, for comparisons
# against nightly: no incremental, jemalloc, thin LTO, then PGO and BOLT
# trained on the rustc-perf crates nightly trains on:
#
#   scripts/release.sh
#
# Run after scripts/setup.sh. Takes about an hour on 16 cores and needs about
# 25 GB of disk. Needs jq, and llvm-bolt and merge-fdata (LLVM 19 or newer)
# on PATH for the BOLT step; without them it stops after PGO.
#
# Afterwards: rustc/build-pgo/host/stage2/bin/rustc.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; R=$root/rustc; W=$root/release-work; CARGO=$root/cargo/target/release/cargo
export RUSTC_WRAPPER=   # sccache would hide real compile times and the profile
mkdir -p "$W/pgo"
opts=(--set rust.incremental=false --set rust.jemalloc=true --set rust.lto=thin)

# Compile the crates nightly's PGO/BOLT training uses: check, debug and
# release, headstart off and on. $1 is the rustc to train.
train() {
  git -C "$R" submodule update --init --depth 1 src/tools/rustc-perf
  local B=$R/src/tools/rustc-perf/collector/compile-benchmarks
  for c in externs ctfe-stress-5 cargo-0.87.1 token-stream-stress match-stress \
           tuple-stress diesel-2.2.10 bitmaps-3.2.1 serde-1.0.219-new-solver; do
    rm -rf "$W/crate"; cp -r "$B/$c" "$W/crate"
    local ropts copts
    ropts=$(jq -r '.cargo_rustc_opts // ""' "$W/crate/perf-config.json")
    copts=$(jq -r '.cargo_opts // ""' "$W/crate/perf-config.json")
    for args in "--profile check" "--profile check -Zheadstart" \
                "--profile dev" "--profile dev -Zheadstart" "--release"; do
      rm -rf "$W/crate/target"
      (cd "$W/crate" && RUSTC=$1 RUSTC_BOOTSTRAP=1 CARGO_INCREMENTAL=0 \
        "$CARGO" rustc -j4 $args $copts -- $ropts >/dev/null 2>&1) \
        || echo "warning: $c $args failed"
      ${AFTER_EACH:-true}
    done
  done
  rm -rf "$W/crate"
}

echo "== 1/4 instrumented rustc"
(cd "$R" && ./x build --stage 2 compiler library --build-dir build-pgo-gen \
  "${opts[@]}" --set build.profiler=true --rust-profile-generate="$W/pgo")
echo "== 2/4 PGO training"
train "$R/build-pgo-gen/host/stage2/bin/rustc"
"$R/build/host/ci-llvm/bin/llvm-profdata" merge -o "$W/rustc.profdata" "$W/pgo"
echo "== 3/4 PGO rustc"
(cd "$R" && ./x build --stage 2 compiler library --build-dir build-pgo \
  "${opts[@]}" --rust-profile-use="$W/rustc.profdata" --enable-bolt-settings)
rm -rf "$R/build-pgo-gen"

if ! command -v llvm-bolt >/dev/null; then
  echo "llvm-bolt not found; stopping after PGO (BOLT adds only a few %)."
  exit 0
fi
echo "== 4/4 BOLT"
lib=$(ls "$R"/build-pgo/host/stage2/lib/librustc_driver-*.so)
rm -rf "$W/instr" "$W/fdata"; mkdir -p "$W/fdata"
cp -a "$R/build-pgo/host/stage2" "$W/instr"
llvm-bolt -instrument "$lib" -o "$W/instr/lib/$(basename "$lib")" \
  --instrumentation-file="$W/fdata/prof.fdata" --instrumentation-file-append-pid
# Raw BOLT profiles run to tens of GB; fold them into one file after each build.
fold() {
  local raw; raw=$(find "$W/fdata" -name 'prof.fdata.*')
  [ -n "$raw" ] || return 0
  merge-fdata $raw $( [ -f "$W/rustc.fdata" ] && echo "$W/rustc.fdata" ) > "$W/merged.fdata" 2>/dev/null
  mv "$W/merged.fdata" "$W/rustc.fdata"; rm -f $raw
}
AFTER_EACH=fold train "$W/instr/bin/rustc"
icf=$(llvm-bolt --help | grep -q -- '-icf=<value>' && echo all || echo 1)
llvm-bolt "$lib" -data "$W/rustc.fdata" -o "$W/bolted.so" -reorder-blocks=ext-tsp \
  -reorder-functions=cdsort -split-functions -split-strategy=cdsplit \
  -split-all-cold -jump-tables=move -icf=$icf
mv "$W/bolted.so" "$lib"
rm -rf "$W/instr" "$W/fdata"
echo "ready: $R/build-pgo/host/stage2/bin/rustc"
