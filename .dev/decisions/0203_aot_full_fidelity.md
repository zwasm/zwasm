# ADR-0203: AOT full fidelity — PIC helper indirection, format v0.5, full-runtime load, transparent cache

- **Status**: Implemented (stages 1–5 merged: PRs #137 #138 #139 #140 #141;
  aot-diff 63/63 incl. cache lanes; D-508/515(1)/516/517/518/519 closed)
- **Date**: 2026-07-09
- **Front**: AOT-full-fidelity (D-508 / D-515 / D-516 / D-517 / D-518)
- **Findings base**: `.dev/meta_audits/2026-07-09-aot-full-fidelity-investigation.md`
  (Phase I) + `test/aot/aot_process_diff.zig` (Phase II characterization).

## Context

The `.cwasm` path today is a compute-only parallel mini-runtime
(`aot/{load,run}.zig`): no memory.grow (D-517), no start function (D-518), no
GC/EH, and the emitted code bakes 13 Zig-helper absolute addresses that die
under per-exec ASLR (D-516 — `zwasm compile` emits the landmine silently).
The campaign goal: `.cwasm` loads back into the FULL runtime —
**cache-hit == cache-miss** — across all module classes, with a transparent
on-disk compilation cache (D-508) on top. Peers establish the architecture:
wasmtime (artifact == runtime image, zero load-time relocations, offset-
relative trap tables, two-tier compatibility gate) and wazero (serialize only
relocation-free function bodies; every runtime pointer reached via a context
register + fixed offset; recompute address-bound shims at load).

## Decisions

### D1 — Helper de-baking: `JitRuntime`-field indirection (fixes D-516)

Every `@intFromPtr(&jit_abi.<helper>)` imm64 bake (13 helpers ×
arm64/x86_64: `jitCallIndirectResolve`, the `jitGcAlloc`/array family,
`jitGcRefCast`/`RefTest`, `rethrowFromExnref`) is replaced by a function
pointer stored in a `JitRuntime` field, called `[rt + comptime offset]` —
the in-tree `memory_grow_fn`/`table_grow_fn`/`reify_exnref_fn` precedent and
wazero's context-register pattern. `setupRuntimeLinked` (and every other
JitRuntime producer, incl. the AOT load path) populates the fields in its
own address space.

- Rejected: a WAMR-style `abs64_helper{code_offset, helper_id}` reloc kind
  patched at load — keeps the 32-file bake sprawl, adds reloc machinery, and
  leaves fresh-JIT code position-dependent for no benefit.
- Rejected: PC-relative helper stub islands per module — extra codegen
  complexity; the rt register is already live at every one of these sites.
- Consequence: emitted code bytes become fully position-independent (SIMD
  pools are PC-relative; br_table is branch-chains; direct calls are
  load-time-patched relocs) — the wasmtime "no absolute references" property.
- Perf guard: an `[rt+off]` load replaces a 4-instr imm64 materialize;
  expectation = noise. Verify with the shootout bench pre/post on both
  arches; regression >2% on a hot bench blocks the stage.

### D2 — Load = deserialize into `CompiledWasm`, then the NORMAL setup path

The `.cwasm` loader is re-aimed at rebuilding a real `CompiledWasm`
(code block + per-func metadata + sigs + tables/globals/EH state) and then
calling the SAME `setupRuntimeLinked` a fresh compile uses. `zwasm run
x.cwasm` produces a full `JitInstance`: growable reservation-backed memory
(discharges D-517 by architecture), WASI dispatch, tables, globals, EH
registry, fuel/interrupt — one code path, so cache-hit == cache-miss by
construction (wasmtime's "deserialize takes the same load path" property).

- The `aot/run.zig` mini-runtime is RETIRED from the CLI path once this
  lands (kept only until the swap stage completes; never extended).
- Trap-registry + code-map entries are rebuilt at load against the loaded
  block's address (the linker's `buildAndRegisterTrapEntries` refactored to
  be callable from both producers).

