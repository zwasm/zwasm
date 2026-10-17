# 0232 — trap origin and trace on the interpreter: module offsets and a per-thread trace buffer

- **Status**: Accepted (2026-10-17 — PR #542)
- **Date**: 2026-10-16
- **Author**: Junji Takakura
- **Tags**: interp, api, c-abi, observability

## Context

`wasm_trap_origin` returns null and `wasm_trap_trace` an empty vector on every
trap (#498): a `Trap` carries a kind and a message and nothing about where it
happened, so a host can say what went wrong but not in which function. The
interpreter has what is needed — every frame on its `Runtime` knows its
function and `pc` — and the proof of concept for a debugger (#457, from
Discussion #452) added the missing piece, a table from instruction to byte
offset in the module.

Four facts constrain the design.

- **A ZIR `pc` is zwasm's own numbering.** `Frame.pc` indexes
  `ZirFunc.instrs`; the JIT lowers each function again and its hoist pass
  inserts instructions, so the same wasm instruction has a different index
  there. `wasm.h`'s `wasm_frame_module_offset` is a byte offset in the module,
  the unit LLDB and `wasm-tools print --print-offsets` also use.
- **A call into another instance switches `Runtime`.** The callee's frame is
  pushed on the callee's own `Runtime`, with nothing linking it to the
  caller's stack. Two paths do this: `mvp.invokeCrossRuntime` (reached from
  `call_indirect` / `call_ref` and their tail forms since #537, and from the
  C-side `cross_module.thunk`), and a host import that calls back into a
  guest function.
- **A tail callee's locals die inside `run`.** The trampoline frees the
  previous callee's locals at the next switch and the last callee's at exit,
  so anything that reads the trapping frame after `dispatch.run` has returned
  reads freed memory when that frame was reached by `return_call` (found in
  #457's review).
- **An error leaves through every level, and the error says what it is.**
  Any error passes through one `run` per wasm frame on its way out. A wasm
  exception travels as `Trap.UncaughtException` until a caller frame's
  `try_table` catches it; `invoke`, the host-call arm and
  `invokeCrossRuntime` re-raise it unchanged, so at every level a trap and a
  throw that may yet be caught can be told apart. `proc_exit` unwinds as
  `error.ProcExit`, which is not a `Trap`.

## Decision

1. **A location is a module byte offset.** `Lowerer.emit` records, for every
   `ZirInstr` it appends, the offset of the opcode that produced it from the
   function's start (`ZirFunc.src_offsets`, parallel to `instrs`); the
   lowerer is handed the length of the local declarations so that the
   offsets it counts from the first opcode land on that origin.
   `instantiateRuntime` records where the function starts in the module
   (`ZirFunc.func_start`): the first byte of the body after its size, that
   is, where the local declarations begin. `func_start` + `src_offsets[pc]`
   is `wasm_frame_module_offset`; `src_offsets[pc]` alone is
   `wasm_frame_func_offset`, measured from the same origin wasmtime's
   `FrameInfo::func_offset` uses (the body's reader start, local
   declarations included). The name avoids `body_offset`, which
   `Diagnostic.validate` already uses for an offset *within* a body. The ZIR
   `pc` is never a location's name.
   The table is not total: instructions directly after `return` /
   `unreachable` are dropped by the lowerer's dead-code arm (D-093), so they
   have no entry, and an import's placeholder function is built without the
   lowerer and has no table at all. Across 7 real-world modules and 989,767
   instructions the table pairs one-to-one, same opcode, with `wasm-tools`;
   the 114 exceptions are all of the dead kind (#452).

2. **A trap's site is taken from inside the loop, one level at a time.** An
   `errdefer |err|` in `dispatch.run` runs while the frame that `run` owns
   and its locals are intact — before the trampoline frees a tail callee's
   locals, before `invoke` pops the frame — and it fires once per nested
   `run` as the error leaves.
   - **What is recorded.** When the error is not `Trap.UncaughtException`,
     and `run` is at the depth it entered at with a frame of its own
     (`rt.frame_len == entry_depth > 0`; a tail switch that failed after
     popping, or a frame `run` pushed for itself, is left to the caller),
     the firing appends that frame to the trace buffer: the function index,
     the module offset and the function-relative offset, all read from the
     `Runtime` and its `ZirFunc`. The entry names no instance and does not
     follow `Runtime.instance`, which can point at a freed instance (see
     below). A frame whose function has no offset table (an import
     placeholder) appends nothing. The buffer holds 64 entries, innermost
     first; frames past 64 are dropped from the outer end. An exception
     appends nothing, so a throw costs nothing extra whether or not it is
     caught.
   - **Which recorded errors are traps** is not decided here. The loop
     records every error but an exception; the surface that turns the error
     into a trap decides its kind with `trap_surface.mapInterpTrap`, the one
     table of which error is reported as which trap, and attaches the trace
     to the trap it builds. There is no second list in the loop, and the
     loop could not use that one (it is in `api/`, Zone 3; the loop is
     Zone 2). A `proc_exit` trace is therefore the site of the `proc_exit`
     call, on the `wasi_exit` trap the C surface returns.
   - **The buffer holds only the failure that is unwinding now.** It is one
     buffer per thread (`threadlocal`). The engine is single-threaded today
     (`include/zwasm.h`, "Threads"), so this is one buffer in practice, but it
     adds nothing to the process-global state that contract names as the
     obstacle to running Stores on separate threads. Nothing moves between
     `Runtime`s: a trace crosses module boundaries because every level
     appends to the same buffer. An entry is 12 bytes (three `u32`s), so the
     buffer adds under 1 KiB of thread-local storage, against the 289 KiB
     #534 measures. Everything that enters the interpreter from outside goes
     through **one entry function** in `src/interp/`, `inline` like the
     facade's `invokeInner` (whose record shows what an out-of-line wrapper
     around `dispatch.run` costs): it checks the native stack as
     `mvp.invoke` does, sets the buffer's contents aside, starts the call
     with the buffer empty, and puts the contents back on the way out, after
     the caller has copied what the call left. Today five places enter from
     outside — the three calls to `dispatch.run` outside `src/interp/`
     (`wasm_func_call`, the start function, the facade's `invoke`) and the
     two that call a `host_calls` entry's `fn_ptr` directly (a facade call
     of a re-exported import, an imported start function) — and all five go
     through it; the function's doc says that anything entering the
     interpreter from outside must, and this ADR points there rather than
     listing call sites that will change. Outside an unwind the buffer is
     empty, so this is one length check; contents are set aside only when a
     guest is entered while a trap is unwinding, which nothing in this ADR
     does — the ADR-0231 hooks may not call back into the engine
     (`include/zwasm.h`, hook rule 1) — but which the rule keeps from
     corrupting a trace. A host function
     that calls an inner guest which traps, then returns that trap to the
     outer guest, leaves the outer trace starting at the host-call site with
     none of the inner frames: the trap the host returned is a new failure
     there.
   - **What the C surface returns.** The trap the C surface builds copies
     the buffer; `wasm_trap_origin` is its first entry and `wasm_trap_trace`
     all of them, with `wasm_frame_func_index`, `_func_offset` and
     `_module_offset` filled. `wasm_frame_instance` returns null: an
     instance's `Runtime` can outlive it — `failBuiltInstance` and
     `wasm_instance_delete` park the `Runtime` and its arena as a zombie and
     free the `wasm_instance_t` — so a recorded pointer could dangle. An
     exception that escapes to the host has origin null and an empty trace.
     The C header states it. A tail call into another instance today runs
     nested, keeping the caller's frame (#538), so the trace lists that
     frame — true to what ran; once #538 is fixed, it will not appear. The
     facade's `invoke` returns a bare error and so drops the trace: a facade
     caller does not learn where a guest trapped. Whether the facade carries
     a trace waits for someone to ask.

3. **Cost: the success path is measured against where `run` lands.**
   `run` gains an `errdefer`, and the external `dispatch.run` calls go
   through the entry function — the same kind of change that cost the
   interpreter 10.8–14.6% when `invokeInner` was taken out of line
   (`src/zwasm/instance.zig`). It is measured as that record was:
   `zig build bench-latency` against `main` (`2afe784da`), interleaved, two
   rounds, x86_64-linux, ReleaseFast, with no foreign load. Beside it,
   placebos — `main` plus a change that executes nothing: an exported
   function nobody calls (four sizes, 156 B – 8 KB), or `run` declared
   `align(32 / 64 / 128)`. Rows by where `run` starts, mod 64:

   | interp, vs `main` | `run` at | 16 trips | 512 trips |
   |---|---|---|---|
   | `main` | 0x30 | — | — |
   | same binary, twice | 0x30 | 0.3% | 0.1% |
   | placebos (4) | 0x10 | +3.7 – +4.0% | +5.8% |
   | this ADR | 0x10 | +2.8% | +4.6% |
   | `align` placebos (3) | 0x00 | +8.4 – +9.4% | +12.8 – +13.1% |

   The JIT rows stay within ±0.7% for every build. On the interpreter this
   bench measures where the hot code lands, not the code added: the `align`
   builds add nothing and are the slowest. #541 traced three placements that
   each move the row by about 10% — the dispatch loop inside `run` against a
   64-byte boundary, the handler table's address, and the handlers' own
   placement — and the builds above move all three together, so the table
   attributes nothing to this change. What this change does to the hot code
   itself: `ZirFunc` grows from 488 to 520 bytes and `blocks` moves from
   offset 72 to 136, so `loopOp` reads it with a 4-byte displacement instead
   of a 1-byte one and is 6 bytes longer; the instructions it executes are
   the same, and callgrind counts 1.9% fewer in `run` than on `main`. With
   the loop and the table pinned — rebased on #541's candidate C (#544) and
   measured against #544 without this change — the interpreter rows move
   +0.6% and +0.8% at the median of 10 interleaved runs in two series,
   within that build's own spread; #544's own measurement put it at −0.5 /
   +0.6%. Accepted on that basis. The JIT rows moved by about 2% in one
   series, all of it in `computeStackLimit`'s glibc call; with the binaries
   run from one directory the gap was gone (−0.2%), and removing the
   thread-local buffer changed nothing. Outside engine code; cause not
   identified.

4. **Interpreter only.** On a JIT-backed instance the trap's origin stays
   null and its trace empty, as today, and the C header says so. The JIT has
   no frame stack the runtime can read; giving its traps a site is a
   different design (D-022's trap-stub ring buffer is one) that this ADR
   does not pre-empt.

## Alternatives considered

### Alternative A — take the trace in the ADR-0231 `trap` hook

- **Sketch**: give the trap hook, or the C surface where it builds the
  `Trap`, a frame vector read from the `Runtime`.
- **Why rejected**: both run after the unwind — the hook fires from
  `allocTrapWithMessage`, `reportTrap` and the facade's `emitInvokeTrap` —
  when the frames are popped and a tail callee's locals are already freed
  (Context, third fact). Only a point inside `run` sees the trapping frame.

### Alternative B — copy the whole stack once, at the innermost level

- **Sketch**: the innermost `errdefer` copies every live frame of its
  `Runtime` into the buffer; outer levels do nothing.
- **Why rejected**: one `Runtime`'s frame stack is not one call chain. After
  A → B → A, A's stack holds the frames of both visits with B's frames
  between them on another `Runtime`, and nothing records the order to put
  them back in. Appending one frame per level takes the order from the
  unwind itself.

## Consequences

- **Positive**: a trap on the interpreter carries its origin and a complete
  trace on the C surface, where both were empty since the C ABI landed
  (#498). What the trace cannot know (an escaped exception, a JIT frame, the
  instance) it leaves empty rather than guessing.
- **Negative**: `ZirFunc` grows an `ArrayList(u32)` per function (4 bytes
  per instruction) that the JIT's own lowering also fills and then ignores,
  and each thread gains the trace buffer (under 1 KiB).
- **Measured cost**: Decision 3.
- **Neutral / follow-ups**: ADR-0016 M3 (a trap's location) and M5
  (backtraces) are met for the interpreter by Decision 2, by a different
  mechanism: no `setDiag` at each raise site, a frame per unwound level
  instead. D-022 (a JIT trap-stub ring buffer) is not touched. The two
  `trap_surface.zig` comments that cite "ADR-0022 / D-022" for the
  frame-less trap are rewritten to say the frame-less case is the JIT's.
  An interpreter debugger (a slot in the loop, a controller, a GDB stub) is
  a separate ADR built on this one's table and buffer — Discussion #452,
  PR #457.

## References

- Issue zwasm/zwasm#498 (trap origin / trace empty); Discussion
  zwasm/zwasm#452 and PR zwasm/zwasm#457 (the offset table, the `errdefer`
  finding); PR zwasm/zwasm#537 (#517: the tail forms route a foreign callee
  through `invokeCrossRuntime`); issue zwasm/zwasm#538 (a cross-instance
  tail call nests a frame); issue zwasm/zwasm#534 (static TLS size)
- Related ADRs: ADR-0016 (M3 / M5 met for the interpreter), ADR-0231 (the
  `trap` hook; the paired-measurement protocol), ADR-0167
  (`checkNativeStackLimit`)
- `include/wasm.h` — `wasm_frame_*`, `wasm_trap_origin`, `wasm_trap_trace`;
  `include/zwasm.h` — "Threads"
- wasmtime 48: `FrameInfo::func_offset`
- Files: `src/parse/sections_codes.zig`, `src/ir/lower.zig`,
  `src/ir/zir.zig`, `src/runtime/instance/instantiate.zig`,
  `src/interp/dispatch.zig`, `src/interp/trap_trace.zig`,
  `src/api/trap_surface.zig`, `src/api/instance.zig`, `src/api/ref_base.zig`,
  `src/zwasm/instance.zig`; `test/c_api_conformance/trap_origin.c`
