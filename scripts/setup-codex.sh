#!/usr/bin/env bash
# Clones openai/codex at the commit measured in docs/results.md into
# <dir>/codex, makes it build with the patched rustc, and prints its
# `bench.sh` spec:
#
#   source <dir>/codex/headstart.env    # V8 overrides, see below
#   scripts/bench.sh -n 3 -w -c check "$(scripts/setup-codex.sh ~/hs-real)"
#
# Three things differ from building codex-rs upstream:
# - `allocative` 0.3.6 is patched in, without its `impl Allocative for !`:
#   on rustc 1.101-dev, `Infallible` is `!`, and the impl conflicts (E0119).
# - V8 comes from codex's own prebuilt release, checksummed against the
#   manifest codex commits, as its CI does. `headstart.env` points the
#   `v8` crate at it.
# - `codex-voice-host` is left out of the workspace build: it needs
#   GStreamer >= 1.28.
#
# A debug `cargo build` of the workspace needs more than 15 GB of RAM at
# `-j4`: codex-core's rustc alone reaches 13.7 GB.
set -euo pipefail
dir=${1:?usage: $0 <dir>}
commit=57a38c1bebc77a04565b5a8ff08110f62f9f6e5d
dest=$dir/codex
mkdir -p "$dir"

if [ ! -d "$dest" ]; then
  tmp=$dest.partial
  rm -rf "$tmp"
  git init -q "$tmp"
  git -C "$tmp" fetch -q --depth 1 https://github.com/openai/codex "$commit"
  git -C "$tmp" checkout -q FETCH_HEAD

  # allocative, without `impl Allocative for !`.
  crate=$tmp/allocative-0.3.6.crate
  curl -fsSL https://static.crates.io/crates/allocative/allocative-0.3.6.crate -o "$crate"
  echo "d8cf9afc79c83d514444b55df3935d317da54b1ce3b17a133c646889cc260de8  $crate" | sha256sum --check --quiet -
  tar xzf "$crate" -C "$tmp"
  rm "$crate"
  python3 - "$tmp" <<'PY'
import sys
root = sys.argv[1]
path = f"{root}/allocative-0.3.6/src/impls/std/unsorted.rs"
src = open(path).read()
impl = """#[cfg(rust_nightly)]
impl Allocative for ! {
    fn visit<'a, 'b: 'a>(&self, _visitor: &'a mut Visitor<'b>) {
        match *self {}
    }
}
"""
assert impl in src
open(path, "w").write(src.replace(impl, "// headstart: removed `impl Allocative for !`; on rustc 1.101-dev, `Infallible` is `!`.\n"))
manifest = f"{root}/codex-rs/Cargo.toml"
toml = open(manifest).read()
anchor = "[patch.crates-io]\n"
assert anchor in toml
open(manifest, "w").write(toml.replace(anchor, anchor + 'allocative = { path = "../allocative-0.3.6" }\n', 1))
PY

  # codex's prebuilt V8, as .github/actions/setup-rusty-v8 fetches it.
  target=$(rustc -vV | sed -n 's/^host: //p')
  version=$(python3 "$tmp/.github/scripts/rusty_v8_bazel.py" resolved-v8-crate-version)
  base=https://github.com/openai/codex/releases/download/rusty-v8-v$version
  profile=ptrcomp_sandbox_release
  archive=librusty_v8_${profile}_$target.a.gz binding=src_binding_${profile}_$target.rs
  sums=rusty_v8_${profile}_$target.sha256
  v8=$tmp/rusty_v8
  mkdir -p "$v8"
  for f in "$sums" "$archive" "$binding"; do curl -fsSL "$base/$f" -o "$v8/$f"; done
  grep -F "  $sums" "$tmp/third_party/v8/rusty_v8_${version//./_}_release_manifests.sha256" |
    (cd "$v8" && sha256sum --check --quiet -)
  (cd "$v8" && tr -d '\r' < "$sums" | sha256sum --check --quiet -)
  cat > "$tmp/headstart.env" <<EOF
export RUSTY_V8_ARCHIVE=$dest/rusty_v8/$archive
export RUSTY_V8_SRC_BINDING_PATH=$dest/rusty_v8/$binding
EOF
  mv "$tmp" "$dest"
fi
echo "$dest/codex-rs::--workspace --exclude codex-voice-host"