### D3 — Format v0.5: complete the CompiledWasm round-trip + two-tier gate

Additions to the `.cwasm` format (version bumps to `0x0005_0000`; loader
accepts exactly the current version — an old artifact is a cache MISS /
load error, never a partial read):

1. start-function idx (D-518), 2. import func sigs (full wasm-space
`func_sigs`), 3. global valtypes, 4. raw + canonical typeidxs, 5. EH
sections (`exception_table` entries + `tag_param_counts`/slot counts),
6. per-func `oob_stub_off` + a module `bounds_elided` bit (D4), 7. memory
idx_type/page-size-log2/shared flags, 8. passive data/elem segments.

Two-tier gate (wasmtime pattern):
- **Loadability metadata** (in the header): format version, arch tag
  (existing), zwasm version string, bounds mode, feature-relevant flags.
  Mismatch = hard, specific error for explicit `zwasm run x.cwasm`; silent
  miss for the cache path.
- **Cache content key** (D5) is computed OUTSIDE the artifact.

### D4 — Elision + trap-registry serialization (D-515(1))

With D2's guarded run-memory and D3's `oob_stub_off` table, elided-bounds
modules become serializable: producer stamps `bounds_elided`, loader
re-registers `{code_off, oob_stub_off}` against the loaded block (offsets
stay module-relative — the wasmtime offset-relative trap-table model).
`compileWasmForAot`'s forced `.explicit` and
`ElidedBoundsNotAotSerializable` are then lifted. Until this stage, the
refusal stays (soundness over coverage).

### D5 — D-508 transparent cache

- Key: `SHA-256(wasm bytes)`, hex filename.
- Layout: `<cache-root>/zwasm-<version>-<arch>-<os>-<bounds>/<hex>.cwasm`
  (wazero versioned-dir model — version/arch/OS/bounds changes = silent
  whole-dir miss; no config-hash needed because codegen-affecting knobs are
  in the dir key).
- Consult: `zwasm run --cache[=dir] x.wasm` — hit → D2 load path; miss →
  compile, atomic write (temp file + rename), run. ANY cache-side error
  (corrupt file, version drift, load failure) → silent miss + fresh
  compile; the cache can never make `run` fail.
- Eviction v1: none + `--cache-clear` (wazero parity); size-cap LRU is a
  later increment. Default root: the platform user-cache dir; opt-in flag
  first, default-on only after soak (per D-508 row).
- Embedding-API knob after the CLI proves the shape.

### D6 — Staged migration (each stage = one PR, diff-gated)

| Stage | Content | Ratchet effect (test-aot-diff) |
|---|---|---|
| 1 | D1 helper de-baking (both arches) + mini-runtime field population | `.unsound` D-516 rows become deterministic (`.wrong_result`); fresh-JIT unchanged (fuzz-diff + bench guard) |
| 2 | D3 format v0.5 + deserializer → `CompiledWasm` | no lane flips yet (load path unchanged); round-trip unit tests |
| 3 | D2 run-path swap + mini-runtime retirement | MASS flip: D-517 rows (8 Go + rust/cpp/c + mem_grow), D-518 start_func, gc_struct, eh_throw → `.match`; table shrinks to empty |
| 4 | D4 elision serialization (D-515(1)) | elided modules serializable; `.explicit` forcing lifted |
| 5 | D5 cache CLI (`--cache`) | new cache-lane fixtures (hit==miss) |
| 6 | Phase V retrospective: debt close (D-508/515/516/517/518), docs, bench record | — |

### Anti-regression invariants

- `test-aot-diff` expectation table may only SHRINK (RATCHET-FLIP enforces);
  any new `.wrong_result`/`.unsound` entry requires a new D-row + ADR note.
