# 0014 — Redesign + refactoring sweep before Phase 7

- **Status**: Closed (Phase 7 DONE)
- **Date**: 2026-05-03
- **Author**: continue loop iter 5–11 + interactive dialogue
- **Tags**: phase-6, redesign, refactor, value-semantics,
  cross-module, ownership, debt-cleanup, phase-7-precondition
- **Replaces**: the placeholder content originally filed under this
  same ADR slot ("Wire a refactor & consolidation phase between
  Phase 6 and the JIT phase"). The placeholder proposed a Phase 7 =
  refactor + Phase 8 = JIT renumber and a forthcoming ADR-0015
  charter. This ADR supersedes that wiring entirely (see
  Alternatives §3).

## 1. Context

zwasm v2 is **pre-release** — zero downstream users, no API
compatibility constraints. ROADMAP §P10 ("re-derive from v1, do
not copy") and §P3 ("cold-start single-pass") give the project
permission to choose the **right** shape, not the cheapest patch.
Phase 6 reopen iterations 5–11 (per ADR-0011 + ADR-0012) drove
the wasmtime misc-runtime gate from 78 fails to 28, but in the
process surfaced eight items that share a single root: the v1
carry-over of "single-instance-implicit" semantics in `Value`,
`Runtime`, and the c\_api ownership graph.

Each is documented inline in `.dev/handover.md` "Workaround / debt
inventory":

1. `c_api/instance.zig` returns `error.UnsupportedCrossModule*`
   for every non-memory cross-module import. Direct cause of
   27 of the 28 remaining misc-runtime failures.
2. `Value.ref` (interp/mod.zig) packs only a 32-bit funcidx — no
   instance identity. Single-instance assumption leaks through
   `call_indirect` / `table.*` / `ref.func` / element-segment
   population.
3. `Runtime ↔ Instance ↔ allocator` ownership is ad-hoc:
   `rt.alloc` is parent\_alloc, `inst.arena` is per-instance,
   table refs straddle both, `rt.memory` got a `memory_borrowed`
   bool to avoid double-free, table/elem slices leak. Every new
   resource (globals, FuncEntity) would re-invent the same
   pattern badly.
4. `Runtime` has no Instance back-pointer. Cross-instance dispatch
   would have to invent ad-hoc routing per call site.
5. `decodeElement` (frontend/sections.zig) only handles forms
   0/1/3/4 — forms 5/7 (passive/declarative reftype-expr vec)
   return `Error.InvalidFunctype`. Two reftypes fixtures fail
   because of this.
6. `Label` (interp/mod.zig) used a single `arity` field for both
   `end`-time results and `br`-time params. iter 11 split it into
   `arity` + `branch_arity` to fix `loop (result T)`. The split
   needs ADR-level formalisation and `.claude/rules/`-level
   anti-pattern guidance ("single slot serving two distinct
   meanings is a §14-class smell") so the next slot doesn't
   regress.
7. `wast_runtime_runner.buildImports` silently null-slots
   unresolved imports; the failure surfaces two layers deep as
   `UnknownImportModule`. The runner's diagnostic chain is
   fragile and grew this way only because cross-module imports
   are still being built out.
8. `partial-init-table-segment/indirect-call result[0] mismatch`
   (1 fixture) is uninvestigated; certainly downstream of (1) /
   (2) — re-measure after they land, do not patch in isolation.

The user's directive (2026-05-03 dialogue): **"設計としてあるべき
論をとるべきで、コストを考えるべきではない。世の中にまだ出ていな
い。残タスクを Phase 7 以降に残すべきでない。"** No outstanding
unimplemented ADRs, no debt rolling forward into the JIT phase.

A subagent survey of `Value.ref` impact (2026-05-03) found 4
producer + 2 consumer + 18 table-mover + 4 null-check + 70+
test sites; worst-hit file is `interp/ext_2_0/table_ops.zig`
(35+ touch sites). v1 uses Store-centric tables with a `shared`
flag; wasmtime uses `*VMFuncRef` pointers; zware/wasm3 do not
support cross-module. Aligning v2 with the wasmtime-style
pointer representation is the only path that satisfies "あるべ
き論": funcref carries its own instance identity, cross-module
dispatch becomes a pointer dereference, and the design extends
cleanly to externref / continuation-ref for Wasm 3.0.

## 2. Decision

Insert a new work-item block §9.6 / 6.K **inside Phase 6, before
6.J close**. Six work items address all eight inventory entries.
Phase 6 closes only when all 6.K items land + the existing 6.E /
6.F / 6.G / 6.H / 6.I / 6.J criteria.

No follow-up ADR. No Phase 7 = refactor renumber. JIT remains
§9.7. Once Phase 6 closes, Phase 7 starts atop a clean
substrate.

### 2.1 Work-item DAG (6.K)

```
6.K.1 (Value funcref → *FuncEntity)
   ├─→ 6.K.2 (ownership model + Instance back-ref)
   │      └─→ 6.K.3 (cross-module imports: table / global / func)
   │             └─→ 6.K.6 (re-measure partial-init-table fixture)
   ├─→ 6.K.4 (decodeElement forms 5 / 7)  [parallel]
   └─→ 6.K.5 (Label arity formalisation + §14 anti-pattern entry)  [parallel]
```

#### 6.K.1 — Value funcref carries instance identity

**What**: Replace bare-funcidx encoding of `Value.ref` with a
pointer to a per-instance `FuncEntity`. Each Instance allocates
a `FuncEntity` array at instantiation time (one per defined
function). Element-segment population, `ref.func`, `table.fill`,
`table.grow`, and `table.set` write `@intFromPtr(*FuncEntity)`
into `Value.ref`. `call_indirect`, `ref.is_null`, `wasm_func_call`,
`wasm_extern_as_func` reverse the cast.

**Null sentinel migration**: the current `Value.null_ref =
maxInt(u64)` (`src/interp/mod.zig:50`) is replaced with literal
`0`. Justification: `c_allocator.alloc` (the underlying allocator
on all three target platforms — Mac aarch64 darwin, Linux x86_64
glibc/musl, Windows x86_64 ucrt) returns non-zero on success per
the C standard's `malloc` contract; address 0 is therefore a
sound funcref-null sentinel. The migration must happen
**atomically in one commit** because every consumer that compares
`r == Value.null_ref` and every producer that constructs
`.{ .ref = Value.null_ref }` is affected (4 null-check sites + 4
producer sites surveyed in §1 Context). Add a compile-time
check `comptime { std.debug.assert(Value.null_ref == 0); }` in
`mod.zig` to catch any accidental re-introduction of the old
value.

**`wasm_func_t` representation choice**: the existing `Func`
struct (`c_api/instance.zig:143`) carries `instance: ?*Instance`
+ `func_idx: u32`. After 6.K.1, **`Func` keeps its current
shape**; `wasm_func_call` looks up the FuncEntity via
`instance.func_entities[func_idx]`. Rationale: `wasm_func_t` is
a public C-API handle; mutating its representation needs an
ADR-grade decision because it affects ABI stability narrative
(even pre-release, the C surface is documented). Internal
`Value.ref` migration is an implementation choice; the C-API
handle is intentionally insulated. Bridge cost: one
array-indexed lookup at `wasm_func_call` entry, negligible.

**Why this shape**: aligns with wasmtime's `*VMFuncRef`
(textbook §Q3); avoids v1's Store-centric `shared` flag (§P10
divergence cited); single-instance modules pay one extra
indirection per `call_indirect` (acceptable per §P3 — the
allocation is once-per-instantiation, not per-call); cross-
module modules need no separate routing table because the
pointer already carries source identity.

**Externref**: this ADR scopes only the funcref change.
Externref keeps its current opaque-host-handle representation
(low 64 bits = host pointer); ADR-0014 does not block externref
work.

**Test cost**: ~70+ test sites in `interp/ext_2_0/table_ops.zig`
+ `interp/trap_audit.zig` use bare-funcidx construction
(`.{ .ref = 7 }`). They migrate to a small helper
`Value.fromFuncRef(*FuncEntity)` or to using a stub FuncEntity
pool. Mechanical but bulky.

**Files touched**: `src/interp/mod.zig`, `src/interp/mvp.zig`,
`src/interp/ext_2_0/{ref_types,table_ops}.zig`, `src/c_api/instance.zig`,
plus the test sites above.

**Acceptance**:
1. Existing tests green.
2. New unit test "two instances share a table; each writes its
   own FuncEntity; `call_indirect` dispatches into the correct
   source instance".
3. New unit test "null funcref round-trip": a table cell
   initialised null (`.ref = 0` post-migration) makes `ref.is_null`
   return `1` AND `call_indirect` on it traps with
   `UninitializedElement`. This catches a stale `== maxInt(u64)`
   check anywhere.
4. `comptime` assertion `Value.null_ref == 0` compiles.

#### 6.K.2 — Ownership model: Instance back-ref, allocator discipline

**What**: Four sub-changes:

1. `Runtime` gains `instance: ?*anyopaque = null` (Zone 2 cannot
   import Zone 3 directly; the c\_api binding stores a `*Instance`
   here at construction). Used by 6.K.3 only — not consulted on
   the hot path.
2. Single allocator policy. `rt.alloc` becomes the
   per-instance arena. All runtime resources (memory, globals,
   tables.refs, elems, FuncEntity pool, host\_calls, dropped
   flags) allocate from this arena. `Runtime.deinit` becomes a
   no-op for individually-tracked resources; arena-free at
   instance teardown reclaims everything in one shot.
3. Drop `Runtime.memory_borrowed` and the parallel hand-rolled
   borrowed-flag pattern. Cross-instance memory imports work by
   making the importer's `rt.memory` slice header reference the
   source's bytes; no free path needs to know which is which
   (the source's arena owns the storage).
4. **Zombie instance contract** (added 2026-05-04 after the 6.K.3
   spike found a partial-init dangling-FuncEntity issue, see §3
   amendment below). When an `instantiateRuntime` call traps
   mid-element-segment processing, prior writes into a foreign
   instance's table cells already hold `*FuncEntity` pointers
   into the failing instance's arena (per Wasm 2.0 partial-init
   semantics). Destroying that arena turns those into dangling
   pointers. The failed instantiation's `Runtime` + arena
   therefore park on a per-`Store` zombie list; they live until
   `wasm_store_delete` walks and frees them. The Instance struct
   itself is freed normally (the C-API caller never sees it),
   but the underlying state is retained. `wasm_instance_delete`
   on a successfully-instantiated handle parks it as a zombie
   too, so cross-module funcrefs into it from sibling instances
   stay valid until store teardown — matching wasmtime
   (`crates/wasmtime/src/runtime/store.rs:146`) and wazero
   (`internal/wasm/table.go:104` `involvingModuleInstances`).

**Why this shape**: every introduced resource (globals,
FuncEntity, future continuation-ref) inherits arena ownership
without re-inventing flags; `table.grow`'s realloc against
arena allocator works when the arena's underlying allocator is
the c\_allocator (which it is in c\_api today —
`c_api/instance.zig:241` `engineAllocator(engine)` resolves to
`std.heap.c_allocator`). Removes the iter-7 `memory_borrowed`
workaround. Removes the iter-5 "tables refs allocated from
parent\_alloc but headers from arena" leak.

**Arena `realloc` trade-off**: Zig 0.16's `ArenaAllocator`
implements `realloc` by allocating a new block and leaving the
old one alive until arena teardown. For `table.grow`, repeated
calls accumulate dead `refs` slices inside the arena. **Accepted
for v0.1.0**: fixtures that exercise `table.grow` heavily are
microbenchmarks, not realistic guest workloads; the arena is
released at instance teardown so memory is bounded by the longest-
lived instance. If this becomes a measurable bench regression
post-6.H baseline (§F.4 — bench re-run check below), file an
ADR proposing a per-table `refs` allocator routed directly at
`parent_alloc` to recover free-on-realloc semantics.

**Files touched**: `src/interp/mod.zig` (Runtime fields +
deinit), `src/c_api/instance.zig` (instantiateRuntime allocator
choice unified; the zombie list lives on Store and is walked by
`wasm_store_delete`), `src/interp/ext_2_0/table_ops.zig`
(`table.grow`'s realloc target).

**Acceptance**:
1. Full test-all green on three hosts; no leak warnings under
   DebugAllocator where available.
2. `Runtime.memory_borrowed` field is deleted (grep -r returns
   zero matches outside git history).
3. New unit test "table.grow on a freshly-instantiated module
   reallocates `rt.tables[0].refs` against the per-instance arena
   and the grown slice contains the previous values plus the
   init-value at the appended slots". Confirms arena-backed
   realloc semantics directly, since the existing test corpus
   does not heavily exercise `table.grow`.
4. **(added 2026-05-04)** New unit test "zombie instance: failed
   instantiation's runtime + arena live until store_delete; a
   funcref into the zombie's funcs survives `wasm_instance_new`'s
   null return and dispatches correctly when invoked from a
   sibling live instance's table". Locks the Wasm 2.0
   partial-init semantics this contract preserves.

**Sub-tasks** (initial 6.K.2 work landed in commit `e6e5c20`):
sub-changes 1-3 are `[x]` post-`e6e5c20`. **Sub-change 4
(zombie list) is `[ ]` and lands as part of the 6.K.3 retry**
since the two are inseparable: 6.K.3 cannot land safely without
4, and 4 has no observable behaviour without 6.K.3 exercising it.

#### 6.K.3 — Cross-module imports for table / global / func

**What**: Drop `error.UnsupportedCrossModuleTableImport` /
`…GlobalImport` / `…FuncImport` from c\_api. Wire each:

- **Table import**: 6.K.1 makes the funcref encoding instance-
  agnostic, so sharing the source's `TableInstance` (refs slice +
  metadata) Just Works. The importer's `rt.tables[idx]` holds a
  copy of the source's `TableInstance` struct value (refs slice
  is shared; mutations from either side propagate).
- **Global import**: per-slot pointer aliasing —
  `Runtime.globals: []*Value` (was `[]Value`), with each slot
  pointing at owning storage. Defined globals point at slots in a
  per-instance `globals_storage: []Value` arena allocation;
  imported globals point at the source instance's slot. global.get
  / global.set dereference the pointer. Mutable global imports
  reach the source via the shared pointer; immutable imports work
  identically. **(amended 2026-05-04)** This replaces the
  original "slice-alias" framing — a flat `[]Value` cannot share
  individual slots between disjoint slice headers, so the encoding
  shifts to per-slot pointers. Hot-path cost is one extra load
  per global access; benchmarks tolerated.
- **Func import**: the importer's funcidx 0..imp\_func\_count map
  to source instance functions. Build the importer's
  `host_calls[i]` to a thunk that pops args off the importer's
  operand stack, pushes them onto the source's, runs source's
  dispatch with source's runtime context, and copies results
  back. (Cross-instance dispatch helper.)

**Why this shape**: 6.K.1's pointer-based funcref makes table
sharing trivial (the source's funcrefs already point at the
source's FuncEntities; the importer reads them and dispatches
correctly). Globals are simple slice-aliasing. Func imports
need an explicit thunk because operand stacks are per-Runtime;
this is the same shape WASI thunks already use.

**Cycle safety**: Wasm-to-Wasm cross-instance dispatch via the
thunk pattern requires the dispatched-into runtime to be in a
consistent state. A cycle (A imports `f` from B, B imports `g`
from A) would re-enter the caller's runtime mid-dispatch and
clobber the inline `operand_buf` / `frame_buf`. **Cycles are
ruled out by Wasm's instantiation order**: a module cannot be
instantiated until every module it imports from has been fully
instantiated. The wast manifest format (`module … as $X` then
`register …`) and `wast_runtime_runner` honour this. Document
the invariant; do not add runtime cycle detection. If a future
test corpus introduces cyclic instantiation by misuse, the
thunk's first re-entry on the still-running runtime will
manifest as an operand-stack assertion (debug builds) or
undefined behaviour (release) — caller fixes the manifest.

**Existing table-import wiring stays**: `c_api/instance.zig`
already implements imported-table sharing at the
`tbl_storage[i] = source_rt.tables[ext.table_idx]` value-copy
step (iter 7; currently behind `error.UnsupportedCrossModule
TableImport` guard around line 576). The value-copy of the
`TableInstance` struct shares the `refs` slice header — exactly
what 6.K.3 wants. **The only required source change for table
imports** is removing the `UnsupportedCrossModuleTableImport`
guard. Globals + funcs are new code.

**How this contract was discovered** (process note, 2026-05-04):
the original 6.K.3 spike landed without anticipating the
partial-init scenario — the fail manifested as a segfault when a
2nd-stage `assert_unlinkable` element segment trapped after a
1st-stage segment had already populated module A's imported
table with B's funcrefs. Two days of investigation rebuilt the
chain (B's arena freed → A's table cell points at undefined
memory → first call_indirect through the dangling cell crashes).
The contract below was designed retroactively against the
discovered failure, then validated against
`crates/wasmtime/src/runtime/instance.rs:327-350` and the spec
interpreter at `WebAssembly/spec/interpreter/exec/eval.ml:427-444`
for fidelity. The lesson: partial-init scenarios are **easier to
miss in design than to debug after they segfault**; future
table / global cross-module work should walk the partial-init
fault tree explicitly during Step 0 survey, not only the
happy-path.

**Partial-init dangling-FuncEntity contract** (added 2026-05-04
after the spike). When module B's element segment writes
`*FuncEntity` pointers (per the 6.K.1 encoding) into module A's
imported table, then a later segment in B traps OOB, partial-init
semantics (Wasm 2.0) keep B's writes visible in A's table.
B's instantiation fails; without further mitigation, B's arena
is destroyed and A's table holds dangling pointers. The fix
lives in 6.K.2's sub-change 4 (zombie-instance keep-alive at the
c\_api Store level — see above). At the runner layer,
`wast_runtime_runner.zig`'s `handleInstantiateExpectFail` must
**retain the failed instance's engine + store + module + arena
in `ctx.all`** — not run the inherited `errdefer
wasm_engine_delete / wasm_store_delete / wasm_module_delete` from
`instantiateWithImports`. The corpus-level `ctx.deinit()` walks
`ctx.all` and frees everything at corpus end, which is when the
last reference into a zombie's funcs is guaranteed to have been
released. Mirrors wasmtime's wast runner shape (one Store across
the whole `.wast` file).

