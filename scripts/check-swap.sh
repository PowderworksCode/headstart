#!/usr/bin/env bash
# Checks that a library that starts on its dependency's early metadata, and
# pauses for the full metadata before code generation, builds exactly as it
# would from full metadata, at every optimization level:
#
#   scripts/check-swap.sh
#
# `dep` is compiled first. Its full metadata and rlib are then hidden, so
# `mid` starts from early metadata, and writes its own early metadata from
# it. They're restored once `mid` announces it's waiting for them. A program
# using `mid` must print the same as when `mid` is built from full metadata.
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
  log=$out/swap.log
  "$rustc" "${common[@]}" "${mid[@]}" -Zearly-metadata-verify \
    --error-format=json --json=artifacts 2> "$log" &
  pid=$!
  for _ in $(seq 600); do
    grep -q '"emit":"wait-metadata"' "$log" && break
    kill -0 $pid 2>/dev/null || break
    sleep 0.05
  done
  paused=$(grep -c '"emit":"wait-metadata"' "$log" || true)
  mv "$out/hidden/"* "$out/"
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
done
exit $status
