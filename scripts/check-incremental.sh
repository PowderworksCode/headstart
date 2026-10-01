#!/usr/bin/env bash
# Checks headstart under incremental compilation: runs one sequence of
# edits to a copy of tests/errors twice, with headstart off and on, each in
# its own directory, and compares the output after every step. Finally
# compares both against a clean build of the last state.
#
#   scripts/check-incremental.sh [check|build]
#
# With `build`, each step also runs the built binary.
set -uo pipefail
command=${1:-check}
root="$(cd "$(dirname "$0")/.." && pwd)"
export RUSTC=$root/rustc/build/host/stage1/bin/rustc RUSTC_WRAPPER= CARGO_INCREMENTAL=1
cargo=$root/cargo/target/release/cargo
tmp=$(mktemp -d)
for mode in 0 1; do
  cp -R "$root/tests/errors" "$tmp/ws$mode"
  rm -rf "$tmp/ws$mode/target"
done

step() { # <name> <edit command, run in the workspace>
  local name=$1 edit=$2 mode out
  for mode in 0 1; do
    (cd "$tmp/ws$mode" && eval "$edit" && sleep 1 &&
      CARGO_UNSTABLE_HEADSTART=$([ $mode = 1 ] && echo true || echo false) "$cargo" $command --color never --message-format short 2>&1 |
        grep -v -e '^ *Checking ' -e '^ *Compiling ' -e '^ *Finished ' -e '^ *Blocking ' -e 'build failed, waiting for other jobs' > "$tmp/$name.$mode"
      echo "exit ${PIPESTATUS[0]}" >> "$tmp/$name.$mode"
      if [ $command = build ] && [ -x target/debug/app ]; then target/debug/app >> "$tmp/$name.$mode" 2>&1; fi)
  done
  if diff -q "$tmp/$name.0" "$tmp/$name.1" >/dev/null && ! grep -q "panicked\|internal compiler error" "$tmp/$name.1"; then
    echo "same   $name ($(tail -1 "$tmp/$name.1"))"
  else
    echo "DIFFER $name"; diff "$tmp/$name.0" "$tmp/$name.1"; status=1
  fi
}
status=0
step initial ":"
step body-edit "sed -i.bak 's/wrapping_mul(3)/wrapping_mul(4)/' slow/src/lib.rs"
step add-opaque "printf 'pub fn adder(n: u64) -> impl Fn(u64) -> u64 { move |x| x + n }\n' >> slow/src/lib.rs &&
  printf 'pub fn two() -> u64 { slow::adder(1)(1) }\n' >> mid/src/lib.rs"
step change-opaque "sed -i.bak 's/move |x| x + n }/move |x| x * n + [0u64; 2].len() as u64 }/' slow/src/lib.rs"
step interface-break "sed -i.bak 's/pub fn make() -> Widget { Widget(busy_0()) }/pub fn make() -> Option<Widget> { None }/' slow/src/lib.rs"
step interface-fix "sed -i.bak 's/pub fn make() -> Option<Widget> { None }/pub fn make() -> Widget { Widget(busy_0()) }/' slow/src/lib.rs"
step body-error "printf 'pub fn oops() -> u32 { \"no\" }\n' >> slow/src/lib.rs"
step body-fix "sed -i.bak '/pub fn oops/d' slow/src/lib.rs"
step app-edit "sed -i.bak 's/mid::widget().0/mid::widget().0 + mid::two()/' app/src/main.rs"
step touch-all "touch slow/src/lib.rs mid/src/lib.rs app/src/main.rs"

# The final incremental state against a clean build of the same sources.
for mode in 0 1; do
  (cd "$tmp/ws$mode" && rm -rf target && CARGO_UNSTABLE_HEADSTART=$([ $mode = 1 ] && echo true || echo false) "$cargo" $command --color never --message-format short 2>&1 |
    grep -v -e '^ *Checking ' -e '^ *Compiling ' -e '^ *Finished ' -e '^ *Blocking ' -e 'build failed, waiting for other jobs' > "$tmp/clean.$mode"; echo "exit ${PIPESTATUS[0]}" >> "$tmp/clean.$mode"
    if [ $command = build ] && [ -x target/debug/app ]; then target/debug/app >> "$tmp/clean.$mode" 2>&1; fi)
done
if diff -q "$tmp/clean.0" "$tmp/touch-all.1" >/dev/null && diff -q "$tmp/clean.1" "$tmp/touch-all.1" >/dev/null; then
  echo "same   final state vs clean build"
else
  echo "DIFFER final state vs clean build"; diff "$tmp/clean.0" "$tmp/touch-all.1"; diff "$tmp/clean.1" "$tmp/touch-all.1"; status=1
fi
rm -rf "$tmp"
exit $status