**Files touched**: `src/c_api/instance.zig`
(remove `error.UnsupportedCrossModule*Import` guards; add
global per-slot pointer aliasing + func thunk paths; add Store
zombie list + `parkAsZombie` helper + walk in
`wasm_store_delete`; preserve the existing
`tbl_storage[i] = ...` lines as the correct shared-refs path),
`src/interp/mod.zig` (`Runtime.globals: []*Value` shape change +
`globals_storage: []Value` field), `src/interp/mvp.zig`
(`globalGet` / `globalSet` deref + `globals` test setup
adjusted), `test/runners/wast_runtime_runner.zig` (1)
`buildImports` raises a named error instead of silently
null-slotting on unresolved imports (closes inventory item 7
from §1); (2) `handleInstantiateExpectFail` retains the failed
ActiveModule in `ctx.all` instead of letting errdefers free it.

**Acceptance**:
1. After 6.K.1 + 6.K.2 (including sub-change 4) land, the
   misc-runtime failure count drops to **≤ 1** — partial-init-
   table-segment is now a target, not a reserved-for-6.K.6 hold-out;
   the fixture should pass. Stating this relative to the
   post-6.K.1+6.K.2 state — not as an absolute "27 fixed" number —
   protects the criterion from baseline drift if any other 6.K item
   resolves a fail as a side effect.
