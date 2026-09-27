#!/usr/bin/env bash
# Check out the pinned rustc and cargo, apply headstart's patches, install
# the rustc build config, and build both tools:
#
#   scripts/setup.sh
#
# Afterwards: rustc/build/host/stage1/bin/rustc and cargo/target/release/cargo.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
git submodule update --init --depth 1 rustc cargo

apply() { # <repo> <patch dir>
  if [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; then
    echo "$1/ has local changes; not re-applying patches over them." >&2
    echo "Inspect them with: git -C $1 diff" >&2
    return
  fi
  for patch in "$2"/*.patch; do
    echo "applying $patch"
    git -C "$1" apply "$root/$patch"
  done
}
apply rustc patches/rustc
apply cargo patches/cargo
cp config/bootstrap.toml rustc/bootstrap.toml

(cd rustc && ./x build --stage 1 compiler library)
# The pinned cargo needs Rust 1.98 or newer to build.
(cd cargo && cargo "+${HEADSTART_TOOLCHAIN:-1.98.0}" build --release)
echo "ready: rustc/build/host/stage1/bin/rustc, cargo/target/release/cargo"