- `test-aot-diff` accounts for its own denominator (ADR-0210 applied to this
  lane): a fixture that is skipped is not a fixture that passed. `skipped_spawn`
  (the harness could not launch a process) and `refused_produce` (`zwasm
  compile` declined the module) both gate. Deliberately narrowing the produce
  envelope therefore updates this gate in the same PR, the way a new divergence
  adds a `known_table` row. Added 2026-08-26 — see the Revision row.
- `fuzz-diff` (interp oracle, D-510) stays green at every stage.
- Stage 1 bench guard on both arches (call_indirect/GC-heavy shootout).
- No new libc sites (ADR-0070); zone layering unchanged (loader stays in
  `engine/codegen/aot/`, setup reuse via existing Zone-2 seams).

## Revision 2026-07-09 (stage-2 survey) — D3 amended: embed the original `wasm_bytes`

The stage-2 survey established that `setupRuntimeLinked` re-decodes ~15
sections directly from `wasm_bytes` (imports, memory incl. idx_type/
page-size/shared, data/elem segments incl. passive tracking, globals +
init-exprs, tables, tags, types) and `runStart` reads it too — the entire
runtime-state build is wasm_bytes-driven, not CompiledWasm-driven. D3 is
therefore amended: **format v0.5 embeds the original `wasm_bytes` as a
section** (raw; compression later), and the loader hands the REAL bytes to
the normal setup path. Consequences: zero re-encode/re-parse divergence
(cache-hit == cache-miss by construction, the D2 goal); v0.4's
globals/memory_init/elem/imports re-encode sections become removable;
artifact size grows by ~the wasm size (acceptable for a cache/compile
artifact whose key IS the source hash); load-time section parse remains
(small vs codegen — measured compile tax is codegen-dominated; individual
reads can migrate to serialized sections later without a format break).
Also fixed by survey: the D-519 dbg-instrumentation refusal lands in
`produceFromCompiledWasm` beside the elided-bounds refusal
(`DbgInstrumentedNotAotSerializable`), backed by a new `dbg.anyActive()`.
What still MUST be serialized (compiler output, not re-derivable):
code + relocs + per-func meta (n_slots, canon+raw typeidx, oob_stub_off),
full wasm-space func_sigs, exception_table.entries (module-relative pcs),
tag_param_counts/slot_counts, globals_offsets/valtypes, start_func_idx,
num_global_imports, bounds_elided bit. NOT serialized (setup/load-derived):
exception_table.tag_ids, trap_func_entries/trap_region_start (rebuilt at
load via `buildAndRegisterTrapEntries`, stage 4).

## Consequences

- D-516's fix (stage 1) benefits fresh JIT too: fully PIC code is a
  prerequisite for any future code-sharing/mmap-cold-start work.
- The mini-runtime's deletion removes a whole divergence surface; the
  "COMPUTE-ONLY" caveats in `aot/run.zig` docs disappear rather than grow.
- `.cwasm` v0.4 artifacts stop loading after stage 2 (version equality).
  Acceptable: pre-release surface, no external consumers pin `.cwasm`
  (cljw pins zwasm by git tag and ships `.wasm`).
- The D-513 optimising-tier decision is untouched — this campaign changes
  where compiled code is STORED, not how it is generated.

## Revision 2026-08-26 — D6 anti-regression invariants: the lane gates its denominator

`test-aot-diff` counted skipped fixtures and printed them, but gated only on
divergence, so a run that differentiated half its corpus still exited 0 — the
shape ADR-0210 exists to forbid, in a lane ADR-0210's Decision text does not
reach. The D6 invariant list gains a third entry: `skipped_spawn` and
`refused_produce` both gate, separately, so that a machine failure and a
produce-envelope refusal cannot be read as each other. Ratchet at the state of
this revision: the expectation table is empty and all three OS legs report zero
of both. The same change gave each run its own scratch roots — shared fixed
roots let two overlapping runs delete each other's working directories, which
is how a run came to be half-empty and green in the first place (issue #284).