2. New unit test `buildImports` raises a named error
   (`error.UnregisteredImportSource` or similar) when an import
   names a module that was never registered, instead of silently
   leaving slot null and surfacing two layers deep as
   `UnknownImportModule`.
3. The cross-module shared-table unit test from 6.K.1 (3) still
   passes end-to-end.
4. **(added 2026-05-04)** Direct call_indirect into a zombie
   funcref dispatches normally (matches wasmtime
   `crates/wasmtime/src/runtime/instance.rs:327-350` partial-init
   semantics). Spec-pure per `WebAssembly/spec/interpreter/exec/eval.ml:427-444`.

#### 6.K.4 — decodeElement element-section forms 5 / 6 / 7

**What**: Extend `decodeElement` (`src/frontend/sections.zig`) to
handle the three remaining Wasm 2.0 §5.5.12 element-section
encodings:

- form 5: passive, reftype, vec(expr) — null-init or ref.func
  exprs
- form 6: active, tableidx, expr, reftype, vec(expr) — explicit
  table + offset, reftype-tagged init exprs
- form 7: declarative, reftype, vec(expr)

Reuse iter-5's `readFuncrefInitExpr` helper (rename to
`readReftypeInitExpr` and accept a reftype tag).

**Why this shape**: completes the §9.2 / 5d-3 carry-over inside
the same iter that needs externref support for table-import
parity (the externref-segment fixture and elem-ref-null fixture
both exercise these forms). Closes a Phase 2 carry-over inside
Phase 6.

