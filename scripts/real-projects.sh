#!/usr/bin/env bash
# Clones the real-world projects used in docs/results.md, at the commits
# measured, into <dir> (skipping ones already there), and prints their
# `bench.sh` specs, one per line:
#
#   scripts/bench.sh -n 3 -c check $(scripts/real-projects.sh ~/hs-real)
#
# Pass project names after <dir> to select some.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir=${1:?usage: $0 <dir> [project...]}
shift
mkdir -p "$dir"

# name, repository, commit, extra cargo arguments (- for none)
projects="
atuin         https://github.com/atuinsh/atuin               c319bf20157ee3b3a93c16c9dfa2df03d597f920 -
bevy          https://github.com/bevyengine/bevy             92a29e701a6b0bf8846484c3999c2ba97d90dd06 -
helix         https://github.com/helix-editor/helix          ba40e547426b0f9896c8bdc699a4ab11f2b37dbc -
lemmy         https://github.com/LemmyNet/lemmy              f1476db8785600db709e6e01df331e00cffbe340 -
lldap         https://github.com/lldap/lldap                 99c510a7a603df1cdaca00a9ffff95ec73b296eb -
nushell       https://github.com/nushell/nushell             2459fdd134ea4fdbae42efd6924e2b41201cf363 -
polars        https://github.com/pola-rs/polars              3479b49e806d363fc45d59b387a2dd83de99fb32 -
rust-analyzer https://github.com/rust-lang/rust-analyzer     03fcb77246f2568adb0e9b2fa60d19c6cc1686f4 -
typst         https://github.com/typst/typst                 9f2b6e8715237cb086899a42873660fe744622e8 -
vaultwarden   https://github.com/dani-garcia/vaultwarden     061694d0cb3bbf5d4c7e920c892824f0020cff83 --features=sqlite
wasmtime      https://github.com/bytecodealliance/wasmtime   a7b4f29596bf686c9293459e29a9d669b79ec503 -
zed           https://github.com/zed-industries/zed          bd747337d7be138834e20972b9e203c7b239cc47 -
zola          https://github.com/getzola/zola                42c89b67214477358a9a4de14f181c474d31a937 -
"

want=" $* "
echo "$projects" | while read -r name url commit args; do
  [ -n "$name" ] || continue
  [ $# -eq 0 ] || [[ $want == *" $name "* ]] || continue
  dest=$dir/$name
  if [ ! -d "$dest" ]; then
    # Clone next to the destination, and move it into place when complete.
    tmp=$dest.partial
    rm -rf "$tmp"
    git init -q "$tmp"
    git -C "$tmp" fetch -q --depth 1 "$url" "$commit"
    git -C "$tmp" checkout -q FETCH_HEAD
    # lemmy's email templates are a submodule its build script reads.
    # Others (wasmtime's test suites) were measured without theirs.
    if [ "$name" = lemmy ]; then
      git -C "$tmp" submodule -q update --init --depth 1
    fi
    # bevy doesn't commit a lockfile; this is the one it was measured with.
    if [ -f "$root/projects/$name.Cargo.lock" ]; then
      cp "$root/projects/$name.Cargo.lock" "$tmp/Cargo.lock"
    fi
    mv "$tmp" "$dest"
  fi
  if [ "$args" = - ]; then echo "$dest"; else echo "$dest::$args"; fi
done
