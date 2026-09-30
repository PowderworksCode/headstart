#!/usr/bin/env bash
# Checks that headstart doesn't change what a build reports: for each
# scenario in tests/errors (clean, an error in a dependency's body, an error
# in the binary), `cargo check` and `cargo build` must print the same
# diagnostics, the same JSON messages and exit the same with headstart off
# and on, and a built binary must print the same. Output that already
# depends on timing is ignored: progress lines (`Checking`, `Compiling`,
# `Finished`), "waiting for other jobs", lock waits (`Blocking`), and the
# order of JSON messages across crates.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export RUSTC=$root/rustc/build/host/stage1/bin/rustc RUSTC_WRAPPER=
cargo=$root/cargo/target/release/cargo
tmp=$(mktemp -d)
cd "$root/tests/errors"
status=0
for command in check build; do
for scenario in "" "--features slow/broken" "--features app/broken"; do
  for mode in 0 1; do
    for format in human json; do
      rm -rf target
      CARGO_HEADSTART=$mode "$cargo" $command --color never --message-format "$format" $scenario \
        >"$tmp/$format.$mode.out" 2>"$tmp/$format.$mode.err"
      echo "exit $?" >>"$tmp/$format.$mode.out"
      if [ -x target/debug/app ]; then target/debug/app >>"$tmp/$format.$mode.out" 2>&1; fi
      # Cargo doesn't order JSON messages across crates (it varies with -j),
      # and headstart holds a crate's messages until its dependencies finish.
      if [ $format = json ]; then sort -o "$tmp/$format.$mode.out" "$tmp/$format.$mode.out"; fi
      grep -v -e '^ *Checking ' -e '^ *Compiling ' -e '^ *Finished ' -e '^ *Blocking ' -e 'build failed, waiting for other jobs' "$tmp/$format.$mode.err" \
        >"$tmp/$format.$mode.err.filtered"
    done
  done
  for format in human json; do
    if diff -q "$tmp/$format.0.out" "$tmp/$format.1.out" >/dev/null &&
      diff -q "$tmp/$format.0.err.filtered" "$tmp/$format.1.err.filtered" >/dev/null; then
      echo "same   $command ${scenario:-clean} ($format)"
    else
      echo "DIFFER $command ${scenario:-clean} ($format)"
      diff "$tmp/$format.0.err.filtered" "$tmp/$format.1.err.filtered"
      diff "$tmp/$format.0.out" "$tmp/$format.1.out"
      status=1
    fi
  done
done
done
rm -rf "$tmp"
exit $status
