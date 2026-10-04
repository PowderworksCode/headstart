# Known bug: "early and full metadata disagree on the SVH"

An incremental rebuild with `-Zearly-metadata` can panic in
`rustc_metadata/src/rmeta/encoder.rs`:

```
assertion `left == right` failed: early and full metadata disagree on the SVH
```

Found on zed (`bd747337`, crate `util`) with this repository's patches on
rustc `6006fd03`, during incremental `cargo check` runs. It's not fixed yet.

## What has to agree

A crate's SVH is its identity: dependents record it, and it's checked when
they load the crate again. With `-Zearly-metadata` a crate writes two
metadata files, and dependents may start on the early one and swap to the
full one, so both must carry the same SVH. It's computed once, while the
early metadata is written, from the early metadata's bytes plus the usual
supplement (the HIR hash and the tracked options). Writing full metadata
then asserts that its SVH is the same.

## How incremental compilation breaks it

When the full metadata's dep node is green, rustc doesn't encode full
metadata again: it reuses the previous session's file (the metadata work
product) and takes the SVH from its header. Early metadata, though, is
encoded from scratch in every session. So in a second session:

1. early metadata is encoded again, and a new SVH is computed from its bytes;
2. full metadata is reused from the first session, with the first session's
   SVH;
3. the assertion compares them, and fails if the early bytes differ at all.

They do differ on zed's `util`, with nothing changed between the sessions.
The two sessions' early metadata files are the same size and differ only
in the 16-byte SVH and in 4 bytes early in the `def-ids` section, where two
entries are swapped. Something is encoded in a different order when its
query result is loaded from the incremental cache than when it's computed.
Non-incremental compilations of the same crate produce identical early
metadata every time.

Upstream rustc doesn't see this: it reuses the metadata file and its SVH
together. Re-encoding one half and asserting it matches the reused other
half is what exposes it.

## Reproducing

- Compile the crate twice with the same `-C incremental` directory and
  `-Zearly-metadata`, changing nothing. The first session succeeds; the
  second panics, every time.
- In cargo terms: a warm incremental `cargo check` of zed with headstart on,
  then any edit that makes cargo rebuild `util`. Every later build fails the
  same way, even with the edit reverted. With headstart off, the same steps
  succeed.
- With `-Zmetadata-crate-hash=no` (the HIR-based SVH, which doesn't hash the
  encoded bytes), the second session succeeds.
- `util` reduced to about 200 lines (part of `command.rs` and `util.rs`)
  still reproduces when compiled against zed's dependencies. A standalone
  crate doesn't yet, so the query whose cached result is ordered
  differently isn't identified.

## Possible fixes

1. **Reuse the SVH with the file.** If the full metadata will be reused,
   write early metadata with the reused SVH, or publish the saved full
   metadata as the early metadata: nothing needs encoding then, so it's
   also faster.
2. **Compute the early SVH from stable inputs** (the HIR hash, the tracked
   options, the dependencies' SVHs) rather than from the encoded bytes, so
   encoding order can't change it.
3. **Find the query whose result is ordered differently when loaded from
   the incremental cache, and fix it.** That's the root cause, and an
   upstream fix; 1 and 2 make headstart robust to it either way.