**Files touched**: `src/frontend/sections.zig`,
`src/c_api/instance.zig` (element-segment population: handle
externref + null per-cell).

**Acceptance**:
1. `externref-segment.0` (form 6) moves from FAIL to PASS.
2. `elem-ref-null.0` (form 5) moves from FAIL to PASS.
3. A new fixture or unit test exercises form 7 (declarative)
   to confirm it parses without error and registers the
   declared funcrefs as initialised. Form 7 fixtures are not
   in the misc-runtime corpus today; without an explicit test,
   the form-7 path could be silently left unimplemented.

#### 6.K.5 — Label arity formalisation + §14 anti-pattern

**What**:

1. Add a `.claude/rules/single_slot_dual_meaning.md` documenting
   the iter-11 bug ("one field serving two distinct semantic
   purposes is a smell; split into named fields per purpose
   from day 1"). Cite the `Label.arity` example. Reference from
   ROADMAP §14.
2. ROADMAP §14 (forbidden patterns) gains a one-line bullet:
   "single slot pulling double duty across distinct semantic
   axes — must be split per axis from day 1". **Already landed
   in commit `9a5b360` when ADR-0014 was accepted**, so the
   remaining 6.K.5 work skips this sub-step.
3. **Mandatory** (was "optional" in earlier draft): a `comptime`
   structural assertion in `src/interp/mod.zig` that
   `@hasField(Label, "arity") and @hasField(Label, "branch_arity")`,
   plus a unit test that constructs a `Label` with distinct
   `arity` and `branch_arity` values and asserts neither is
   silently aliased to the other. Catches an accidental future
   merge (the precise regression this rule prevents).

**Why this shape**: iter 11 fixed the bug but the design lesson
needs a durable anchor; otherwise the same pattern reappears at
the next "looks like it can share a field" decision (operand
arity vs result arity in some future opcode, etc.).

**Files touched**: `.claude/rules/single_slot_dual_meaning.md`
(new), `src/interp/mod.zig` (comptime assertion + unit test).

**Acceptance**:
1. The new rule file exists and auto-loads when editing
   `src/interp/*.zig` (per `.claude/settings.json` rule glob).
2. ROADMAP §14 entry visible (already done — see (2) above).
3. The `comptime` field check + the unit test compile and
   pass.

#### 6.K.6 — Re-measure partial-init-table-segment

**What**: After 6.K.1–6.K.3 land, re-run
`test-wasmtime-misc-runtime` and check whether
`partial-init-table-segment/indirect-call result[0] mismatch`
self-resolves. If yes: PASS, document in commit message. If no:
investigate as a standalone interp behaviour bug.

**Why this shape**: avoids speculatively patching something that
was almost certainly downstream of (1) / (2). Per
`.claude/rules/no_workaround.md`: fix root causes, not symptoms.

**Acceptance**: one of:

1. The fixture moves from FAIL to PASS (28th failure resolved)
   — close 6.K.6 with the commit message documenting the
   downstream cause confirmed.
2. The fixture still fails AND a new work item `6.K.7` is
   opened in the §9.6 task table with its own scope description
   + acceptance criterion targeting the now-localised root
   cause. 6.K.6 cannot close on "documented as a distinct bug"
   alone; the bug must have a queued next-step. (This blocks
   the cheap-out of "punt by note" — per `no_workaround.md`'s
   §6 reviewer checklist on "what condition makes this expire".)

### 2.1.7 Inventory → work-item coverage check

| §1 item                                                                | Resolved by         |
|------------------------------------------------------------------------|---------------------|
| 1. `Unsupported*Import` for non-memory imports                          | 6.K.3               |
| 2. `Value.ref` lacks instance identity                                  | 6.K.1               |
| 3. Runtime ↔ Instance ↔ allocator ownership ad-hoc                      | 6.K.2               |
| 4. Runtime has no Instance back-pointer                                 | 6.K.2               |
| 5. `decodeElement` forms 5 / 7 (and 6) deferred                          | 6.K.4               |
| 6. `Label.branch_arity = 0` for loop hardcoded                           | 6.K.5               |
| 7. `buildImports` null-slots silently                                    | 6.K.3 (acceptance 2)|
| 8. `partial-init-table-segment/indirect-call` uninvestigated             | 6.K.6               |

All 8 inventory items map to a 6.K.X work item with at least
one explicit acceptance line.

### 2.2 Phase 6 close criterion (unchanged in spirit)

§9.6 / 6.J's text remains "100% PASS, no soft-skip, no tolerated
nonzero". 6.K is added as a precondition for 6.J ("6.J cannot
fire until all 6.K items are [x]").

### 2.3 Phase Status widget

No renumber. Phase 7 stays "JIT v1 ARM64 baseline". The
widget's only update at 6.J close is `6 = DONE, 7 = IN-PROGRESS`,
matching the standard `continue` skill flow.

### 2.4 No follow-up ADR

Everything decided here. No ADR-0015 placeholder. No
"forthcoming charter". If 6.K work surfaces a sub-decision that
needs ADR-grade documentation (e.g. choosing between two
FuncEntity layouts), that ADR is filed at the moment of
decision, not pre-allocated.

## 3. Alternatives considered

The accepted design (pointer-based `*FuncEntity` for `Value.ref`,
single per-instance arena, thunk-based cross-module dispatch
with cycle-free guarantee from instantiation order) is the §2
Decision above. The four alternatives below were rejected.


### α — Defer to Phase 7 / Phase 11 (subagent's option 2)

Keep bare-funcidx encoding for v0.1.0; address cross-module in a
later phase with its own ADR. Rejected: the user's "あるべき論"
directive prohibits this. Pre-release with zero users means
there is no compatibility cost to choosing the right shape now;
deferring just rolls the same work + accumulated retrofitting
cost forward.

### β — Phase 7 = refactor phase (the original ADR-0014
placeholder)

