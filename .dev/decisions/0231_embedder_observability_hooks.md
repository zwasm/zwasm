# 0231 — embedder observability hooks: five events, one funnel per event

- **Status**: Accepted (2026-09-13 — sign-off on PR #454)
- **Date**: 2026-09-13
- **Author**: Junji Takakura
- **Tags**: api, c-abi, observability, runtime

## Context

Discussion #209 asked whether the absence of an observability surface in the
C and Zig APIs was deliberate. It was not: nothing in the ROADMAP, the ADRs or
the C-ABI design had ruled it out, and the first embedder to need it
(`containerd-shim-zwasm`, which has to report per-workload events to a
container runtime) would otherwise reach for the only thing available — timing
calls from outside and inferring the rest. #216 recorded the shape the
discussion settled on; this ADR records the decision itself, because the
callback signatures become C ABI the moment they ship.

Two properties of the engine constrain the design before any taste enters.
The core carries no clock and no allocator of its own — `zwasm_engine_new`
takes the host's — so a hook cannot report a duration without the engine
acquiring a time source it deliberately does not have. And an instance's
address is reusable: `wasm_instance_delete` frees the handle, and the next
instantiation can be handed the same bytes back, so a pointer cannot name one
instantiation across a workload's life.

The harder constraint is structural. Each event has more than one raising
site, and the sites are spread across all three zones: `memory.grow` succeeds
in `runtime.growMemory` (Zone 1, interp), in `setup.jitMemoryGrow` (Zone 2,
called from emitted code), and in `wasm_memory_grow`'s own interp arm (Zone 3,
which reimplements the grow rather than calling Zone 1's). A trap becomes a
`wasm_trap_t` in `trap_surface.allocTrapWithMessage` for the C surface, and
becomes an `InvokeError` with no Trap object at all for the Zig facade. A
design that emits at each site is a design whose two surfaces drift apart on
the first site somebody adds.

## Decision

1. **Five events, one registration function each.** `compile`, `instantiate`,
   `trap`, `fuel_exhausted`, `memory_growth`, registered as
   `zwasm_engine_set_<event>_hook(engine, fn, user_data)` in `include/zwasm.h`
   and as `Engine.set<Event>Hook` in the Zig facade. Not a struct passed by
   value: one function per hook is how `zwasm.h` already grows (`zwasm_version`,
   the sandboxing setters), and it lets a sixth event land without changing a
   struct's size. The slots live on `runtime.Engine`, so both surfaces write
   the same five fields and cannot diverge.

2. **Events, not durations.** A hook says something happened. Timing is the
   host's, which already has a clock; giving the core one to service a hook
   would be a dependency acquired for instrumentation.

3. **Instances are named by a `u64` id, never by a pointer.** Minted from a
   per-engine monotonic counter at the top of `instantiateInternal` — before
   either engine arm runs, so a trap or a grow inside a `(start)` function is
   already attributable. Never reused, not dense: a failed instantiation burns
   its id. `0` means "no instance" (a binding the engine refuses before one
   exists; a `wasm_func_new` function, which belongs to none).

4. **One funnel per event, and the funnel is where the emission lives.**
   `runtime/hooks.zig` (Zone 1, the only zone importable from all three) holds
   the five typedefs and the emit helpers; the events are raised where the
   engine already decides the outcome, not where a caller might want to
   observe it. `fuel_exhausted` is raised INSIDE the trap funnel when the kind
   is 17, so the two hooks cannot disagree about whether a budget ran out or
   about the order they report it in — that pairing is decided in exactly one
   place. A trap's EVENT is also separate from its HANDLE: `reportTrap` and
   `allocTrapQuiet` split out of the funnel because `wasm_instance_new`'s
   `trap_out` is nullable and `src/zwasm/linker.zig` always passes null, so
   emitting as a side effect of building the handle silently cost every
   start-function trap its event — and an out-of-fuel start its
   `fuel_exhausted` too.

5. **No hot struct gains a field.** `Runtime` derives its reporting site from
   the `instance` back-pointer it already keeps; `Instance.id` is declared
   last. Both are layout decisions, not taste: Zig's auto layout re-packs on
   any field added, and a 16-byte slot on `Runtime` moved `memory` by 8 bytes
   and `fuel` by 40 — fields the interpreter reads on every executed
   instruction. `@offsetOf` against 6f6cbc02d now reports every `Runtime`
   field, and every `Instance` field but the appended id, at its pre-change
   offset. The JIT's `MemGrowCtx` does carry a stored site, because emitted
   code reaches the grow helper with only `rt.host_state` in hand and that
   context is off the hot path.

6. **The Zig facade's `invoke` keeps its body in one function.** The hook needs
   one place that sees every failure of both engine arms, and the obvious shape
   — move the body into a helper and wrap the call in a `catch` — cost the
   interpreter 10.8% at 16 loop trips and 14.6% at 512, reproducibly, while the
   per-call constant did not move at all. What regressed was `dispatch.run`'s
   compilation in the caller, not any work the hook added. The helper is
   therefore `inline fn`, which returns both rows to within the control's
   drift, and its doc comment carries the numbers so the keyword is not
   mistaken for decoration. (`errdefer |err|` would have been the tidier shape
   and does not compile here: the body has `return`s of an error-set value,
   which the payload capture rejects.)

7. **Trap classification is the existing `TrapKind`.** The number the hook
   carries is the number `zwasm_trap_kind` returns, which
   `check_trap_abi_sync.sh` already holds to the header. Not `diagnostic.Kind`:
   that is the CLI's vocabulary and is not C ABI. The funnel spells the kind as
   a plain `i32` because it is Zone 1 and the enum is Zone 3; a test in
   `trap_surface.zig` holds the one constant that leaks (17) to the enum.

8. **No build option.** Unregistered slots are a null check on paths that
   already branch; a `-Dhooks` switch would exist only for footprint and would
   rot the way `-Dgc` did (D-525). No invoke hook either: a per-call listener
   is a different design (per-function, decided at instantiate, Before/After/
   Abort), and inventing engine-wide nullable slots for it now would make that
   design harder to reach, not easier.

9. **Three rules are the whole contract**, stated in `include/zwasm.h` and
   nowhere else: calling back into the engine from a hook is undefined; slots
   are set before first use and not changed concurrently (read with a plain
   load, no lock — the engine is single-threaded anyway); a `(ptr, len)` string
   is borrowed for the callback's duration. No guard enforces the first — the
   same posture #445 took for `wasm_*_set_host_info`'s finalizer, for the same
   reason: a re-entrancy guard is engine state that exists only to catch a
   documented misuse.

## Alternatives considered

### Alternative A — one `zwasm_hooks_t` struct set in a single call

- **Sketch**: `zwasm_engine_set_hooks(engine, const zwasm_hooks_t*)`.
- **Why rejected**: adding a sixth event changes the struct's size, which is
  an ABI break for every consumer that compiled against the old one, and
  `zwasm.h` has no versioned-struct convention to absorb it. The per-function
  form has neither problem and matches the header's existing growth.

### Alternative B — emit at each raising site rather than through a funnel

- **Sketch**: call the hook at the three memory-growth sites, the 25
  `allocTrap` call sites, and the facade's error-mapping sites directly.
- **Why rejected**: it makes "does this event fire once" a property somebody
  has to re-establish for every site added later, and the two surfaces would
  have drifted already — the Zig facade builds no `wasm_trap_t`, so a
  Trap-site-only emission would have reported nothing for it.

### Alternative C — pass the instance pointer and let the host key on it

- **Sketch**: `void* instance` instead of `uint64_t instance_id`.
- **Why rejected**: the address is reusable after delete, so a host keyed on
  it attributes a new workload's events to a finished one — silently, and only
  under memory pressure.

### Alternative D — report durations by giving the engine a clock

- **Sketch**: hook pairs (`begin`/`end`) with a timestamp.
- **Why rejected**: the core would acquire a time source it does not otherwise
  need, and a host that wants durations can bracket its own calls. This is the
  point at which #209 chose "events".

## Consequences

- **Positive**: an embedder can attribute compiles, instantiations, traps,
  fuel exhaustion and memory growth to a workload without timing the engine
  from outside. Both surfaces observe one engine, so a host can mix them.
- **Negative**: five callback typedefs become C ABI, and a typedef's signature
  cannot be fixed append-only the way an enum can. There is no consumer yet:
  the signatures should be exercised from `containerd-shim-zwasm` before the
  next tag, or the surface should wait for the tag after it.
  `allocTrap`/`allocTrapWithMessage` grew a parameter, touching 25 call sites
  — mechanical, but it is the diff's bulk.
- **Measured cost**: nothing is added to the interpreter's dispatch loop or to
  JIT-emitted code, and no helper here survives as a symbol in a ReleaseFast
  build. Paired A/B against 6f6cbc02d (`zig build bench-latency`, both binaries
  built first and then run alternately, two rounds) puts every row within the
  machine-state control's own 2.1% drift. Getting there took two findings that
  a single unpaired run had hidden, both recorded in Decision 5 and Decision 6.
  The reason to state them rather than the final number: each was invisible
  until the measurement was paired, and each would come back the moment
  somebody edits the code without knowing why it is shaped this way.
- **Neutral / follow-ups**: the compile event's `accepted` is two-state, and
  `instantiate.frontendValidate` returns a bare `bool`, so a validation that
  failed for lack of memory reports the same way as one that rejected the
  bytes. Splitting them means classifying all 13 of that function's `return
  false` sites and changing a signature the CLI also calls — outside this
  issue. The header says what false actually covers rather than claiming a
  verdict the engine cannot give.
- **Neutral / follow-ups**: `wasm_memory_grow`'s interp arm reimplements the
  grow instead of calling `runtime.growMemory` (it skips the declared-max
  check by its own documented choice), so it raises the event itself rather
  than inheriting it. Folding the two would be a behaviour change and belongs
  to its own issue.

## References

- Issues: zwasm/zwasm#216; Discussion zwasm/zwasm#209
- Related ADRs: ADR-0179 (the per-instance sandboxing setters this mirrors in
  shape), ADR-0200 (the engine fork every event has to cross), ADR-0221
  (`zwasm_version`, the last `zwasm.h` extension), ADR-0225 / #445 (undefined
  re-entry from a callback, stated and not guarded)
- Files: `src/runtime/hooks.zig`, `src/runtime/engine.zig`,
  `src/runtime/runtime.zig`, `src/runtime/instance/instance.zig`,
  `src/engine/setup.zig`, `src/engine/runner.zig`,
  `src/api/trap_surface.zig`, `src/api/instance.zig`,
  `src/api/zwasm_ext.zig`, `src/zwasm/engine.zig`, `src/zwasm/instance.zig`,
  `include/zwasm.h`; tests `test/c_api_conformance/hooks.c`
