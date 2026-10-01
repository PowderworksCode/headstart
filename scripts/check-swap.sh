#!/usr/bin/env bash
# Checks that a library that starts on its dependency's early metadata, and
# pauses for the full metadata before code generation, builds exactly as it
# would from full metadata, at every optimization level:
#
#   scripts/check-swap.sh
#
# `dep` is compiled first. Its full metadata and rlib are then hidden, and
# their lock files held, as if `dep` were still compiling, so `mid` starts
# from early metadata, and writes its own early metadata from it. They're
# restored, and the locks released, once `mid` announces it's waiting for
# them. A program using `mid` must print the same as when `mid` is built
# from full metadata.
#
# Then `dep` "fails": its locks are released without the full metadata
# coming back. `mid` must stop with an error instead of waiting.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rustc=${RUSTC:-$root/rustc/build/host/stage1/bin/rustc}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/dep.rs" <<'EOF'
pub fn small(x: u32) -> u32 { x + 1 }
pub fn generic<T: Default + std::fmt::Debug>() -> String { format!("{:?}", T::default()) }
#[inline]
pub fn hinted(x: u64) -> u64 { x * 3 }
pub async fn later(x: u32) -> u32 { small(x) }
EOF
cat > "$work/mid.rs" <<'EOF'
pub fn poll<F: std::future::Future>(f: F) -> F::Output {
    let waker = std::task::Waker::noop();
    let mut cx = std::task::Context::from_waker(waker);
    let mut f = std::pin::pin!(f);
    loop {
        if let std::task::Poll::Ready(v) = f.as_mut().poll(&mut cx) {
            return v;
        }
    }
}
pub fn calls() -> String {
    format!("{} {} {}", dep::small(1), dep::generic::<u32>(), dep::hinted(2))
}
pub fn run() -> String {
    format!("{} {}", calls(), poll(dep::later(4)))
}
EOF
echo 'fn main() { println!("{}", mid::run()); }' > "$work/main.rs"

# Holds exclusive locks on the given files, like a compilation that hasn't
# written the outputs they guard yet, until it's killed. Prints its PID once
# they're held.
hold_locks() {
  perl -e 'use Fcntl ":flock"; my @held;
    for (@ARGV) { open(my $f, ">", $_) or die "$_: $!"; flock($f, LOCK_EX) or die; push @held, $f }
    $| = 1; print "$$\n"; sleep 600' "$@"
}

# Waits until the compilation logging to $1 (PID $2) announces it's waiting.
wait_for_pause() {
  for _ in $(seq 600); do
    grep -q '"emit":"wait-metadata"' "$1" && return
    kill -0 "$2" 2>/dev/null || return
    sleep 0.05
  done
}

status=0
for opt in 0 1 2 3 s z; do
  out=$work/$opt
  mkdir -p "$out/hidden"
  common=(-Zearly-metadata -C opt-level=$opt --edition=2024 -L "dependency=$out")
  lib=(--crate-type lib --emit=metadata,link -C extra-filename=-x --out-dir "$out")
  mid=("${lib[@]}" --crate-name mid --extern "dep=$out/libdep-x.rmeta" "$work/mid.rs")
  main=(--crate-name main --extern "mid=$out/libmid-x.rlib" "$work/main.rs")
  "$rustc" "${common[@]}" "${lib[@]}" --crate-name dep "$work/dep.rs"

  # From full metadata.
  "$rustc" "${common[@]}" "${mid[@]}"
  "$rustc" "${common[@]}" "${main[@]}" -o "$out/direct"
  want=$("$out/direct")
  rm -f "$out"/libmid-x.*

  # From early metadata, swapping in the full metadata while paused.
  mv "$out/libdep-x.rmeta" "$out/libdep-x.rlib" "$out/hidden/"
  exec 3< <(hold_locks "$out/libdep-x.rmeta.lock" "$out/libdep-x.rlib.lock")
  read -r locker <&3
  log=$out/swap.log
  "$rustc" "${common[@]}" "${mid[@]}" -Zearly-metadata-verify \
    --error-format=json --json=artifacts 2> "$log" &
  pid=$!
  wait_for_pause "$log" $pid
  paused=$(grep -c '"emit":"wait-metadata"' "$log" || true)
  mv "$out/hidden/"* "$out/"
  kill "$locker"; exec 3<&-
  if ! wait $pid; then
    echo "opt-level=$opt: build from early metadata failed:"
    grep -o '"rendered":"[^"]*' "$log" | head -5
    status=1
    continue
  fi
  "$rustc" "${common[@]}" "${main[@]}" -o "$out/swapped"
  got=$("$out/swapped")
  if grep -q '^early-metadata-verify' "$log"; then
    echo "opt-level=$opt:"; grep '^early-metadata-verify' "$log" | sort -u; status=1
  elif [ "$paused" = 0 ]; then
    echo "opt-level=$opt: never paused"; status=1
  elif [ "$got" != "$want" ]; then
    echo "opt-level=$opt: printed '$got', expected '$want'"; status=1
  else
    echo "opt-level=$opt: ok ($got)"
  fi

  # From early metadata, and the dependency fails: its locks are released
  # without the full metadata.
  rm -f "$out"/libmid-x.*
  mv "$out/libdep-x.rmeta" "$out/libdep-x.rlib" "$out/hidden/"
  exec 3< <(hold_locks "$out/libdep-x.rmeta.lock" "$out/libdep-x.rlib.lock")
  read -r locker <&3
  log=$out/fail.log
  "$rustc" "${common[@]}" "${mid[@]}" --error-format=json --json=artifacts 2> "$log" &
  pid=$!
  wait_for_pause "$log" $pid
  kill "$locker"; exec 3<&-
  if wait $pid; then
    echo "opt-level=$opt: built although the dependency failed"; status=1
  elif ! grep -q 'a dependency failed to compile after writing early metadata' "$log"; then
    echo "opt-level=$opt: failed, but not as expected:"
    grep -o '"rendered":"[^"]*' "$log" | head -5
    status=1
  fi
  mv "$out/hidden/"* "$out/"
done
exit $status