Insert a refactor phase between Phase 6 and JIT. Rejected: the
"refactor phase" framing implied workaround-first then cleanup-
later; Phase 7 dedicated to JIT can't open atop unfixed
cross-module gaps anyway. Splitting the cleanup into a separate
phase introduces a phase boundary (close-criterion ceremony,
handover update, ADR-0015 forthcoming) that adds zero design
value. Doing it inside Phase 6 keeps the work concentrated on
correctness, which is Phase 6's charter (per ADR-0008).

### γ — Packed (instance\_id, funcidx) registry

Encode `Value.ref` as `(instance_id << 32) | funcidx`; maintain
a global `instance_id → *Instance` registry.

**Original rejection** (pre-2026-05-04): requires a process-wide
registry (introduces global mutable state, against §P3); the
registry needs lifecycle management (free instance\_id on
instance delete); JIT phase will want a direct pointer
dereference for `call_indirect` performance, not a registry
lookup. The pointer-based approach (6.K.1) is what JIT will
adopt anyway, so doing it now avoids a second migration.

**Spike review (2026-05-04)** — the rejection still holds, but
for different reasons than originally stated:

1. The `*FuncEntity` pointer encoding (6.K.1) does have the
   partial-init dangling-pointer issue this section originally
   used to reject γ (the registry's lifecycle management is
   what fixes it). But γ's "kill the pointer encoding entirely"
   over-corrects — it makes dispatch into a still-valid foreign
   function trap when the spec says it should succeed. Wasm 2.0
   per `eval.ml:427-444` permits dispatch on cells whose
   allocating module's instantiation later trapped; γ's
   "instance gone → null lookup → trap" semantics deviate from
   that.
