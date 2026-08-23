# MoonBit `--target wasm-gc` fixtures (Phase 10 / GC)

**Toolchain**: `moon 0.1.20260819 (fc2a4ee 2026-08-19)`,
`moonc v0.10.9+6e6c44045 (2026-08-19)`, installed via the official MoonBit
installer (`~/.moon/bin`). **Not** in `devShells.gen` — nixpkgs availability
was not verified, so this follows the hand-generated realworld pattern: the
`.wasm` is committed and runs on every host through the edge-runner.

- `gc_shapes.{mbt,wasm,expect}` — the corpus's first fixture emitted by a
  toolchain whose native backend is wasm-gc. `test()->i32` = 658.
  moonc scalar-replaces structs that stay local, so the guest deliberately
  routes every allocation through a function boundary or a recursive call
  to keep the GC instructions in the emitted code.
- `gc_nullable_walk.{mbt,wasm,expect}` — the nullable-reference walk the
  section below stages as `gc_shapes`'s upgrade path. `test()->i32` = 240.
  A recursive `Node?` chain (`struct Node { val : Point; next : Node? }`)
  built and walked by recursion: moonc narrows the nullable field with
  `ref.as_non_null` and then reads two fields off the narrowed ref, which is
  the shape #245 miscompiled. Added with the #245 fix; red before it
  (`expected i32:240, got i32:32`).

**Emitted GC surface** (`wasm-tools print`, custom sections excluded).
`gc_shapes`: 8 GC typedefs in a `(sub …)` / `(sub final …)` hierarchy, 48 GC
instructions — `struct.new` ×8, `struct.get` ×25, `ref.cast` ×3, and
non-nullable `(ref $t)` in function params, results, and struct fields.
`gc_nullable_walk`: 2 struct typedefs, one of them self-referential through a
nullable field (`(struct (field (ref 0)) (field (ref null 1)))`), 18 GC
instructions — `struct.get` ×8, `ref.as_non_null` ×3, `ref.is_null` ×3,
`struct.new` ×2, `ref.null none` ×2. The two `ref.null none` sit in
`(ref null $concrete)` block results — the #224 bottom edge #231 fixed, which
`gc_shapes` does not carry.

**Build** (same for both; `<name>` = the fixture's basename):

```sh
moon new <name>    # then replace the three files below
moon build --target wasm-gc --release
cp _build/wasm-gc/release/build/cmd/main/main.wasm <name>.wasm
```

`moon.mod`:

```
name = "zwasm/<name>"

version = "0.1.0"
```

`cmd/main/moon.pkg.json` — `test` is a MoonBit keyword, so the export is
renamed at link time to the name the edge-runner invokes:

```json
{
  "is-main": true,
  "link": { "wasm-gc": { "exports": ["compute:test"] } }
}
```

`cmd/main/main.mbt` = `<name>.mbt`.

**Determinism** (both fixtures): no imports, no `memory.grow`, no float, no
time or randomness source (`wasm-tools print` count = 0 for all of those).
Three wasmtime runs byte-identical; two clean rebuilds byte-identical by
sha256. Rebuilding `gc_shapes.mbt` on the toolchain pinned above reproduces
the committed `gc_shapes.wasm` byte-for-byte
(sha256 `88ab3c5d51b878798fc45dd39012692882a2b28a39f957ad95377d210ff824f8`).

**Result-check**: `zig build test-edge-cases` → `run_edge_realworld_p10` →
`runI32Export` `test` → `.expect` = `i32: 658` / `i32: 240`. That lane is
JIT-only; the interpreter was verified by hand (`zwasm run --engine interp
--invoke test` = 658 / 240, matching wasmtime 47.0.3). **Status**: ACTIVE.

## Scope: what `gc_shapes` does NOT cover

Measured 2026-08-22, x86_64-linux, Debug. Two engine defects bound the guest;
both are `src/` product defects, filed separately, not worked around here.
**#245 has since landed** — `gc_nullable_walk` is the guest this section said
was blocked on it, and it now guards that fix. #244 still stands, so both
fixtures remain loop-free.

The guest is written to steer around them, but what matters is the **emitted**
module, not the source — moonc is free to introduce either shape on its own.
Audit the committed bytes:

```sh
wasm-tools print gc_shapes.wasm | grep -cE 'ref\.as_non_null|\bloop\b'   # must be 0
wasm-tools print gc_nullable_walk.wasm | grep -cE '\bloop\b'             # must be 0
```

Measured 0 and 0. The first command returns 1 on a guest that carries the
bottom edge and 1 on the #244 repro, so it fires rather than being vacuous
(`gc_nullable_walk` is such a guest — 3, by construction). The widest functype
in either module has 1 result, well under #246's cap of 16.
**Re-run this after any regeneration.**

The audit is a diagnostic, not the safety net — the static `.expect` is.
Measured by simulation: dropping a module that *does* emit `ref.as_non_null`
into this lane with its wasmtime-correct expectation fails it
(`expected i32:140, got i32:0`, lane exit 1). A regeneration that introduces
a miscompiled shape therefore cannot pass quietly; it turns the lane red and
the audit says why.

- **No loops** (#244, with #246 behind how it surfaces). A `loop` whose block
  type takes a parameter traps `unreachable` in the interpreter, where
  wasmtime and the JIT both compute it; `block (param …)` is fine. moonc
  emits that shape for every `for`, so any looping guest is interp-red. GC is
  not involved — it reproduces in plain wat.
- **No `ref.as_non_null` at all** — `gc_shapes` predates the #245 fix, and its
  guest reaches every struct through a value moonc already knows is non-null,
  so the narrowing op never appears. That is now a property of this fixture,
  not a limitation of the engine: `gc_nullable_walk` carries the op three
  times and is checked against the same oracle.

**`gc_shapes` alone does not guard the #231 regression.** The bottom edge #224
reported and #231 fixed (`ref.null none` into a concrete ref slot) needs a
guest like a `Node?` linked list, and every such guest was miscompiled by #245
— which is why `gc_shapes` passes identically at `28964b42a` (pre-#231) and
after. `gc_nullable_walk` is that guest: it emits `ref.null none` into two
`(ref null $concrete)` block results (measured on the committed bytes). Its
verdict against a pre-#231 tree has not been re-measured here.

What these fixtures do is put a real wasm-gc-emitting toolchain into a lane
that walks it and checks a value — the gap #226 records for the GC leg.
