# Design

## The idea

A crate's dependents compile against its metadata (`.rmeta`): its items'
signatures, types, trait impls, and the MIR of anything they might
evaluate at compile time. Today rustc writes that metadata only after
every function body has been type-checked and borrow-checked. Those are
answers dependents almost never need.

Headstart writes the metadata as soon as the item interfaces are checked,
before any function body is. Build tools can start dependent crates right
away, while the crate itself goes on checking its bodies. If a body turns
out to be wrong, the crate still fails, and so does the build. The
dependents' work is simply thrown away.

That is the "dangerous" part: dependents are compiled against a promise.
If the promise holds, which it does whenever the build succeeds, the
dependents' results are exactly what they would have been.

## rustc: `-Zearly-metadata`

`rustc_hir_analysis::check_crate` is split in two:

- `check_crate_interfaces`: well-formedness and coherence of every item.
- `check_crate_bodies`: evaluates statics and consts, then type-checks
  every body.

Between the two, `run_required_analyses` calls `write_early_metadata`,
which encodes and writes the `.rmeta` and emits the `--json=artifacts`
notification that cargo listens for. `start_codegen` reuses that
metadata instead of encoding it again.

The early write only happens for metadata-only builds (`--emit=metadata`
without codegen, which is `cargo check`), and only if no errors have been
reported so far.

### What encoding still forces

The encoder asks the query system for whatever the metadata contains, so
anything a crate's interface depends on is computed on demand, bodies
included:

- **Opaque types.** The hidden type of an `impl Trait` in a signature
  comes from type-checking the defining function's body.
- **Constants.** The encoder records the MIR (or value) of consts,
  `const fn`s and array lengths, which means building their bodies.
- **Statics.** Every static is evaluated before the write. Evaluation can
  create new definitions (nested allocations), and the definitions table
  is frozen once metadata is encoded.
- **Coroutines.** `async fn` and `async` block state machines are
  encoded with their witnesses, because dependents read them to decide
  whether a future is `Send`. Their bodies are checked before the write.
- **Async closures.** Their by-move bodies are synthesized first, for the
  same reason as statics.

Everything else waits until after the write.

### What early metadata leaves out

Closures, inline consts and const arguments (`foo::<3>()`) inside a
function body are definitions of their own. Their types come from
type-checking the enclosing body. Encoding them would force every body,
which is the cost this change avoids. So in early mode the encoder defers
them to the end. It encodes a deferred item only if something else
already forced its enclosing body, for example an opaque type or a const,
and repeats until nothing new is forced. The rest are left out.

A dependent `cargo check` can't name those definitions. It only ever sees
them through types or MIR that come from a forced body, and those are
exactly the ones that get encoded.

`required_panic_strategy` is also left out, because computing it scans
the MIR of every body. Only linking reads it, and check builds don't
link.

The encoder also skips computing the crate's reachable set. It only
consults that set when generating code, and computing it walks the bodies
of every `#[inline]` and generic function. Before this fix, the early
write forced about 8× more work than the same encoding costs today (see
[results.md](results.md)).

Because of these omissions, early metadata is never used for an rlib.

## cargo: `CARGO_HEADSTART=1`

Cargo already pipelines `cargo build`: an rlib dependent starts when its
dependency's `.rmeta` is announced. It doesn't pipeline `cargo check`,
where every dependency edge waits for the dependency's rustc to exit.

With `CARGO_HEADSTART=1`:

- `BuildRunner::only_requires_rmeta` also holds between check units. The
  job queue then releases a check unit's dependents on the `.rmeta`
  notification, as it does for pipelined builds.
- Each check unit that has such dependents is passed `-Zearly-metadata`.
- A check unit doesn't get the synthetic edges that cargo adds for units
  that link. Normally a binary also waits for the *full* build of every
  transitive dependency, because it links against them. A check build
  never links, so those edges would only make binaries wait for their
  whole dependency tree to finish checking.
- **Only error-free dependencies get their output reported.** A unit that
  started before its dependencies finished is provisional. Its
  diagnostics, its JSON messages and its own result are held until every
  dependency has finished cleanly, and then emitted in their original
  order. If a dependency fails, they're dropped. A held unit still frees
  its job slot and unblocks its dependents as usual. So a failing build
  prints the same diagnostics, JSON messages and exit status as today.
  The only difference is the `Checking` progress lines of the dependents
  that started early.

With the variable unset, cargo behaves exactly as upstream.

## Risks

- **A crate's own errors surface a little later.** They're delayed by the
  early write: 4 ms for the median crate in cargo-0.87.1's build, and
  249 ms at p99 (see [results.md](results.md)). This is the objection
  that stopped the 2019 attempt ([rust-lang/rust#64112]); here the cost
  is measured.
- **Wasted work on failure.** If a crate's body fails to check, its
  dependents have already started, and their work is thrown away. The
  output is still the same as today (see above).
- **Incremental builds.** Early metadata is written from inside the
  `analysis` query. The patch lets the encoder read the definitions table
  without depending on `analysis`, which it normally does. That's fine
  for clean builds; it hasn't been examined for incremental reuse.
- **Coverage.** Anything the metadata needs from a body and that the
  encoder doesn't know to force would show up as an ICE: a missing entry
  in a dependent, or a definition created after the freeze. The benchmark
  sweep is how we look for those (see [results.md](results.md)).

## Prior art

In 2019, Nicholas Nethercote moved metadata writing before type-checking
and borrow-checking in [rust-lang/rust#64112]. He measured debug and
release builds, where code generation dominates and cargo already
overlaps it with dependents, and saw at most 1.07×. He abandoned the
change because "it wasn't much of a win, and it would slightly delay
error message emission"
([blog](https://blog.mozilla.org/nnethercote/2019/10/11/how-to-speed-up-the-rust-compiler-some-more-in-2019/)).
The approach wasn't tried on check builds, and cargo doesn't pipeline
those at all. In a check build, type-checking bodies *is* the work, and
the metadata carries almost no MIR.

David Lattimore's
["Speeding up rustc by being lazy"](https://davidlattimore.github.io/posts/2024/06/05/speeding-up-rustc-by-being-lazy.html)
(2024) proposes a first step that writes an `.rmeta` with "only what's
needed to check dependent crates" and then finishes the error checking.
He framed it as a way to speed up full builds.

[rust-lang/rust#64112]: https://github.com/rust-lang/rust/pull/64112