2. The right answer is **Alpha** (zombie keep-alive at Store
   level, per 6.K.2 sub-change 4) — keeps the pointer encoding,
   keeps the spec's dispatch-success semantics, fixes the
   lifetime by retaining the arena until store-delete. Mirrors
   wasmtime (`store.rs:146`) and wazero
   (`internal/wasm/table.go:104` `involvingModuleInstances`),
   both of which keep failed-instance state alive via their
   respective lifetime mechanisms (Arc/Weak ref-counts in
   wasmtime, GC roots in wazero).
3. JIT-side prediction in the original rejection was correct for
   the wrong reason: pointer-based dispatch IS what JIT will
   adopt, but only because the arena lifetime is now carried by
   the Store-level zombie list rather than by the dispatch-time
   liveness check γ proposed.

γ stays rejected; Alpha is the chosen design (locked in via
6.K.2 sub-change 4 + 6.K.3's runner-layer retention).

**Author candor (added 2026-05-04 per debt D-004 / lesson
`2026-05-04-beta-funcref-encoding-rejected.md`)**: in the design
discussion that preceded the Step 0 textbook survey, the author
(Claude) initially preferred γ over Alpha on **aesthetic
grounds** — the explicit identity packing felt cleaner than
"hold every failed instance forever". The survey revealed two
costs that the aesthetic preference hid:

- A 2-level lookup on every cross-module call (registry +
  instance + funcidx) doubles the dispatch hot path vs Alpha's
  single pointer dereference. Aesthetic packing disappears under
  the operational cost.
- 10+ years of production wasm runtimes (wasmtime, wazero, the
  spec interpreter) all chose pointer encoding **with full
  awareness** of the dangling-pointer class — the failure-keep-
  alive cost is bounded (one zombie per failed instantiation,
  freed at store close), and they accepted it knowingly.

The Phase 6 takeaway (recorded as a lesson, not a rule): when v2
sits between two design choices and one *looks cleaner* while
the other is what every mature wasm runtime does, the
cleaner-looking one usually has implicit costs that 10 years of
production has paid for elsewhere. Step 0 survey is specifically
designed to surface those costs before v2 re-pays them; trust
the survey output over the aesthetic preference.

### δ — Skip cross-module fixtures via per-fixture ADR

Document each of the 27 fixtures in `.dev/decisions/skip_*.md`
per ROADMAP §9.6 / 6.J's exception clause. Rejected: that
clause is for "v1-era design-dependent fixtures v2 deliberately
rejects on spec-fidelity grounds (§P1)". Cross-module imports
are a v2-supported feature per the wasmtime corpus we vendored;
skipping would be dishonest closure.

## 4. Consequences

### Positive

- Phase 6 closes with **strict 100% PASS** (modulo the
  legitimate v1-era-rejection clause for fixtures that don't
  apply).
- Phase 7 (JIT) opens atop a clean substrate: instance-agnostic
  funcref, single-allocator Runtime, no cross-module gaps,
  no `memory_borrowed`-class flags, formalised Label arity.
- No outstanding unimplemented ADRs roll into Phase 7+.
- The Value-funcref pointer representation is what JIT v1 will
  need anyway for `call_indirect` codegen; doing it now in the
  interp pays JIT's design cost up front.
- 6.K.4 closes a Phase 2 carry-over (element forms 5/6/7),
  shrinking the "outstanding spec gaps" handover list.
- 6.K.5 turns a one-off bug-fix lesson into durable scaffolding.

### Negative

- Phase 6 takes longer to close. The 6.K block is on the order
  of 6 source iterations (one per work item); maybe more if
  6.K.1's test-site migration uncovers subtleties. This is the
  cost the user explicitly accepted ("コストを考えるべきでは
  ない").
- 6.K.1 churns 70+ test sites mechanically. Risk of merge pain
  if other work touches those tests in parallel; mitigated by
  Phase 6 being the only active line of development.
- The pointer-based funcref encoding makes funcrefs allocated
  (one FuncEntity per defined function per instance). For
  small modules this is cheap; for an embedded use-case with
  many tiny modules, a follow-up could pool. Out of scope for
  v0.1.0.

### Neutral / follow-ups

- ROADMAP §9.6 gains 6.K rows (inlined between 6.D and 6.E in
  the reopened-scope table per `continue` skill's first-`[ ]`
  lookup convention; see commit `453c47a`). §9.6 / 6.J row text
  loses the "Phase Status widget flip per ADR-0014 (new §9.7 =
  refactor & consolidation; ...)" annotation — that wording
  referred to the placeholder content this ADR replaces.
- ROADMAP §9.7 (JIT v1 ARM64 baseline) stays at §9.7. No
  renumber. No §9.<N+1> shifts.
- ADR-0008 (Phase 6 v1-conformance baseline) is unaffected; 6.K
  fits its charter because every item is a correctness gap
  surfaced by the misc-runtime gate.
- ADR-0011 (Phase 6 reopen) is unaffected; its renumber-rejection
  rule continues to protect numbering through Phase 6 close.
- ADR-0012 (Phase 6 reopen scope, 6.A〜6.J DAG) gains 6.K rows
  by §18 amendment; the existing 6.A〜6.J semantics are preserved.
- ADR-0013 (runtime-asserting WAST runner design) is unaffected.
- `.dev/handover.md`'s "Phase 6 close → automatic refactor-phase
  ADR drafting" + "ADR-0015 draft brief" + "Carry-over reminders
  for ADR-0015 drafting" sections are removed (they referenced
  the placeholder this ADR replaces). They are replaced by a
  "Phase 6 / 6.K work item table" pointing at this ADR.
