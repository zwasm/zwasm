# 0109 — Native Zig API inversion: Engine + Linker + TypedFunc

- **Status**: Closed (implemented) 2026-09-08 — Removal condition met: the rewrite shipped 2026-05-25 (`017193bc`..`05c47829`, J.2..J.7) and cw v1 dogfooded it from v2.0 through v2.5.0 with no shape problem surfaced; the feedback that will come has come (ClojureWasm wound down 2026-09-06, #407). Previously Accepted 2026-05-25.
- **Date**: 2026-05-24
- **Author**: claude (autonomous loop, cycle 36)
- **Tags**: zwasm.zig, facade, api, Engine, Linker, TypedFunc, cw-v1, dogfooding, D-075
- **Supersedes-portion-of**: ADR-0025 "minimum subset" target shape (Runtime / Module / Instance / Value as thin c_api veneer)
- **Amends**: ADR-0024 `src/zwasm.zig` re-export hub role (now also hosts native facade types)
- **Paired execution plan + test strategy**: TBD — produced by a post-amend codebase-investigation chunk (subagent-driven; enumerates every site needing change for the rewrite + designs the test approach to ensure regression detection + happy path + edge cases so "other tests pass while Zig API is broken" cannot happen). Required reading before any J.* impl chunk lands.

## Context

The Zig facade in `src/zwasm.zig` was originally designed
(ADR-0025) as a thin veneer over the wasm-c-api binding:
`Runtime.init` calls `wasm_engine_new()`, `Module.parse` calls
`wasm_module_new`, etc. This shape mirrors wasm-c-api's
Engine/Store/Module/Instance separation because the c_api
binding landed first and the Zig facade was retro-fitted on
top.

Cycle 35 (`6b0cbbf6`) closed the immediate Phase 9 blocker
(D-168 entry.zig cap) but surfaced a deeper question raised
by the ClojureWasm v1 dogfooding team: **the current Zig
facade is not designed for Zig consumers**. Concrete defects
inventoried in the cycle 35-36 discussion:

1. **Facade is a C ABI veneer.** `Runtime.init` accepts an
   allocator argument but ignores it (`c_allocator` is
   hard-coded internally via wasm_engine_new). Zig
   consumers expecting allocator strict-pass cannot
   integrate per-instance arenas or restricted allocators.
2. **Two `Value` types coexist.** Facade tagged
   `union(enum)` (~16+ bytes with `u128` v128 variant)
   vs internal `extern union` (8-byte slot). Inconsistent;
   the tagged form is incompatible with NaN-boxing
   consumers.
3. **`InstantiateOpts = struct {}` is empty.** No host
   import wiring API. Consumers cannot embed Wasm modules
   that import host functions (= the primary use case
   for a Wasm runtime as a library).
4. **`InvokeError = error{...Trap...}` collapses all 12
   trap variants into one `error.Trap`.** Diagnostic
   information lost at the API boundary.
5. **No TypedFunc.** Consumers must use raw `Value` slices
   for every call; type errors surface at runtime.
6. **No Memory access API.** No way to read/write Wasm
   linear memory from Zig.
7. **v128 routed through facade is hard-coded to 0** in
   `valueToVal` (deferred to D-075 v0.2).
8. **Zombie-instance contract is implicit** (no `detachForZombie`
   API; cross-instance funcref lifetime invariant is
   load-bearing but un-surfaced).

The user reframe (cycle 36): the c_api binding is the
**industry-standard wasm-c-api implementation** and stays
where it is; the Zig API should be **independent and
first-principles**, designed for Zig consumers (cw v1
being the immediate use case, but generalizable to any
Zig project embedding Wasm).

Survey of industry shape (cycle 36):

- **wasmtime (Rust)**: `Engine` + `Store<T>` + `Linker<T>`
  + `TypedFunc<Params, Results>`. Linker as builder for
  reusable import sets.
- **wasmer (Rust)**: `Engine` + `Store` + `Imports` (via
  `imports!` macro) + `TypedFunction<Args, Rets>`.
- **wasmi (Rust)**: same as wasmtime.
- **wasm3 (C)**: `IM3Environment` (engine) + `IM3Runtime`
  (per-execution state; "Runtime" means something
  different).
- **WAMR (C)**: `wasm_engine_t` + `wasm_runtime_init`.
- **zware (Zig)**: `Store` + `Instance` (no Engine).
- **v1 zwasm (Zig, predecessor)**: `WasmModule.load(alloc,
  bytes)` — 1-step, host imports inline via
  `loadWithImports(alloc, bytes, entries)`. Predates the
  Linker pattern.

Consensus: **`Engine` as top-level name** (5/5 major
runtimes), **`Linker` as imports builder** (wasmtime/wasmer
strong precedent, zware would adopt if it had host import
needs), **TypedFunc as the primary call surface**
(everyone except zware has it).

## Decision

Rewrite `src/zwasm.zig` as a **native Zig facade independent
of the c_api binding**, adopting:

1. **`Engine`** as top-level type for the new public Zig facade
   — `pub const Engine = struct { ... }` in `src/zwasm/engine.zig`
   replaces the current `src/zwasm.zig::Runtime` c_api veneer.
   The internal interpreter-state struct `src/runtime/runtime.zig::Runtime`
   is **unchanged** — it lives in its own namespace and is
   unrelated to the JIT ABI struct `JitRuntime` at
   `src/engine/codegen/shared/jit_abi.zig:137` (introduced as
   `JitRuntime` from day 1 per ADR-0017 sub-2a, prefixed with
   `Jit` precisely to avoid collision with the pre-existing
   `runtime.Runtime`). Zig 0.16's module-as-struct semantics
   + `usingnamespace` removal guarantee qualified access at every
   call site, so `runtime.Runtime` + `jit_abi.JitRuntime`
   coexist without ambiguity.
2. **`engine.compile(bytes)` → `Module`** (1-step, not
   `Runtime` + `Module.parse` + `Module.instantiate` 3-step).
3. **`engine.linker()` → `Linker`** as a reusable builder
   for imports. `Linker.defineFunc`, `defineMemory`,
   `defineGlobal`, `defineTable`, `defineInstance`,
   `defineWasi`. `Linker.instantiate(module)` → `Instance`.
4. **`TypedFunc(comptime Sig: type)`** with `Sig` as a Zig
   function type (e.g. `fn(i32, i32) i32`). Comptime layer
   uses `@typeInfo(.@"fn")` to derive the Wasm function
   signature and generates marshal code. Multi-result via
   Zig anonymous struct return (`fn(i32, i32) struct { i32,
   i32 }`).
5. **`Value` exposed as the internal `extern union`** — post-
   ADR-0110 (Accepted 2026-05-24 `9204847a`) the internal
   Value cell is **uniform 16-byte** (v128 first-class). The
   facade exposes this single union with all variants
   (i32/i64/f32_bits/f64_bits/v128/ref) — **no separate
   `V128` type** (ADR-0110 supersedes the original 8+16
   split intended in this ADR's first draft; see
   Revision history 2026-05-25). NaN-boxing-friendly:
   float bits flow through `f32_bits` / `f64_bits` without
   canonicalization at the Value boundary. `ValueKind` enum
   for dynamic-dispatch cases.
6. **Full `Trap` error set re-exported** (no `error.Trap`
   catchall in the API boundary).
7. **`Memory` slice view**: `mem.slice() → []u8`,
   `mem.sliceAt(offset, len)`, `mem.read(T, offset)`,
   `mem.write(offset, value)`. Bounds-checked.
8. **Allocator strict-pass** through `Engine.init(alloc,
   opts)`. No `c_allocator` fallback.
9. **`Caller` ctx for host functions** (first parameter of
   host functions): `caller.memory()`, `caller.engine()`,
   `caller.instance()`, `caller.alloc()`.
10. **WASI as a bulk `linker.defineWasi(cfg)`** path.

The c_api binding (`src/api/`) is unaffected by this ADR.
It continues as the cross-language wasm-c-api implementation;
the native Zig facade is a sibling, not a replacement.

Full design spec: `docs/zig_api_design.md` (written
alongside this ADR; reviewed in tandem at Accept time;
canonical artifact for ClojureWasm v1 dogfooding).

## Alternatives considered

### Alternative A — Keep the current c_api-veneer facade, fix defects in place

- **Sketch**: Add Linker / TypedFunc / Memory on top of the
  existing `Runtime` / `Module` / `Instance` (wasm-c-api
  wrappers). Plumb the allocator. Replace the tagged Value
  with the extern union. Keep the wasm-c-api delegation
  internal.
- **Why rejected**: The wasm-c-api delegation forces all
  facade operations through C ABI boundaries (handle ptr
  + Vec<u8> args + opaque return codes). This is wasteful
  for Zig-internal calls and obstructs typed marshal
  generation. Allocator plumbing into wasm-c-api requires
  per-call thread-local context (wasm-c-api APIs don't
  take allocators). Architecturally, the c_api binding
  exists for cross-language consumers — using it as the
  Zig consumer path is layering inversion.

### Alternative B — Adopt v1 zwasm shape unchanged (`WasmModule.load(alloc, bytes)` etc)

- **Sketch**: Mirror the v1 API surface 1:1.
  `WasmModule.load(alloc, bytes)`, `WasmModule.loadWithImports(...)`,
  `WasmValType` enum, etc.
- **Why rejected (partial)**: v1's shape is good in spirit
  (allocator strict-pass, 1-step construction, host
  imports first-class) but missing two industry-standard
  conveniences:
  - **Linker as builder** (v1 passes imports inline,
    forces repeat construction for multi-module hosts).
  - **TypedFunc** (v1 only has Value-slice invoke,
    forcing all consumers to write marshal code).
  This ADR inherits v1's spirit but adds the Linker +
  TypedFunc layers from the industry-standard playbook.

### Alternative C — Defer the rewrite to v0.1.0 RC (status quo)

- **Sketch**: Mark D-075 as still-deferred. cw v1 codes
  against the current c_api-veneer facade, accepting the
  defects, and migrates at v0.1.0 RC.
- **Why rejected**: cw v1 explicitly stated (2026-05-24)
  that the current facade defects block their work.
  Allocator strict-pass and host import wiring are
  structural blockers, not nice-to-haves. Deferring
  forces cw v1 to either (a) not dogfood until v0.1.0
  RC (= months) or (b) build a CW-internal Zig facade
  around the c_api binding that duplicates the work this
  ADR proposes. (a) blocks CW; (b) wastes work that has
  to be redone when zwasm proper lands the facade.

### Alternative D — `Runtime` instead of `Engine` for the public facade

- **Sketch**: Keep the public facade name as `Runtime`
  (current ADR-0025 name) instead of introducing `Engine`.
- **Why rejected**: 5/5 major Wasm runtimes use `Engine`
  as the top-level name. `Runtime` is used by wasm3 and
  WAMR to mean "per-execution state" — a different
  concept. Adopting `Engine` for the public facade reduces
  cognitive load for consumers familiar with wasmtime /
  wasmer / wasmi / wasm-c-api. The internal struct
  `runtime.Runtime` (interp per-instance state) keeps its
  name unchanged — it is namespace-isolated from the
  public `Engine` facade.

## Consequences

**Positive**:

- ClojureWasm v1 (and any other Zig consumer) gets a
  first-principles API designed for them. Allocator
  strict-pass, comptime-typed marshal, NaN-boxing-friendly
  Value, host import builder.
- The c_api binding stays as the cross-language path
  without becoming a bottleneck for Zig-internal use.
- Industry-standard naming (`Engine`, `Linker`,
  `TypedFunc`) reduces cognitive load for consumers
  familiar with wasmtime / wasmer.
- Trap variant preservation enables better diagnostics
  in consumer code.
- TypedFunc comptime layer replaces the internal
  114-helper `entry.zig` catalog as the consumer-facing
  surface (the internal catalog stays as the JIT-call
  ABI implementation detail).

**Negative**:

- ~6-8 cycles of implementation work. Affects
  `src/zwasm.zig` (rewrite) + new modules under `src/zwasm/`
  (`engine.zig`, `module.zig`, `instance.zig`, `typed_func.zig`,
  `memory.zig`, `linker.zig`, `caller.zig`, `host_func_marshal.zig`,
  `wasi_config.zig`) per `phase10_zig_api_plan.md` §3.
- Breaking change for anything depending on the current
  c_api-veneer facade. Mitigation: today's facade is
  unused outside the Phase 9 invariant test (I3); cw v1
  hasn't started coding against it. Window for the
  breaking change is now (pre-cw-v1 adoption).
- The c_api binding stays at `src/api/`, which means
  TWO API surfaces exist in the tree. This is intentional
  (audience separation: native Zig vs cross-language)
  but adds maintenance load. Mitigation: c_api stays as
  a thin wrapper around the same internal types; native
  facade and c_api share the underlying `runtime.Runtime`
  + `Instance` impl.

**Neutral / follow-ups**:

- ADR-0025 should be amended (in tandem with this Accept)
  to point at this ADR as the superseding target shape;
  ADR-0025 stays in-tree as the lineage of the
  minimum-subset attempt.
- D-075 narrows: instead of "facade B-1..B-5 phases
  un-started", D-075 becomes the implementation tracker
  for THIS ADR's 6-8 cycles.
- Phase 11 (WASI 0.1 full + bench infra) ROADMAP row
  should reference `linker.defineWasi(cfg)` as the WASI
  surface delivery vehicle.

## Removal condition

This ADR retires when the rewrite ships and cw v1 has
successfully dogfooded against the new API for at least
1 minor version (= the design has survived contact with
a real consumer). At that point this ADR transitions
to `Status: Closed (Implemented)` with the implementation
SHA range cited.

If cw v1 review surfaces a fundamental shape problem
(e.g. TypedFunc comptime layer hits a Zig compiler
limitation), this ADR is amended (Revision history) or
superseded by a follow-on ADR.

## References

- `docs/zig_api_design.md` — full consumer-facing design
  spec (read alongside this ADR).
- ADR-0024 — `src/zwasm.zig` self-import hub (compatible).
- ADR-0025 — Original Zig facade minimum-subset (this
  ADR supersedes the target shape; ADR-0025 stays
  in-tree as lineage).
- ADR-0014 — Allocator + zombie-instance contract
  (relevant for `Engine.init` allocator plumbing +
  `Instance.detachForZombie` API).
- ADR-0107 — Byte-buffer globals for v128 cross-module
  (Withdrawn 2026-05-24; root-cause-fixed by ADR-0110
  uniform 16-byte Value).
- D-075 (`.dev/debt.md`) — Zig facade implementation
  tracker (will be re-scoped to track this ADR's cycles
  on Accept).
- Industry survey (cycle 36): wasmtime, wasmer, wasmi,
  wasm3, WAMR, zware, v1 zwasm — see
  `docs/zig_api_design.md` §7.

## Revision history

- 2026-05-24 — Initial draft at cycle 36, post-cycle-35
  user reframe (c_api → native-Zig inversion). Filed
  `Status: Proposed` for user collab review. Paired
  with `docs/zig_api_design.md` (consumer spec
  artifact).
- 2026-05-25 — **Status: Proposed → Accepted** at Phase 10
  open. User direction: "実装を提案の状態に寄せていく (大作業
  OK)" — cw v1 dogfooding feedback overrides the Phase 16
  deferral the original ADR-0025 plan carried. Companion
  amends in the same commit:
  - ADR-0025 Status clarified (target shape fully
    superseded; ADR-0025 stays in-tree as design lineage).
  - D-075 re-scoped from `blocked-by: ADR-0109 Accept`
    to `Status: now` (impl tracker for the 6-8 cycles).
  - ROADMAP §10 new row **10.J** added (placed before
    10.F so the rename chain lands early — see
    Consequences §"Internal rename `Runtime` → `JitRuntime`").
  - `phase10_design_plan_ja.md` §7 work-sequence updated
    + new §3.6 sub-section for Zig API implementation.
  - `phase9_close_master.md` §1 deliverable table row 40
    "deferred to v0.1.0 RC (Phase 16)" — that doc is
    ARCHIVED-IN-PLACE so the row text stays as a snapshot;
    superseding noted in the doc's top blockquote.
  - **§5 Value section reconciled with ADR-0110**: the
    "8-byte slot + separate V128 16-byte struct" split
    from the original draft is OBSOLETE post-ADR-0110
    Accept (`9204847a` 2026-05-24 widened internal Value
    to uniform 16-byte). The facade now exposes the single
    extern union with all variants — no separate `V128`
    type. `docs/zig_api_design.md` §4 amended to match.
