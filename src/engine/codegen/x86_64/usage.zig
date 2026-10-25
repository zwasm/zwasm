//! Per-function ZIR usage prescans for x86_64 emit.
//!
//! Extracted from `emit.zig` (line-count
//! discipline after D-087/088/089 whitelist extension). Sibling
//! to `rbp_disp.zig` (form-selectors) under the x86_64 namespace.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`). Imported by `emit.zig`
//! only; no upward dependencies.

const zir = @import("../../../ir/zir.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const ZirFunc = zir.ZirFunc;

/// INVARIANT: this enum IS the truth that the x86_64 prologue
/// gates `PUSH R15 / MOV R15, <entry_arg0>` on. Any op whose emit:
///   1. Reads or writes `[R15 + off]` in its emitted bytes, OR
///   2. Invokes a runtime callback (trampoline, host dispatch,
///      memory.grow / table.grow) that itself reads R15, OR
///   3. Generates a trap-stub fixup (the trap stub writes
///      `trap_flag` / `trap_kind` via R15),
/// MUST be listed here. Drift = silent miscompile on Linux x86_64
/// (Mac aarch64 is structurally immune — its prologue always sets
/// X19). See lesson
/// `.dev/lessons/2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`
/// for the D-180 case study (EH ops missed → JIT read garbage R15
/// from Linux loader base address).
///
/// Detection hook: `bash scripts/check_uses_runtime_ptr.sh`.
///
/// Returns `true` when the function emits any op that requires
/// R15 to hold the runtime pointer at execution time. R15 is
/// loaded in the prologue and used by:
///
/// - Memory ops (load / store / size / grow / copy / fill —
///   all sizes + v128 family) — vm_base / mem_limit reload via
///   `[R15+...]`.
/// - Globals (`global.get` / `global.set`) — globals table base
///   via `[R15+...]`.
/// - Call / call_indirect — funcptr / sig-table base via R15.
/// - Trap-stub-emitting ops (`unreachable`, div / rem trap
///   stubs, trunc_trap stubs) — write `1` to
///   `[R15+trap_flag_off]` on trap path. Without R15 set,
///   the store hits a garbage address; the runner-side
///   trap_flag check sees 0 (no trap) AND adjacent memory
///   corruption manifests as glibc dl-fini assertions at
///   process exit on Linux x86_64. D-087/088/089 cohort
///   (per ADR-0056) discharged by adding the
///   div / rem / trunc_trap ops to this whitelist.
///
/// **Same-class grep target**: when adding a new ZirOp that
/// emits a trap-stub fixup (or otherwise references R15), add
/// it BOTH here AND at the op's emit site. Forgetting either
/// surfaces as silent miscompile (Mac aarch64 unaffected; x86_64
/// looks fine until the runtime trap path executes).
pub fn usesRuntimePtr(func: *const ZirFunc) bool {
    for (func.instrs.items) |ins| {
        // Atomic rmw / cmpxchg / notify / wait (ADR-0168): callout
        // through `[R15+atomic_*_fn(s)_off]` + passes rt in arg0 →
        // needs R15. D-180 class.
        if (jit_abi.isAtomicRmw(ins.op) or jit_abi.isAtomicCmpxchg(ins.op) or
            jit_abi.isAtomicNotify(ins.op) or jit_abi.isAtomicWait(ins.op)) return true;
        switch (ins.op) {
            // Memory family (scalar + v128).
            .@"i32.load",
            .@"i32.load8_s",
            .@"i32.load8_u",
            .@"i32.load16_s",
            .@"i32.load16_u",
            .@"i32.store",
            .@"i32.store8",
            .@"i32.store16",
            .@"i64.load",
            .@"i64.load8_s",
            .@"i64.load8_u",
            .@"i64.load16_s",
            .@"i64.load16_u",
            .@"i64.load32_s",
            .@"i64.load32_u",
            .@"i64.store",
            .@"i64.store8",
            .@"i64.store16",
            .@"i64.store32",
            // Wasm threads/atomics (ADR-0168) — the atomic load/store
            // emit reloads vm_base / mem_limit via `[R15+...]` exactly
            // like the plain memory family. Omitting them = D-180-class
            // silent miscompile: a function whose ONLY memory ops are
            // atomic got the 4-byte (uses_runtime_ptr=false) prologue,
            // so R15 was never set and the store/load hit a garbage base
            // (returned 0 on x86_64; Mac arm64 immune — X19 always set).
            // rmw/cmpxchg join here when their JIT emit lands (callout
            // passes rt=RDI=R15 + a trap-stub fixup).
            .@"i32.atomic.load",
            .@"i32.atomic.load8_u",
            .@"i32.atomic.load16_u",
            .@"i64.atomic.load",
            .@"i64.atomic.load8_u",
            .@"i64.atomic.load16_u",
            .@"i64.atomic.load32_u",
            .@"i32.atomic.store",
            .@"i32.atomic.store8",
            .@"i32.atomic.store16",
            .@"i64.atomic.store",
            .@"i64.atomic.store8",
            .@"i64.atomic.store16",
            .@"i64.atomic.store32",
            .@"f32.load",
            .@"f64.load",
            .@"f32.store",
            .@"f64.store",
            .@"v128.load",
            .@"v128.store",
            .@"v128.load8_splat",
            .@"v128.load16_splat",
            .@"v128.load32_splat",
            .@"v128.load64_splat",
            .@"v128.load32_zero",
            .@"v128.load64_zero",
            .@"v128.load8_lane",
            .@"v128.load16_lane",
            .@"v128.load32_lane",
            .@"v128.load64_lane",
            .@"v128.store8_lane",
            .@"v128.store16_lane",
            .@"v128.store32_lane",
            .@"v128.store64_lane",
            .@"v128.load8x8_s",
            .@"v128.load8x8_u",
            .@"v128.load16x4_s",
            .@"v128.load16x4_u",
            .@"v128.load32x2_s",
            .@"v128.load32x2_u",
            // Globals / memory metadata / calls.
            .@"global.get",
            .@"global.set",
            .@"memory.size",
            .@"memory.grow",
            .@"memory.copy",
            .@"memory.fill",
            // memory.init reads data_segments_ptr +
            // data_dropped_ptr + mem_limit + vm_base from [r15+off].
            .@"memory.init",
            .call,
            .call_indirect,
            // call_ref: emit does MOV <arg0>, R15 (runtime_ptr →
            // callee) + a null-check trap-stub fixup ([R15+trap_flag_off]).
            // Both read R15 → D-208: missing entry meant a null funcref
            // returned 0 on x86_64 instead of trapping (the trap stub
            // wrote trap_flag via an uninitialised R15). Mac arm64 immune
            // (prologue always sets X19). The positive call_ref test
            // survived because its callee never dereferenced the bad rt.
            .call_ref,
            // ADR-0112 D4: return_call emits MOV RDI, R15
            // (emitLoadCalleeRtSameModule) — reads R15. Must be
            // whitelisted so the prologue PUSH-saves R15 (otherwise
            // the MOV reads uninitialised R15 → silent miscompile,
            // D-180-class).
            .return_call,
            // return_call_indirect ALSO reads R15: bounds via
            // [R15+table_size_off], sig via [R15+typeidx_base_off],
            // funcptr via [R15+funcptr_base_off]. Same D-180 risk
            // class.
            .return_call_indirect,
            // return_call_ref: emitLoadCalleeRtSameModule (MOV
            // RDI, R15) + null-check trap-stub fixup. Same D-208/D-180
            // risk class as call_ref (cyc208 ungated → 0 on x86_64).
            .return_call_ref,
            // Trap-stub emitters: unreachable + div / rem (i32/i64
            // × s/u) + trunc_trap (i32/i64 × f32/f64 × s/u) +
            // ref.as_non_null. All write `[r15+trap_flag_off]` on
            // the trap path; require R15 initialised. ref.as_non_null
            // is an exact D-180 hazard
            // (test trapped on Mac arm64 + returned 0 on ubuntu
            // x86_64 before this whitelist entry, because the trap
            // stub wrote trap_flag via an uninitialised R15).
            .@"ref.as_non_null",
            // GC-on-JIT: i31.get_s / i31.get_u emit a null /
            // non-i31 trap-stub fixup (TEST src,1 + JE → trap stub
            // writes trap_flag via [R15+off]). Exact D-180 hazard —
            // without R15 pinned, a null i31.get_* returns garbage
            // instead of trapping on x86_64 (Mac arm64 immune; X19
            // always set). ref.i31 is NOT here (no trap, no R15).
            .@"i31.get_s",
            .@"i31.get_u",
            // GC-on-JIT: struct.new_default CALLs the jitGcAlloc
            // trampoline with rt in RDI (= R15) → needs R15 pinned
            // (D-180 class). arm64 emit landed first; the x86_64 emit
            // (D-211) inherits this whitelist entry.
            .@"struct.new_default",
            // GC-on-JIT: struct.get loads the gc_heap slab base
            // from [R15 + gc_heap_off] (= X19 on arm64) → needs R15
            // pinned. arm64 emit landed first; x86_64 emit = D-211.
            .@"struct.get",
            // D-225: struct.get_s / struct.get_u (packed i8/i16 sign/zero-
            // extend) load the slab base the same way → also need R15 pinned.
            .@"struct.get_s",
            .@"struct.get_u",
            // GC-on-JIT: struct.new CALLs jitGcAlloc (rt=RDI=R15)
            // AND reloads the slab base from [R15 + gc_heap_off] for the
            // field stores → needs R15 pinned (mirror of arm64).
            .@"struct.new",
            // GC-on-JIT: struct.set reloads the slab base from
            // [R15 + gc_heap_off] for the field store → needs R15 pinned.
            .@"struct.set",
            // GC-on-JIT array: array.new_default CALLs
            // jitGcAllocArray (rt=RDI=R15); array.len loads the slab base
            // from [R15 + gc_heap_off] → both need R15 pinned.
            .@"array.new_default",
            .@"array.len",
            // array.get / array.set reload the slab base from
            // [R15 + gc_heap_off] for the element access → need R15 pinned.
            .@"array.get",
            .@"array.set",
            // array.get_s / array.get_u reload the slab base for
            // the packed element load (then MOVSX / MOVZX) → need R15 pinned.
            .@"array.get_s",
            .@"array.get_u",
            // array.fill CALLs jitGcArrayFill with rt=RDI=R15.
            .@"array.fill",
            // array.copy CALLs jitGcArrayCopy with rt=RDI=R15.
            .@"array.copy",
            // array.new_data CALLs jitGcArrayNewData (rt=RDI=R15).
            .@"array.new_data",
            // array.new_elem CALLs jitGcArrayNewElem (rt=RDI=R15).
            .@"array.new_elem",
            // array.init_data / array.init_elem CALL
            // jitGcArrayInit{Data,Elem} (rt=RDI=R15) + emit a trap-stub fixup
            // on the 0 return → need R15 pinned (D-180 class).
            .@"array.init_data",
            .@"array.init_elem",
            // ref.test / ref.test_null CALL jitGcRefTest (rt=RDI=R15).
            .@"ref.test",
            .@"ref.test_null",
            // ref.cast CALLs jitGcRefCast (rt=RDI=R15).
            .@"ref.cast",
            // ref.cast_null CALLs jitGcRefTest (rt=RDI=R15).
            .@"ref.cast_null",
            // br_on_cast / br_on_cast_fail CALL jitGcRefTest (rt=RDI=R15).
            .br_on_cast,
            .br_on_cast_fail,
            // array.new CALLs jitGcAllocArrayFill (rt=RDI=R15).
            .@"array.new",
            // array.new_fixed CALLs jitGcAllocArray (rt=RDI=R15)
            // + reloads the slab base from [R15+gc_heap_off] for the element
            // stores → needs R15 pinned.
            .@"array.new_fixed",
            .@"unreachable",
            // ref.func loads func_entities_ptr
            // from [r15+off]. Requires R15.
            .@"ref.func",
            // data.drop / elem.drop load
            // dropped_ptr from [r15+off] then byte-store 1.
            .@"data.drop",
            .@"elem.drop",
            // Per ADR-0058: table.get / table.set
            // / table.size load tables_ptr from [r15+off] then index
            // the TableSlice array (refs / len reads). table.get
            // and table.set also emit trap-stub fixups for the
            // bounds check; all three require R15 initialised.
            .@"table.get",
            .@"table.set",
            .@"table.size",
            // table.fill — emits trap-stub fixups
            // for the dst+n bounds check; requires R15 initialised.
            .@"table.fill",
            // table.copy — emits trap-stub fixups
            // for dst+n + src+n bounds checks; requires R15.
            .@"table.copy",
            // table.init — same trap-fixup
            // surface (src+n vs seg.len, dst+n vs tables[x].len).
            .@"table.init",
            // D-122/D-125: table.grow
            // loads `table_grow_fn` ptr from `[r15+off]` and CALLs
            // through it (mirror of memory.grow's ADR-0059 callout).
            // Without R15 initialised, the LDR reads garbage and
            // CALL jumps to an invalid address (SEGV).
            .@"table.grow",
            .@"i32.div_s",
            .@"i32.div_u",
            .@"i32.rem_s",
            .@"i32.rem_u",
            .@"i64.div_s",
            .@"i64.div_u",
            .@"i64.rem_s",
            .@"i64.rem_u",
            .@"i32.trunc_f32_s",
            .@"i32.trunc_f32_u",
            .@"i32.trunc_f64_s",
            .@"i32.trunc_f64_u",
            .@"i64.trunc_f32_s",
            .@"i64.trunc_f32_u",
            .@"i64.trunc_f64_s",
            .@"i64.trunc_f64_u",
            // Phase 10 EH (ADR-0114 D6 + ADR-0119) — `throw` /
            // `throw_ref` emit `MOVABS R10, trampoline; CALL R10`;
            // the trampoline reads `[R15 + eh_table_off]` etc. to
            // run `dispatchThrow`. Without R15 initialised, those
            // reads see whatever was in R15 at process startup
            // (typically Linux loader base, e.g. 0x7ffff7ffd000)
            // and the EH dispatch silently misroutes (e2e fixture
            // returns 0 instead of catching).
            //
            // `try_table` doesn't emit any R15-dependent bytes
            // directly, but its semantic completion relies on the
            // throw site reaching the trampoline; including it
            // here is defensive — a try_table with no inner throw
            // is a valid Wasm shape and would unnecessarily emit
            // R15 setup, but the cost is 13 bytes (probe + sentinel)
            // and the asymmetric "throw forces R15, try_table
            // doesn't" rule is harder to maintain correctly.
            .throw,
            .throw_ref,
            .try_table,
            // ADR-0179 #3a / D-314 — a `loop` makes every backward br /
            // br_if / br_table to its header emit the back-edge interrupt
            // poll, which reads `[R15 + interrupt_ptr_off]` AND emits a
            // trap-stub fixup (stub writes trap_flag/trap_kind via R15).
            // Without this entry a no-call tight loop gets the no-R15
            // prologue and the poll would read garbage — the exact D-180
            // silent-miscompile class (Mac arm64 immune; X19 always set).
            .loop,
            => return true,
            else => {},
        }
    }
    return false;
}