- `audit_scaffolding` runs after 6.K.1 + 6.K.2 land in addition
  to its existing pass at 6.J close. `src/interp/mod.zig` (currently
  ~430 lines) gains the `FuncEntity` definition + the
  `instance: ?*anyopaque` field + the comptime null-sentinel
  assertion; if mod.zig grows past the soft cap, split into
  `mod.zig` + `func_entity.zig`.
- Bench delta check after 6.K.1: `call_indirect` gains one
  pointer indirection. Run `bench-quick` on Mac after 6.K.1
  lands; record the delta in `bench/results/recent.yaml`. If
  `call_indirect`-heavy benchmarks regress >10% vs the pre-6.K.1
  baseline, investigate before proceeding to 6.K.2 (e.g. the
  arena allocator's locality may need tuning, or `FuncEntity`
  layout may need cache-line packing). Per ROADMAP §12.1, no
  hard ratio gate; this is an investigation trigger, not a
  block.

## 5. Observations on what made this necessary

Documented for future-self and for the §6.K.5 anti-pattern rule.

Two root-cause families showed up in iter 5–11:

**Family A — single-instance-implicit carry-over from v1**.
This is the dominant family: covers inventory items 1–4 + 7. v1's
single-instance-implicit assumptions were carried into v2 without
re-derivation. The validator/lowerer survived because they're
per-module pure functions with no instance state. The interp
runtime + c\_api binding inherited the assumption silently:
- `Value.ref = funcidx` — single-instance.
- `Runtime` no Instance back-ref — single-instance.
- table.refs as raw funcidxs — single-instance.
- `memory_borrowed` flag introduced ad-hoc when cross-module
  finally arrived — local-fix instead of model-fix.

Per `.claude/rules/no_copy_from_v1.md`, v2 should have re-derived
"how do funcrefs cross instance boundaries" up front. The
re-derivation didn't happen because Phase 1–5 only exercised
single-instance test fixtures (spec testsuite + smoke + WASI
realworld). The misc-runtime corpus vendored in §9.6 / 6.B
introduced cross-module test cases for the first time, and the
gap surfaced under 6.E. ADR-0014's §6.K.1 / 6.K.2 redoes that
re-derivation.

The lesson, queued for `.claude/rules/no_copy_from_v1.md` as a
follow-up: when introducing v2 substrate types (`Value`,
`Runtime`, `Instance`), explicitly enumerate the "what does this
mean across instances" axis even if the immediate test corpus
doesn't exercise it. This protects against the same surface
returning silently in continuation-ref / shared-memory /
multi-thread land.

**Family B — single field overloaded with two semantic axes**.
Inventory item 6 (`Label.arity` doing both end-results and
br-target-arity) is a different anti-pattern: not v1 carry-over
but a design choice that fused two semantic purposes into one
field "because they were equal in Wasm 1.0 for block/if". 6.K.5
turns this into the durable rule
`single_slot_dual_meaning.md` so the next "looks like one slot
fits both" decision triggers a per-axis split from day 1.

The two families share the iter-11 fix-after-the-fact
characteristic but have distinct preventive scaffolding: family
A → `no_copy_from_v1.md` cross-instance check; family B →
`single_slot_dual_meaning.md`.

## 6. References

- ROADMAP §9.6 (Phase 6 — gains 6.K work-item block per §2.1
  above), §9.7 (JIT v1 ARM64 — unchanged), §P1 / §P3 /
  §P10 / §A12, §14 (gains anti-pattern entry per 6.K.5).
  (§P6 — single-pass compilation — was incorrectly listed in an
  earlier draft; §P6 governs the compiler pipeline shape, not
  runtime data structures, so it is not invoked by this ADR.)