- 2026-05-25 — **Pre-impl investigation + execution plan
  + test strategy** queued as the next chunk after this
  amend round. Per user direction: codebase-wide
  investigation (subagent-driven) enumerating every site
  needing change for the rewrite, plus a unified plan
  doc that integrates the test strategy — covering
  regression detection / happy path / edge cases so
  "other tests pass while Zig API is broken" cannot
  happen. The plan doc gates the first J.* impl chunk;
  no `src/zwasm.zig` rewrite lands before the plan is
  user-reviewed.
- 2026-05-25 — **Internal `runtime.Runtime` → `JitRuntime`
  rename clause WITHDRAWN** from Decision §1 + Alternative D
  + Consequences. Rationale: pre-impl investigation at J.1
  着手 surfaced that `JitRuntime` is already a load-bearing
  `extern struct` at `src/engine/codegen/shared/jit_abi.zig:137`
  (399 usages / 26 files; introduced from day 1 per ADR-0017
  sub-2a with the `Jit` prefix precisely to avoid collision
  with the pre-existing `runtime.Runtime`). The original §1
  rename rationale ("preserve the ABI surface that JIT-emitted
  code reads via `[X19 + offset]`") was based on a factual
  error — JIT body reads `jit_abi.JitRuntime` (per offset
  constants at `jit_abi.zig:396-428` + `arm64/emit.zig:233-244`
  LDR sites), NOT `runtime.Runtime`. Keeping `runtime.Runtime`
  as-is preserves the ADR-0017 design intent. Zig 0.16's
  module-as-struct semantics + `usingnamespace` removal
  guarantee qualified access at every call site, so
  `runtime.Runtime` + `jit_abi.JitRuntime` coexist without
  ambiguity. Side-effect: `phase10_zig_api_plan.md` §3 J.1
  chunk withdrawn (subsequent chunks J.2..J.close keep their
  numbers); plan §7 cycle estimate reduced by 1. Note: the
  earlier "10.J added before 10.F so the rename chain lands
  early" rationale (Revision row 2 above, last sub-bullet)
  is now obsolete; the 10.J position is retained because the
  remaining J.2..J.close work is still the load-bearing
  facade rewrite.
- 2026-05-25 — **Implementation complete** (ROADMAP §10 / 10.J `[x]`;
  6 cycles J.2..J.7). Sub-chunk SHAs: J.2 `017193bc` (Engine + Module
  skeleton + native parser + allocator strict-pass), J.3 `698c23ce`
  (Instance + untyped invoke + full 12-variant Trap set), J.4
  `995270cf` (TypedFunc(comptime Sig) + Memory + multi-result),
  J.5 `b10922d2` (Linker + Caller + host imports + host_func_marshal
  + `instantiateInternal` refactor), J.6 `97434726` (Tier-2
  `zig_facade_runner` + `test-api-zig-facade` build step), J.7
  `05c47829` (Linker.defineWasi skeleton + UnsupportedWasiImport
  variant). Coverage matrix per plan §4.2: T1.1..T1.13 cover every
  shipped public symbol; `Linker.defineGlobal` / `defineTable` /
  `Instance.global` / `.table` / `Instance.call` sugar /
  `engine.linker()` factory / `Module.exports() / .imports()`
  iterators carved out as Phase 11 D6 follow-up per the plan's
  "deferred" rows (S-4 reframe). **Status remains Accepted** until
  cw v1 dogfooding feedback per this ADR's Removal condition;
  D-075 status tightened to "dogfooding gate only" (impl tracker
  duty discharged at this commit).
- 2026-09-08 — **Status: Accepted → Closed (implemented)**. Removal
  condition met: the rewrite shipped 2026-05-25 and cw v1 dogfooded it
  across v2.0→v2.5.0 (≥ 1 minor version) without surfacing a fundamental
  shape problem. ClojureWasm wound down 2026-09-06 (#407), so no further
  consumer feedback will arrive — the wait D-075 held open is over; D-075
  retires in the same commit.