- ADR-0008 (`0008_phase6_v1_conformance_baseline.md`) — Phase 6
  charter; 6.K fits because every item is a correctness gap.
- ADR-0011 (`0011_phase6_reopen.md`) — Phase 6 reopen rules;
  renumber-rejection still protects current Phase 6 numbering.
- ADR-0012 (`0012_first_principles_test_bench_redesign.md`) —
  Phase 6 reopen scope, 6.A〜6.J DAG — gains 6.K by §18
  amendment.
- ADR-0013 (`0013_wast_runtime_runner.md`) — runtime-asserting
  WAST runner; independent.
- `.dev/handover.md` "Workaround / debt inventory" (the eight
  items 6.K addresses)
- `.claude/rules/no_copy_from_v1.md` (the rule that should have
  flagged the v1 carry-over earlier; follow-up §5 above)
- `.claude/rules/no_workaround.md` (the rule 6.K.6's "no
  speculative patch" stance derives from)
- iter-5 / iter-7 / iter-11 commit messages
  (`bdef556` / `7cc6715` / `7b26760`) — the substrate work that
  surfaced the inventory
- `.dev/lessons/2026-05-04-beta-funcref-encoding-rejected.md` —
  the observational framing of the §3.γ rejection's "aesthetic
  preference vs production experience" learning; cited from
  §3.γ "Author candor" §.
- `.dev/lessons/2026-05-04-autoregister-spike-regression.md` —
  related Phase 6 lesson on the import-type-validation gap
  (debt D-006).
- `.dev/debt.md` — D-006 (import-type validation), D-010
  (`rawFreeOwned` long-term workaround pending Zig stdlib
  semantics), D-018 (cross-module thunk arena).

## 7. Revision history

| Date       | Commit       | Summary                                                                                          |
|------------|--------------|--------------------------------------------------------------------------------------------------|
| 2026-05-03 | `9a5b360`    | Initial Accepted — replaced placeholder with §9.6 / 6.K work-item block.                         |
| 2026-05-04 | `73766b8`    | 6.K.3 spike → zombie-instance contract (6.K.2 sub-change 4); §3.γ spike review; 6.K.6 expanded. |
| 2026-05-04 | `e4e7493`    | §3.γ "Author candor" + §6.K.3 "How this contract was discovered" added per debt D-004 + lessons. |
| 2026-05-11 | `e85bd561` | **Path drift note** (per 2026-05-11 ADR audit, SUMMARY §3.3 / batch_B). The "Files touched" subsections cite pre-ADR-0023 paths (`src/interp/mod.zig`, `src/c_api/instance.zig`, `src/frontend/sections.zig`, `src/interp/ext_2_0/`). ADR-0023 §7 relocated to `src/runtime/runtime.zig`, `src/api/instance.zig`, `src/parse/sections.zig`, `src/instruction/wasm_2_0/`. Original paths kept as the retrospective design snapshot; current paths follow the relocation. |
| 2026-10-17 | `<backfill>` | #539: a zombie also keeps the `Instance` struct, which §2.1 item 4 said "is freed normally": `Runtime.instance` and the `Ref`s a host call is handed point at it, so freeing it left both dangling. `wasm_store_delete` reaps it with the runtime and arena. |

(SHAs backfilled at the next phase boundary per
`.dev/decisions/README.md` "Revision history" rules; verified by
`scripts/check_adr_history.sh` at audit time.)

### Detailed amendment notes

- **2026-05-03 (initial Accepted)** — ADR replaced its own
  placeholder content (the "Phase 7 = refactor / Phase 8 = JIT"
  sketch) with the §9.6 / 6.K work-item block (6.K.1 funcref
  encoding, 6.K.2 ownership model, 6.K.3 cross-module imports,
  6.K.4 element forms, 6.K.5 Label arity, 6.K.6 partial-init
  re-measure). Decision: keep Phase 7 = JIT v1 ARM64; absorb the
  carry-over into Phase 6.
- **2026-05-04** — Amendment after the 6.K.3 implementation
  spike (reverted; design notes survive at
  `private/notes/p6-6K3-survey.md` and
  `private/notes/p6-6K3-lifetime-survey.md`). The 6.K.1
  `*FuncEntity` pointer encoding has a partial-init dangling-
  pointer issue: cross-module element-segment writes survive a
  later OOB-trap in the importer (per Wasm 2.0 spec) and store
  pointers into the failing instance's arena, which the catch
  path destroys. Per the wasmtime / wazero / spec-interpreter
  cross-reference, the load-bearing fix is a **per-Store zombie-
  instance keep-alive contract** (Alpha): the failed runtime +
  arena park on a Store-private list and live until
  `wasm_store_delete`. 6.K.2 gains sub-change 4 (the zombie list);
  6.K.3 gains the runner-layer retention path; §3.γ rejection is
  re-justified on the more-principled ground that γ's "instance
  gone → null lookup → trap" deviates from the spec's
  dispatch-success semantics (the encoding is fine; it's the
  lifetime that needed the fix). 6.K.6 expands from
  "re-measure-only" to verifying the zombie contract holds across
  the partial-init-table-segment fixture, which now passes
  end-to-end rather than being deferred. The amendment edits
  6.K.2 §2.1 ("Four sub-changes") + 6.K.3 §2.1 ("Partial-init
  dangling-FuncEntity contract" sub-section) + §3.γ ("Spike
  review (2026-05-04)") in place per ROADMAP §18.2's "edit-as-if-
  always-so" discipline. ADR number stays `0014`; cross-references
  in commits and other ADRs are unaffected.
