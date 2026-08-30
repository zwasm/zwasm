// FILE-SIZE-EXEMPT: the JIT ABI contract file — extern structs + offset constants + the host-callback families that JitRuntime FIELD DEFAULTS name directly (gc_alloc_fn = jitGcAlloc etc., lines ~606-614), so extracting any callback family creates a definition cycle (ADR-0099 N1; investigated 2026-08-12, split rejected).
//! JIT Runtime ABI (ADR-0017).
//!
//! `JitRuntime` is the extern struct passed to every JIT-compiled
//! Wasm function via X0 (ARM64) / RDI (x86_64 System V). The
//! function's prologue LDRs the five invariants from `*X0` once
//! per call, then the body uses them via the
//! `reserved_invariant_gprs` (ADR-0018):
//!
//!   X28 ← vm_base       (linear-memory base ptr)
//!   X27 ← mem_limit     (linear-memory size in bytes)
//!   X26 ← funcptr_base  (table 0 funcptr array)
//!   X25 ← table_size    (table 0 entry count, X-width u64 — D-475 table64)
//!   X24 ← typeidx_base  (parallel u32 typeidx side-array)
//!
//! `extern struct` keeps the layout deterministic across Zig
//! versions and across the ABI boundary the prologue depends on.
//!
//! Zone 1 (`src/runtime/`) — Zone 2 (jit/, jit_arm64/, jit_x86/)
//! consumers import this module to thread the offset constants
//! into prologue emission. Caller-side construction (host code
//! building a JitRuntime before invoking the entry frame) lives
//! in Zone 3 (cli/, c_api/).

const std = @import("std");
const zir = @import("../../../ir/zir.zig");
const Value = @import("../../../runtime/value.zig").Value;
const FuncEntity = @import("../../../runtime/instance/func.zig").FuncEntity;
const exception_table = @import("exception_table.zig");
const exception_mod = @import("../../../feature/exception_handling/exception.zig");
const code_map = @import("code_map.zig");
const heap_mod = @import("../../../feature/gc/heap.zig");
const gc_type_info = @import("../../../feature/gc/type_info.zig");
const object_alloc = @import("../../../feature/gc/object_alloc.zig");
const root_scope = @import("../../../feature/gc/root_scope.zig");
// array.init_data recovers the typeidx from the object header (the immediate
// can't fit the 6-arg SysV budget); the mark-bit must be masked off first.
const mark_sweep = @import("../../../feature/gc/collector_mark_sweep.zig");
// ref.test / ref.cast share the interp's subtype-check core (one algorithm,
// two runtimes) — see `gcRefMatchesNonNullCore`.
const ref_test_ops = @import("../../../instruction/wasm_3_0/ref_test_ops.zig");
const build_options = @import("build_options");

// Build-level guard (matches emit.zig): the GC / subtyping JIT helpers below
// are held as `JitRuntime` fn-pointer field defaults (ADR-0203 D1 / D-516
// position-independence). A field default takes the helper's ADDRESS
// unconditionally, so without this guard the helpers — and everything they
// reach (`feature/gc/*`, `instruction/wasm_3_0/*`) — stay live even in a
// `-Dwasm=v1_0` build, tripping `check_build_dce` (a `wasm_3_0` symbol in a
// v1_0 binary). Wrapping each body in `if (comptime wasm_v3_plus)` lets the
// comptime-false block go un-analysed in sub-v3 builds, so the address points
// at a bare `@panic` stub and the GC code DCEs. Sub-v3 builds can never emit a
// GC / subtyping op (the validator rejects them), so the stub is unreachable.
const wasm_v3_plus = @intFromEnum(build_options.wasm_level) >=
    @intFromEnum(@TypeOf(build_options.wasm_level).v3_0);

/// `@sizeOf(FuncEntity)` — exposed for JIT emit's `ref.func`
/// recipe (`ADD ptr, ptr, #(idx * func_entity_size)`). Comptime
/// derived from the actual FuncEntity struct so layout changes
/// (e.g. adding fields for richer host-call dispatch) are
/// picked up automatically.
pub const func_entity_size: u32 = @sizeOf(FuncEntity);

/// Per-data-segment slice descriptor (per ADR-0056) exposed to
/// JIT `memory.init`. Layout is a fixed
/// 16-byte (ptr, len) pair so the JIT body indexes the
/// `data_segments_ptr` array with a stride of `segment_slice_size`.
/// `len = 0` when the host has dropped the segment OR when the
/// module declared no bytes for it — the JIT's seg_len read uses
/// `data_dropped_ptr[idx]` to override `len` to 0, mirroring the
/// interp's `if (dropped) seg_len = 0` arm.
pub const SegmentSlice = extern struct {
    ptr: [*]const u8,
    len: u64,
};

pub const segment_slice_size: u32 = @sizeOf(SegmentSlice);

/// Per-table slice descriptor (per ADR-0058)
/// exposed to JIT `table.get` / `table.set` / `table.size`,
/// `table.grow` / `table.fill`, `table.copy` / `table.init`.
/// Layout is a fixed 32-byte stride so the JIT body indexes
/// the `tables_ptr` array with `tableidx * table_slice_size`.
///
/// `refs` points to the table's storage as `[*]u64` raw Value bits
/// (each entry is a `Value.ref`-encoded u64; for funcref tables
/// that means `@intFromPtr(&rt.func_entities[funcidx])` or
/// `Value.null_ref` sentinel; for externref tables, host-supplied
/// u64 handles). The interpretation is identical to interp's
/// `TableInstance.refs: []Value`; the JIT loads/stores raw u64
/// without re-tagging.
///
/// `max` is `std.math.maxInt(u32)` when the module's table type
/// has no explicit max (matches interp's `?u32` `null` semantics);
/// otherwise it's the declared upper bound used by `table.grow`'s
/// max-cap check.
pub const TableSlice = extern struct {
    refs: [*]u64,
    /// Entry count. u64 per D-475 (table64): an i64-indexed table's
    /// length is spec-u64; JIT bounds checks compare the (possibly
    /// 64-bit) index against this at X/.q width on both arches.
    len: u64,
    /// Declared upper bound for `table.grow` (u64 per D-475; a
    /// table64 declares u64 limits, spec §5.3.5). `table_no_max`
    /// sentinel when the type has no explicit max.
    max: u64,
    /// TODO(audit): table storage shape — see D-126 / ADR-0068.
    /// Parallel funcptr-view for the same table slot. `refs[i]` carries
    /// the FuncEntity-ptr encoding (per reftype semantics); `funcptrs[i]`
    /// carries the raw native code entry point that `call_indirect`'s
    /// X26 fast path reads (via `funcptr_base` for table 0 / via the
    /// per-table fast path bind for k > 0). The two views encode the
    /// same logical entry in two shapes; ADR-0068's `mirrorWrite`
    /// helper keeps them in sync after every table-mutating op
    /// (`table.set` / `table.copy` / `table.init` / `table.grow` /
    /// `table.fill`). Stride changed 16 → 24 (ADR-0068) → 32
    /// (D-475 u64 len/max); all JIT `tables_ptr` indexers
    /// (op_table.zig / op_call.zig per-arch) dereference via
    /// `table_slice_size` + the `tableslice_*_off` field constants
    /// rather than literals.
    ///
    /// `allowzero` carve-out: externref tables have no funcptr view,
    /// so setup writes the zero sentinel here. JIT mirror code's
    /// leading `CBZ funcptrs_base, .skip` guards against deref.
    funcptrs: [*]allowzero u64,
};

pub const table_slice_size: u32 = @sizeOf(TableSlice);

/// Field byte-offsets within `TableSlice` for the per-arch emitters
/// (D-475: `len` widened to u64 moved `funcptrs` 16 → 24; emitted
/// descriptor loads reference these instead of literals).
pub const tableslice_len_off: u32 = @offsetOf(TableSlice, "len");
pub const tableslice_funcptrs_off: u32 = @offsetOf(TableSlice, "funcptrs");

/// Sentinel for `TableSlice.max` indicating "no explicit max" (per
/// Wasm spec §3.2.1: tables without an explicit max field accept
/// growth up to the index-type range). Mirrors interp's `?u64`
/// `null` arm (u64 per D-475 table64).
pub const table_no_max: u64 = std.math.maxInt(u64);

/// Per-element-segment slice descriptor (per ADR-0058 amendment)
/// exposed to JIT `table.init`. Each entry stores
/// a pre-computed `[*]const u64` of `Value.ref`-encoded values (for
/// funcref segments: `@intFromPtr(&func_entities[fidx])`; for
/// externref: opaque host u64; for null entries: `Value.null_ref`).
/// 16-byte stride matches `SegmentSlice` and `TableSlice`
/// for ABI consistency. `len = 0` when the segment has been
/// dropped via `elem.drop` (override applied via `elem_dropped_ptr`).
pub const ElemSlice = extern struct {
    refs: [*]const u64,
    len: u32,
    _pad: u32 = 0,
};

pub const elem_slice_size: u32 = @sizeOf(ElemSlice);

/// Per-table call_indirect dispatch descriptor (D-112).
/// Each entry carries the funcptr and
/// typeidx base pointers for one declared table, indexed by
/// `call_indirect`'s table_idx (Wasm 2.0 multi-table; spec
/// §3.4.6 + §4.4.10.1). The scalar `JitRuntime.funcptr_base`
/// / `typeidx_base` fields remain backed by table 0's arrays
/// for the legacy single-table fast path (X24/X26 / R15-relative
/// preloads); `tables_jit_ci_ptr[k]` provides the parallel view
/// for `k > 0`. `funcptr_base` matches the scalar field's
/// encoding (native code pointer; null for ref.null funcref or
/// imported funcs not exposed via host_dispatch); `typeidx_base`
/// matches D-111 canonicalization.
pub const TableJitCallInfo = extern struct {
    funcptr_base: [*]const u64,
    typeidx_base: [*]const u32,
};

pub const table_jit_ci_size: u32 = @sizeOf(TableJitCallInfo);

/// Pointer-and-counter bundle the JIT body relies on. Layout
/// extends only at the tail (Phase 8+: trap_buf, host-call
/// dispatch table, gc_root_set ptr) so existing prologue
/// offsets stay valid.
pub const JitRuntime = extern struct {
    /// Linear-memory base pointer. JIT body's bounds-checked
    /// memory ops compute effective addresses as `vm_base + idx`.
    vm_base: [*]u8,
    /// Linear-memory size in bytes. JIT body's bounds check
    /// rejects `idx >= mem_limit` with a trap.
    mem_limit: u64,
    /// Table 0 funcptr array (each entry a u64 native funcptr).
    /// Indexed by `call_indirect`'s computed table index.
    funcptr_base: [*]const u64,
    /// Table 0 entry count. JIT body's call_indirect bounds
    /// check rejects `idx >= table_size` with a trap. u64 per
    /// D-475 (table64) — absorbs the former `_pad0`, so every
    /// subsequent field offset is unchanged.
    table_size: u64,
    /// Parallel array of u32 typeidx values for table 0;
    /// indexed identically to `funcptr_base`. JIT body's
    /// call_indirect sig check compares `typeidx_base[idx]`
    /// against the call site's expected typeidx, traps on
    /// mismatch.
    typeidx_base: [*]const u32,
    /// Trap flag — JIT body's trap stub stores `1` here
    /// before returning, allowing the entry frame to
    /// distinguish "function trapped (and unwound to its
    /// epilogue with a sentinel return)" from "function
    /// returned a value that happens to equal the sentinel".
    /// Caller (host) zeroes this before each call; reads it
    /// after to detect trap.
    ///
    /// Sub-7.5b-ii scope: single boolean. Diagnostic M3 (D-022)
    /// will widen this to a per-trap-kind code (mem OOB, sig
    /// mismatch, idx OOB, NaN, integer overflow, etc.) +
    /// optional trap-site PC for source-location surfacing.
    trap_flag: u32,
    /// Trap kind marker (D-144). Repurposed
    /// from `_pad1`. Per-fixup-class trap stubs (arm64 emit.zig)
    /// pre-set W18 with a distinct ID; the trap stub STR's W18
    /// here so `printCallTrap` can disambiguate bounds vs sig vs
    /// other JIT traps. Sentinel `0` = unmarked (legacy trap stub
    /// path; treat as generic). Codes:
    ///   1  = generic (memory bounds, NaN, range, unreachable, …)
    ///   2  = call_indirect bounds (B.HS)
    ///   3  = call_indirect sig (B.NE)
    /// Layout-stable: replaces the existing 4-byte pad after
    /// `trap_flag`. All offsets in this struct unchanged.
    /// Cleared together with `trap_flag` on every JIT entry (#336): a trap
    /// stub that raises the flag without writing a kind — the generic
    /// `bounds_fixups` bucket — must read as "no kind", not as whatever the
    /// previous invocation left here.
    trap_kind: u32 = 0,
    /// Globals array base pointer (ADR-0027 + ADR-0110
    /// widen). Each entry is one `runtime.value.Value` = 16 bytes
    /// post-widen. JIT body's `global.get` emits `LDR Rd, [X23,
    /// #byte_off]` (ARM64) or `MOV R_dst, [R_scratch + byte_off]`
    /// (x86_64) where `byte_off` is per-global `idx * 16` from
    /// `computeGlobalsLayout` (uniform stride). `globals_base` is
    /// reloaded from `[R15 + globals_base_off]` (x86_64) or
    /// pre-loaded into X23 at function prologue (ARM64) per
    /// ADR-0026's invariant strategy.
    globals_base: [*]Value,
    /// Globals array length. Reserved for future bounds-checked
    /// global access (gc proposal Phase 11+ runtime-typed
    /// globals); not consulted in Wasm 1.0 spec where global
    /// indices are statically validated.
    globals_count: u32,
    _pad2: u32 = 0,
    /// Host-import dispatch table base (chunk 7.9-d). Indexed by
    /// import-function-idx (0..host_dispatch_count). Each entry
    /// is a C-ABI function pointer with signature
    /// `fn (rt: *JitRuntime, ...wasm_args) callconv(.c) <ret>`
    /// — i.e. arg 0 is the JitRuntime ptr (matching the JIT-body
    /// internal calling convention) and args 1..N are the Wasm
    /// imports' params marshalled per platform C ABI. The JIT
    /// emits `LDR X16, [X19 + host_dispatch_base_off]; LDR X16,
    /// [X16, #(idx*8)]; BLR X16` (arm64) / `MOV RAX, [R15 +
    /// host_dispatch_base_off]; MOV RAX, [RAX + idx*8]; CALL RAX`
    /// (x86_64) for `call N` when `N < num_imports`. Until
    /// chunk d-2 lands real WASI handlers, every entry points to
    /// `defaultTrap` (sets trap_flag = 1 + returns 0), preserving
    /// the prior trap-on-import-call observable behaviour.
    host_dispatch_base: [*]const usize,
    /// Number of populated dispatch slots (= module's import-func
    /// count). Reserved for diagnostic checks; the JIT body does
    /// not bounds-check the dispatch idx because validator
    /// rejects out-of-range function indices.
    host_dispatch_count: u32,
    _pad3: u32 = 0,
    /// JIT-execution sentinel (ADR-0034). Every
    /// JIT-emitted prologue stores `1` here unconditionally
    /// after the runtime-ptr handoff completes. Caller pre-clears
    /// to `0` before each guest invocation; post-call read of `0`
    /// proves the JIT body never executed despite compile success;
    /// non-zero proves at least one JIT-emitted prologue ran.
    /// Always-on (no build-flag gate); cost is 8 bytes ARM64 / 7
    /// bytes x86_64 per function prologue.
    jit_executed_flag: u32 = 0,
    _pad4: u32 = 0,
    /// (per ADR-0056, amending ADR-0017): base
    /// pointer to `Runtime.func_entities: []FuncEntity`. Each
    /// entry is a `FuncEntity` struct (size = `@sizeOf(FuncEntity)`,
    /// kept in sync at construction time). JIT `ref.func idx`
    /// emits `LDR Xresult, [X<rt>, #func_entities_ptr_off]` +
    /// `ADD Xresult, Xresult, #(idx * @sizeOf(FuncEntity))` so the
    /// result is `@intFromPtr(&rt.func_entities[idx])`, matching
    /// `Value.fromFuncRef`'s encoding (interp parity). Optional —
    /// caller may pass `&.{}` cast for modules without ref.func.
    func_entities_ptr: [*]const u8 = undefined,
    /// Number of populated entries in `func_entities_ptr`'s array.
    /// JIT `ref.func` does NOT bounds-check (validator rejects
    /// out-of-range funcidx at validate time); this field is for
    /// host-side diagnostic + future debugger hooks.
    func_entities_count: u32 = 0,
    _pad5: u32 = 0,
    /// (per ADR-0056): parallel "data segment
    /// dropped" flag table. JIT `data.drop dataidx` emits
    /// `MOV [r15+data_dropped_ptr_off] + idx, 1` (1 byte per
    /// flag; bool = u8 in Zig extern layout). JIT `memory.init`
    /// reads the same flags before computing seg_len.
    data_dropped_ptr: [*]u8 = undefined,
    data_dropped_count: u32 = 0,
    _pad6: u32 = 0,
    /// (per ADR-0056): parallel "element segment
    /// dropped" flag table. JIT `elem.drop elemidx` emits a byte
    /// store to `[r15+elem_dropped_ptr_off] + idx`. table.init
    /// reads.
    elem_dropped_ptr: [*]u8 = undefined,
    elem_dropped_count: u32 = 0,
    _pad7: u32 = 0,
    /// (per ADR-0056): per-data-segment slice
    /// descriptor array. Each entry is a `SegmentSlice` (16 bytes:
    /// `ptr` + `len`). JIT `memory.init dataidx` indexes this with
    /// stride `segment_slice_size` to read the segment's source
    /// bytes, then memcpy n bytes into linear memory at dst.
    data_segments_ptr: [*]const SegmentSlice = undefined,
    data_segments_count: u32 = 0,
    _pad8: u32 = 0,
    /// (per ADR-0058): per-table slice descriptor
    /// array. Each entry is a `TableSlice` (16 bytes: `refs`,
    /// `len`, `max`). JIT `table.get` / `table.set` / `table.size`
    /// index this with stride `table_slice_size`.
    /// `table.grow` reads `max` for the cap check;
    /// `table.copy` / `table.init` consume both source and
    /// destination slices.
    tables_ptr: [*]const TableSlice = undefined,
    tables_count: u32 = 0,
    _pad9: u32 = 0,
    /// (per ADR-0058 amendment): per-element-
    /// segment slice descriptor array. JIT `table.init elemidx
    /// tableidx` indexes this with stride `elem_slice_size` to read
    /// the segment's pre-computed funcref array, then memcpy n
    /// reftype values into the target table. `elem_dropped_ptr[idx]`
    /// overrides seg.len to 0 for dropped segments.
    elem_segments_ptr: [*]const ElemSlice = undefined,
    elem_segments_count: u32 = 0,
    _pad10: u32 = 0,
    /// (per ADR-0059): opaque pointer to
    /// host-managed state needed by runtime callout fn ptrs (e.g.
    /// allocator + back-reference to the canonical backing buffer
    /// the JitRuntime aliases). Each callout's fn ptr knows how
    /// to interpret this; mismatched casts are silent UB so
    /// `host_state` and the matching callout fn slot are paired
    /// at construction time.
    host_state: ?*anyopaque = null,
    /// (per ADR-0059): `memory.grow mem=0`
    /// callout. Args: `(rt: *JitRuntime, delta_pages: u32)` →
    /// previous page count on success (widened from u32 to i32),
    /// `-1` on failure. The fn MUST update `rt.vm_base` +
    /// `rt.mem_limit` in place when growth succeeds so the JIT
    /// body's post-call reload (arm64 reloads X28/X27 from these
    /// offsets) sees the new values. Calling convention is C-ABI
    /// (SysV on Linux/macOS x86_64, Win64 on Windows, AAPCS64 on
    /// arm64); callee-saved registers MUST be preserved.
    ///
    /// Defaults to `defaultMemoryGrowReject` (always returns -1,
    /// matches the pre-ADR-0059 skeleton's spec-conformant "host
    /// refuses growth" semantics) so JIT-emitted BLR/CALL through
    /// this slot is SEGV-safe out of the box. Runners that need
    /// actual growth override with their own impl.
    memory_grow_fn: *const fn (rt: *JitRuntime, delta_pages: u32) callconv(.c) i32 = defaultMemoryGrowReject,
    /// (D-112): per-table call_indirect
    /// dispatch info array. Indexed by `call_indirect`'s table_idx
    /// (carried in `ZirInstr.extra` per lower.zig:927). Entry 0
    /// duplicates the legacy table-0 fast path (`funcptr_base` /
    /// `typeidx_base` scalars above) — both views point at the
    /// same memory at construction time. Entries `k > 0` back the
    /// per-call slow path the JIT emits when `ins.extra != 0`.
    /// `undefined` is safe when no module declares > 1 table (the
    /// emit only LDRs through this when `ins.extra > 0`).
    tables_jit_ci_ptr: [*]const TableJitCallInfo = undefined,
    tables_jit_ci_count: u32 = 0,
    _pad11: u32 = 0,
    /// (D-122 / D-125): `table.grow tableidx`
    /// callout. Args: `(rt: *JitRuntime, tableidx: u32, init: u64,
    /// delta: u64)` → previous entry count on success (as i64),
    /// `-1` on failure (D-475: u64 delta / i64 result so an i64
    /// table's grow marshals at X/.q width; i32 tables stage the
    /// delta W-form — zero-extended — and capture the low 32 result
    /// bits, so the wider signature is transparent to them). The
    /// fn MUST update the per-table
    /// `tables_ptr[tableidx].len` (and `refs` if reallocated) in
    /// place when growth succeeds. Calling convention is C-ABI
    /// (SysV/AAPCS64); callee-saved registers MUST be preserved.
    ///
    /// Defaults to `defaultTableGrowReject` (always returns -1)
    /// so JIT-emitted BLR/CALL through this slot is SEGV-safe out
    /// of the box. Spec runners override with `growableTableGrowFn`.
    table_grow_fn: *const fn (rt: *JitRuntime, tableidx: u32, init: u64, delta: u64) callconv(.c) i64 = defaultTableGrowReject,
    /// ADR-0105 D1 — JIT-prologue stack-probe threshold. Set at
    /// entry-helper construction time via
    /// `platform.stack_limit.computeStackLimit(STACK_GUARD_HEADROOM)`;
    /// the JIT prologue emits `cmp sp, [vmctx +
    /// stack_limit_off] + b.ls trap-stub` so SP descending below
    /// this threshold traps cleanly via the existing trap-stub
    /// path BEFORE the OS guard page faults. Sentinel `0` =
    /// "probe disabled" (the comparison always passes, since SP
    /// > 0). Cross-platform per ADR-0105 D1 (macOS pthread_*np,
    /// Linux pthread_getattr_np, Win64 GetCurrentThreadStackLimits).
    stack_limit: usize = 0,
    /// JIT trap-stub entry counter (D-165, 2026-05-23).
    /// Incremented unconditionally as the first instruction in the
    /// x86_64 stack-overflow trap stub (op_control.zig:1334+).
    /// arm64 path unchanged (Mac runaway PASSes;
    /// arm64 diagnostic added when needed). Allows host-side
    /// observation of "did the probe fire and the trap stub run"
    /// for the Win64 fac-rec hang investigation — distinguishing
    /// "probe never fired" (count=0) from "probe fired but unwind
    /// stalled" (count>0 with trap_flag possibly 1).
    trap_stub_entry_count: u32 = 0,
    _pad12: u32 = 0,
    /// Per-Instance JIT exception table view (ADR-0114 D5 + ADR-0119)
    /// consumed by `shared/zwasm_throw.dispatchThrow` after the per-arch
    /// trampoline CALL. Written at instance init from
    /// `CompiledWasm.exception_table.entries`.
    /// Module-relative pc_start / pc_end (the
    /// unwinder subtracts `JitModule.block.bytes.ptr` from the
    /// throw-site absolute address before lookup).
    ///
    /// `null` (with `eh_table_count = 0`) signals "no try_table
    /// anywhere in this module" — the trampoline's .uncaught
    /// path fires immediately without walking the table.
    eh_table_entries: ?[*]const exception_table.HandlerEntry = null,
    /// HandlerEntry count for `eh_table_entries`. Paired with
    /// the ptr; both written together at instance init.
    eh_table_count: u32 = 0,
    _pad13: u32 = 0,
    /// Per-Instance JIT CodeMap view.
    /// Written at instance init from `JitModule.code_map_entries`.
    /// The trampoline reads via
    /// `code_map.CodeMap{ .entries = eh_code_map_entries[0..N] }`
    /// then passes to `dispatchThrow` for absolute-pc →
    /// `(func_idx, relative_pc)` translation.
    eh_code_map_entries: ?[*]const code_map.Entry = null,
    /// Entry count for `eh_code_map_entries`.
    eh_code_map_count: u32 = 0,
    /// Handler-dispatch result fields.
    /// Written by `trampolineCore` on `.handler` return; consumed by
    /// the naked stub's branch + JMP path.
    ///
    /// `eh_handler_active`:
    ///   0 = `.uncaught` path (naked stub RETs to throw site whose
    ///       fallthrough hits the trap stub).
    ///   1 = `.handler` path (naked stub restores SP from
    ///       `eh_handler_sp` and JMPs to `eh_handler_pc`).
    ///
    /// `eh_handler_sp` = absolute SP value at the catching frame's
    /// prologue boundary = `handler_fp - frame_bytes` (per AAPCS64
    /// §6.4 + the function's `SUB SP, SP, #frame_bytes` prologue).
    ///
    /// `eh_handler_pc` = absolute address of the landing-pad
    /// instruction = `code_map.Entry.start_addr + landing_pad_pc`
    /// (catching function's start + the catch label's module-relative
    /// offset).
    eh_handler_active: u32 = 0,
    eh_handler_sp: usize = 0,
    eh_handler_pc: usize = 0,
    /// FP (X29 / RBP) to install BEFORE the BR/JMP to the landing
    /// pad. The catching function's body uses FP to address its
    /// locals + spills; we restore it from the unwinder's matched
    /// frame. = `HandlerLanding.handler_fp` verbatim.
    eh_handler_fp: usize = 0,
    /// JIT payload staging region (ADR-0120). Written by throw.emit's
    /// pop+store sequence; read by try_table.emit's landing-pad
    /// load+push synthesis. Width 16×u64 matches
    /// ADR-0114 D1's `Exception.payload[16]Value` inline cap;
    /// v128 / exnref tag params remain v0.2 scope per ADR-0120
    /// Consequence §3. Layout-stable tail: added after the
    /// handler-dispatch trio so existing prologue offsets
    /// are unaffected.
    eh_payload_buf: [16]u64 = [_]u64{0} ** 16,
    /// EH payload length (N from `tag_param_counts[tag_idx]` at
    /// the most recent throw site). See `eh_payload_buf`.
    eh_payload_len: u32 = 0,
    _pad14: u32 = 0,
    /// GC-on-JIT (ADR-0128 §2) — opaque pointers to the
    /// per-Instance GC heap (`*feature/gc/heap.Heap`) and GC
    /// type-info table (`*const feature/gc/type_info.GcTypeInfos`).
    /// Set at instance setup iff the module declares a GC type
    /// section; null otherwise. The struct alloc trampoline
    /// (`jitGcAlloc` below) reads both to look up payload_size +
    /// allocate; struct.get/set read `gc_heap`'s
    /// slab base (`Heap.bytes.ptr`) via a second indirection.
    /// Layout-stable tail (added after the EH fields so existing
    /// prologue offsets are unaffected).
    gc_heap: ?*anyopaque = null,
    gc_type_infos_ptr: ?*anyopaque = null,
    /// Per-Instance tag-identity map (ADR-0134 D3; see
    /// `exception_table.ExceptionTable.tag_ids`). Indexed by local tag
    /// index; `tag_ids_ptr[i]` is a globally-comparable identity id so
    /// aliased imports share an id (Cause A) and a cross-module import
    /// inherits the source instance's id (Cause B). Covers the full
    /// tag index space when the module has ≥1 imported tag; `null`
    /// (count 0) = defined-tags-only → raw-index comparison.
    /// `trampolineCore` slices `tag_ids_ptr[0..tag_ids_count]` into the
    /// materialized `ExceptionTable`. Layout-stable tail.
    tag_ids_ptr: ?[*]const u64 = null,
    tag_ids_count: u32 = 0,
    _pad_tc: u32 = 0,
    /// D-244 (JIT-WASI): opaque `*wasi.host.Host` for real WASI I/O under the
    /// JIT (`--engine jit`). Null on the compute-only path (handlers fall back
    /// to their deterministic stubs). Set by the run path; read only by the
    /// C-ABI WASI thunks in `wasi/jit_dispatch.zig`, never by the JIT body, so
    /// this trailing field leaves every codegen `@offsetOf` unchanged.
    wasi_host: ?*anyopaque = null,
    /// Wasm threads/atomics (ADR-0168) — `tNN.atomic.rmw*` callout.
    /// Args `(rt, ea, operand, opcode)`; returns the OLD value
    /// zero-extended to u64. `opcode = (kind << 8) | width_bytes`
    /// (kind: add=0 sub=1 and=2 or=3 xor=4 xchg=5; width ∈ {1,2,4,8}).
    /// Operates directly on `rt.vm_base` / `rt.mem_limit` — no host
    /// state — so the default IS the production impl (no setup-time
    /// install needed, unlike memory.grow). On an unaligned ea or an
    /// out-of-bounds access it sets `trap_flag` + `trap_kind` and
    /// returns 0; the JIT epilogue raises the trap (the returned 0 is
    /// discarded). The Zig-side alignment check fires reliably on every
    /// arch — this is why rmw sidesteps the inline-emit D-299 gap.
    /// TRAILING field (like `wasi_host`): keeps every codegen `@offsetOf`
    /// unchanged; only consulted via `[R15+atomic_rmw_fn_off]`.
    atomic_rmw_fn: *const fn (rt: *JitRuntime, ea: u64, operand: u64, opcode: u32) callconv(.c) u64 = defaultAtomicRmw,
    /// Wasm threads/atomics (ADR-0168) — `tNN.atomic.rmw*.cmpxchg*`
    /// callout, indexed by width_log2 (0=1 B … 3=8 B). Args `(rt, ea,
    /// expected, replacement)`; returns OLD zero-extended. Per-width fn
    /// pointers (not an opcode arg) keep the callout at 4 args on every
    /// ABI. TRAILING field — keeps every codegen `@offsetOf` unchanged.
    atomic_cmpxchg_fns: [4]*const fn (rt: *JitRuntime, ea: u64, expected: u64, replacement: u64) callconv(.c) u64 = default_atomic_cmpxchg_fns,
    /// Wasm threads/atomics (ADR-0168) — `memory.atomic.notify` callout.
    /// Args `(rt, ea)`; returns waiters woken (always 0 single-thread).
    /// Sets trap_flag on unaligned/oob. TRAILING (keeps @offsetOf stable).
    atomic_notify_fn: *const fn (rt: *JitRuntime, ea: u64) callconv(.c) u32 = defaultAtomicNotify,
    /// Wasm threads/atomics (ADR-0168) — `memory.atomic.wait{32,64}`
    /// callout, indexed by width_log2-2 (0=wait32/4B, 1=wait64/8B). Args
    /// `(rt, ea, expected)`; returns 1 (≠) / 2 (timed-out). Sets
    /// trap_flag on unaligned/oob/non-shared. TRAILING.
    atomic_wait_fns: [2]*const fn (rt: *JitRuntime, ea: u64, expected: u64) callconv(.c) u32 = default_atomic_wait_fns,
    /// Wasm threads/atomics (ADR-0168) — memory0's shared flag (1=shared),
    /// surfaced from the MemoryInstance so the wait callout can trap on a
    /// non-shared memory (the JIT rt has no MemoryInstance). TRAILING.
    mem0_shared: u32 = 0,
    /// Wasm custom-page-sizes (ADR-0168 v0.2) — memory0's page_size_log2
    /// (0 = 1 byte, 16 = 64 KiB default). The JIT memory.size emit reads
    /// this as a variable shift (`mem_limit >> log2` = page count) and
    /// jitMemoryGrow uses `1 << log2` as the page size (the JIT rt has no
    /// MemoryInstance). TRAILING. memory.size is a rare op, so the field
    /// load + variable shift is negligible vs threading a compile-time
    /// constant through compileOne.
    mem0_page_size_log2: u32 = 16,
    /// Sandboxing (ADR-0179 #3a / D-314) — host cooperative-interruption flag.
    /// Points at the host's `std.atomic.Value(u32)` (== the interp Runtime's
    /// `interrupt_flag_storage` when shared); null = no interrupt configured.
    /// The JIT prologue/back-edge poll does `LDR Xptr ← interrupt_ptr; CBZ
    /// skip (null = disabled); LDR Wf ← [Xptr]; CMP Wf,0; B.NE interrupted-stub`.
    /// A plain load is a relaxed/monotonic read of the aligned u32 (matches the
    /// interp's `.monotonic`). TRAILING (extern-struct layout; no offset churn).
    interrupt_ptr: ?*const std.atomic.Value(u32) = null,
    /// Sandboxing (ADR-0179 #3b / D-314) — JIT fuel metering enable flag
    /// (0 = unmetered, the poll skips). NOT a pointer like `interrupt_ptr`:
    /// the budget cell lives in THIS struct and RuntimeOwned moves by value
    /// into JitInstance (D-215) — a self-referential pointer would dangle on
    /// the move. The poll, beside the interrupt poll at the prologue + every
    /// loop back-edge, does `load fuel_metered; zero-skip; SUB fuel_cell, 1;
    /// sign-negative → out-of-fuel stub (code 17)`. Fuel UNITS are poll-site
    /// crossings (v1 parity), NOT interp instructions — engines meter
    /// differently by design (ADR-0179 rev 2026-06-12). TRAILING.
    fuel_metered: u32 = 0,
    /// Explicit pad keeping `fuel_cell` 8-aligned in the extern layout.
    fuel_pad: u32 = 0,
    /// JIT fuel budget. Signed so the post-SUB sign check is one flag test:
    /// budget N permits N polls; the poll taking it to -1 traps. TRAILING.
    fuel_cell: i64 = 0,
    /// Wasm 3.0 EH exnref reification (ADR-0120 D6 / D-327). Callout the
    /// catch_ref / catch_all_ref landing pad BLRs to materialize an exnref
    /// (`*Exception`) from the live thrown tag + payload. Defaults to a
    /// panic stub — only reached when an `_ref` catch clause was compiled,
    /// which REQUIRES the runner to install the real `reifyExnref`. TRAILING.
    reify_exnref_fn: *const fn (rt: *JitRuntime) callconv(.c) usize = defaultReifyExnref,
    /// Opaque `*EhReifyCtx` (allocator + Exception tracker) consumed by
    /// `reifyExnref`. Null on the default/no-`_ref` path. TRAILING.
    eh_reify_ctx: ?*anyopaque = null,
    /// The tag index of the exception currently being dispatched. Stashed by
    /// `trampolineCore` on the `.handler` path (ADR-0134) so a catch_all_ref
    /// landing pad — whose clause carries no compile-time tag — can reify the
    /// exnref with the ACTUAL thrown tag. TRAILING.
    eh_thrown_tag_idx: u32 = 0,
    _pad_reify: u32 = 0,
    /// D-314(b) — host sandbox cap on total table elements, consulted by
    /// `jitTableGrow` so a guest cannot `table.grow` past the host ceiling
    /// (mirrors the interp `Runtime.store_table_elements_max`). `maxInt`
    /// sentinel = unlimited (extern-struct can't carry `?u64`; an optional
    /// integer needs a tag byte). TRAILING — appended so JIT-emitted code's
    /// `@offsetOf` field offsets are unchanged. Set by `runWasiLenient` from
    /// `RunLimits.max_table_elements`.
    store_table_elements_max: u64 = std.math.maxInt(u64),
    /// D-478 — base of the host-import payload array (parallel to
    /// `host_dispatch_base`, indexed by func-import idx). Each entry is
    /// `@intFromPtr(*api.HostFuncPayload)`. Only the Zig comptime host-bridge
    /// thunks (`src/api/jit_host_bridge.zig`) planted into `host_dispatch_base`
    /// read it — the JIT body never does, so this trailing field leaves every
    /// codegen `@offsetOf` unchanged. Null when the module has no host-func
    /// imports the bridge covers (WASI-only / no-import modules).
    host_payloads_base: ?[*]const usize = null,

    // ADR-0203 D1 (D-516) — position-independence: Zig-helper entry points
    // the JIT body calls, held as fn-pointer fields and reached via
    // `[rt + offset]` (the `memory_grow_fn` pattern) instead of imm64
    // addresses baked into emitted code. Baked addresses are the producing
    // process's and die under per-exec ASLR when a `.cwasm` is reloaded —
    // the field defaults below resolve in the RUNNING process (ordinary
    // binary relocation), so every JitRuntime is correct without setup
    // wiring and the emitted code bytes carry no absolute addresses.
    // TRAILING — appended so existing codegen `@offsetOf` values are
    // unchanged. All target functions take `rt` first and are
    // self-contained, so the real helpers ARE the defaults.
    call_indirect_resolve_fn: *const fn (rt: *JitRuntime, table_idx: u32, idx: u64, expected_typeidx: u32) callconv(.c) u64 = jitCallIndirectResolve,
    gc_alloc_fn: *const fn (rt: *JitRuntime, typeidx: u32) callconv(.c) u32 = jitGcAlloc,
    gc_alloc_array_fn: *const fn (rt: *JitRuntime, typeidx: u32, length: u32) callconv(.c) u32 = jitGcAllocArray,
    gc_alloc_array_fill_fn: *const fn (rt: *JitRuntime, typeidx: u32, length: u32, init: u64) callconv(.c) u32 = jitGcAllocArrayFill,
    gc_array_fill_fn: *const fn (rt: *JitRuntime, typeidx: u32, ref: u32, idx: u32, value: u64, count: u32) callconv(.c) u32 = jitGcArrayFill,
    gc_array_copy_fn: *const fn (rt: *JitRuntime, dst_ref: u32, dst_off: u32, src_ref: u32, src_off: u32, len: u32) callconv(.c) u32 = jitGcArrayCopy,
    gc_array_new_data_fn: *const fn (rt: *JitRuntime, typeidx: u32, segidx: u32, offset: u32, size: u32) callconv(.c) u32 = jitGcArrayNewData,
    gc_array_new_elem_fn: *const fn (rt: *JitRuntime, typeidx: u32, segidx: u32, offset: u32, size: u32) callconv(.c) u32 = jitGcArrayNewElem,
    gc_array_init_data_fn: *const fn (rt: *JitRuntime, segidx: u32, ref: u32, dst_off: u32, src_off: u32, len: u32) callconv(.c) u32 = jitGcArrayInitData,
    gc_array_init_elem_fn: *const fn (rt: *JitRuntime, segidx: u32, ref: u32, dst_off: u32, src_off: u32, len: u32) callconv(.c) u32 = jitGcArrayInitElem,
    gc_ref_test_fn: *const fn (rt: *JitRuntime, ref: u64, ht_nullbit: u32) callconv(.c) u32 = jitGcRefTest,
    gc_ref_cast_fn: *const fn (rt: *JitRuntime, ref: u64, ht: u32) callconv(.c) u64 = jitGcRefCast,
    rethrow_exnref_fn: *const fn (rt: *JitRuntime, exc_ptr: usize) callconv(.c) u32 = rethrowFromExnref,
    /// The `throw`/`throw_ref` unwind entry (`callconv(.naked)`; reads its
    /// arguments from the registers the op emit stages) — same D1 motive.
    throw_trampoline_fn: *const fn () callconv(.naked) noreturn = @import("throw_trampoline.zig").zwasmThrowTrampoline,
};

/// Host-side context for `reifyExnref` (ADR-0120 D6 / D-327). Owns the
/// allocator + a tracker of every Exception reified at an `_ref` catch
/// landing pad. The exnref handle is a raw `*Exception` the Wasm program
/// may hold across calls and re-throw (`throw_ref`), so the objects must
/// outlive the catching frame; the tracker frees them at instance
/// teardown (mirrors the interp's `Runtime.live_exceptions`). Installed
/// on `JitRuntime.eh_reify_ctx` by the runner (setup.zig) only when a
/// module compiles an `_ref` catch clause.
pub const EhReifyCtx = struct {
    allocator: std.mem.Allocator,
    exceptions: std.ArrayList(*exception_mod.Exception) = .empty,

    pub fn deinit(self: *EhReifyCtx) void {
        for (self.exceptions.items) |exc| self.allocator.destroy(exc);
        self.exceptions.deinit(self.allocator);
    }
};

/// Default `reify_exnref_fn`. Reached only if an `_ref`-suffixed catch
/// clause was compiled yet the runner failed to install the real impl —
/// a wiring bug, not a runtime condition. Panic loudly (ADR-0120 D6 +
/// platform_panic_vs_error rule: a comptime-unreachable branch panics
/// rather than silently returning a null exnref).
pub fn defaultReifyExnref(rt: *JitRuntime) callconv(.c) usize {
    _ = rt;
    @panic("reify_exnref_fn not installed but an _ref catch clause was compiled (D-327)");
}

/// ADR-0120 D6 — materialize an `exnref` at a catch_ref / catch_all_ref
/// landing pad. Snapshots the live `eh_thrown_tag_idx` + `eh_payload_buf
/// [0..eh_payload_len]` into a freshly-allocated `Exception` (the interp
/// representation, so JIT + interp exnref values are bit-identical) and
/// returns its address as the handle the landing pad pushes. The copy is
/// a SNAPSHOT, not an alias: the shared payload buffer is overwritten by
/// the next throw while a caught exnref may still be live. Each `u64`
/// payload slot round-trips through `Value{.bits64=…}` (lossless for the
/// v0.1 gpr param types). Returns `0` (null exnref) on allocation
/// failure; the landing-pad emit treats `0` as a trap (D-327).
pub fn reifyExnref(rt: *JitRuntime) callconv(.c) usize {
    const ctx: *EhReifyCtx = @ptrCast(@alignCast(rt.eh_reify_ctx orelse return 0));
    const exc = ctx.allocator.create(exception_mod.Exception) catch return 0;
    exc.* = .{
        .tag_idx = rt.eh_thrown_tag_idx,
        .tag = null,
        .payload_len = rt.eh_payload_len,
        .payload = undefined,
    };
    const n = @min(rt.eh_payload_len, exception_mod.max_payload);
    var i: u32 = 0;
    while (i < n) : (i += 1) exc.payload[i] = .{ .bits64 = rt.eh_payload_buf[i] };
    ctx.exceptions.append(ctx.allocator, exc) catch {
        ctx.allocator.destroy(exc);
        return 0;
    };
    return @intFromPtr(exc);
}

/// D-327 — `throw_ref` re-throw. Reads the held exnref's `*Exception`
/// (`exc_ptr`) back into the JIT payload-staging buffer + length, and
/// returns its `tag_idx` so the emitted `throw_ref` re-enters the throw
/// dispatcher exactly as a fresh `throw` of the same tag+payload (the
/// round-trip identity Wasm `throw_ref` requires). `exc_ptr == 0` is a
/// null exnref — spec says `throw_ref` then TRAPS; route to an uncaught
/// dispatch (len 0 + no-match sentinel) rather than deref null (the
/// precise null-trap kind is a follow-up, untested by the wg-3.0 corpus).
pub fn rethrowFromExnref(rt: *JitRuntime, exc_ptr: usize) callconv(.c) u32 {
    if (exc_ptr == 0) {
        rt.eh_payload_len = 0;
        return 0xFFFF_FFFF;
    }
    const exc: *exception_mod.Exception = @ptrFromInt(exc_ptr);
    const n = @min(exc.payload_len, exception_mod.max_payload);
    var i: u32 = 0;
    while (i < n) : (i += 1) rt.eh_payload_buf[i] = exc.payload[i].bits64;
    rt.eh_payload_len = exc.payload_len;
    return exc.tag_idx;
}

/// Default `memory_grow_fn` — unconditionally refuses growth by
/// returning the spec sentinel `-1`. Spec-conformant for any host
/// that opts to disallow runtime linear-memory growth (per Wasm
/// 1.0 §4.4.7.6). Matches the pre-ADR-0059 skeleton's behaviour
/// so existing test corpora that exercise `memory.grow` without
/// a growable runner observe identical outcomes.
pub fn defaultMemoryGrowReject(rt: *JitRuntime, delta_pages: u32) callconv(.c) i32 {
    _ = rt;
    _ = delta_pages;
    return -1;
}

/// Default `table_grow_fn` — unconditionally refuses growth by
/// returning the spec sentinel `-1`. Spec-conformant for any host
/// that opts to disallow runtime table growth (per Wasm 2.0
/// §4.4.10.1).
pub fn defaultTableGrowReject(rt: *JitRuntime, tableidx: u32, init: u64, delta: u64) callconv(.c) i64 {
    _ = rt;
    _ = tableidx;
    _ = init;
    _ = delta;
    return -1;
}

/// Production `atomic_rmw_fn` (ADR-0168). Reads `old` at `rt.vm_base +
/// ea`, applies the rmw op, writes back, returns `old` zero-extended.
/// Alignment trap BEFORE bounds (spec exec step 8 precedes 14a). Width
/// + kind decoded from `opcode`. Result-width (i32 vs i64) is the JIT's
/// concern at the capture site (it reads W0 vs X0); the old value is
/// ≤ `width` bytes and already zero-extended, so either capture width
/// is correct.
pub fn defaultAtomicRmw(rt: *JitRuntime, ea: u64, operand: u64, opcode: u32) callconv(.c) u64 {
    const width: u64 = opcode & 0xff;
    const kind: u32 = opcode >> 8;
    if (ea & (width - 1) != 0) {
        rt.trap_flag = 1;
        rt.trap_kind = 14; // unaligned_atomic
        return 0;
    }
    if (ea + width > rt.mem_limit) {
        rt.trap_flag = 1;
        rt.trap_kind = 6; // oob_memory
        return 0;
    }
    const ptr = rt.vm_base + ea;
    return switch (width) {
        1 => rmwAt(u8, ptr, operand, kind),
        2 => rmwAt(u16, ptr, operand, kind),
        4 => rmwAt(u32, ptr, operand, kind),
        8 => rmwAt(u64, ptr, operand, kind),
        else => unreachable,
    };
}

fn rmwAt(comptime W: type, ptr: [*]u8, operand: u64, kind: u32) u64 {
    const slot = ptr[0..@sizeOf(W)];
    const old = std.mem.readInt(W, slot, .little);
    const val: W = @truncate(operand);
    const new: W = switch (kind) {
        0 => old +% val,
        1 => old -% val,
        2 => old & val,
        3 => old | val,
        4 => old ^ val,
        5 => val,
        else => unreachable,
    };
    std.mem.writeInt(W, slot, new, .little);
    return @as(u64, old);
}

/// rmw opcode metadata: `code = (kind << 8) | width_bytes` (kind add=0
/// sub=1 and=2 or=3 xor=4 xchg=5; width ∈ {1,2,4,8}). `res64` selects
/// the i64 result-capture width at the emit site. The `code` encoding
/// MUST match `defaultAtomicRmw`'s decode above (single source of truth
/// for the rmw callout ABI). `null` = not an atomic rmw op.
pub const RmwMap = struct { code: u32, res64: bool };

pub fn rmwMapOf(op: zir.ZirOp) ?RmwMap {
    return switch (op) {
        .@"i32.atomic.rmw.add" => .{ .code = (0 << 8) | 4, .res64 = false },
        .@"i32.atomic.rmw.sub" => .{ .code = (1 << 8) | 4, .res64 = false },
        .@"i32.atomic.rmw.and" => .{ .code = (2 << 8) | 4, .res64 = false },
        .@"i32.atomic.rmw.or" => .{ .code = (3 << 8) | 4, .res64 = false },
        .@"i32.atomic.rmw.xor" => .{ .code = (4 << 8) | 4, .res64 = false },
        .@"i32.atomic.rmw.xchg" => .{ .code = (5 << 8) | 4, .res64 = false },
        .@"i64.atomic.rmw.add" => .{ .code = (0 << 8) | 8, .res64 = true },
        .@"i64.atomic.rmw.sub" => .{ .code = (1 << 8) | 8, .res64 = true },
        .@"i64.atomic.rmw.and" => .{ .code = (2 << 8) | 8, .res64 = true },
        .@"i64.atomic.rmw.or" => .{ .code = (3 << 8) | 8, .res64 = true },
        .@"i64.atomic.rmw.xor" => .{ .code = (4 << 8) | 8, .res64 = true },
        .@"i64.atomic.rmw.xchg" => .{ .code = (5 << 8) | 8, .res64 = true },
        .@"i32.atomic.rmw8.add_u" => .{ .code = (0 << 8) | 1, .res64 = false },
        .@"i32.atomic.rmw8.sub_u" => .{ .code = (1 << 8) | 1, .res64 = false },
        .@"i32.atomic.rmw8.and_u" => .{ .code = (2 << 8) | 1, .res64 = false },
        .@"i32.atomic.rmw8.or_u" => .{ .code = (3 << 8) | 1, .res64 = false },
        .@"i32.atomic.rmw8.xor_u" => .{ .code = (4 << 8) | 1, .res64 = false },
        .@"i32.atomic.rmw8.xchg_u" => .{ .code = (5 << 8) | 1, .res64 = false },
        .@"i32.atomic.rmw16.add_u" => .{ .code = (0 << 8) | 2, .res64 = false },
        .@"i32.atomic.rmw16.sub_u" => .{ .code = (1 << 8) | 2, .res64 = false },
        .@"i32.atomic.rmw16.and_u" => .{ .code = (2 << 8) | 2, .res64 = false },
        .@"i32.atomic.rmw16.or_u" => .{ .code = (3 << 8) | 2, .res64 = false },
        .@"i32.atomic.rmw16.xor_u" => .{ .code = (4 << 8) | 2, .res64 = false },
        .@"i32.atomic.rmw16.xchg_u" => .{ .code = (5 << 8) | 2, .res64 = false },
        .@"i64.atomic.rmw8.add_u" => .{ .code = (0 << 8) | 1, .res64 = true },
        .@"i64.atomic.rmw8.sub_u" => .{ .code = (1 << 8) | 1, .res64 = true },
        .@"i64.atomic.rmw8.and_u" => .{ .code = (2 << 8) | 1, .res64 = true },
        .@"i64.atomic.rmw8.or_u" => .{ .code = (3 << 8) | 1, .res64 = true },
        .@"i64.atomic.rmw8.xor_u" => .{ .code = (4 << 8) | 1, .res64 = true },
        .@"i64.atomic.rmw8.xchg_u" => .{ .code = (5 << 8) | 1, .res64 = true },
        .@"i64.atomic.rmw16.add_u" => .{ .code = (0 << 8) | 2, .res64 = true },
        .@"i64.atomic.rmw16.sub_u" => .{ .code = (1 << 8) | 2, .res64 = true },
        .@"i64.atomic.rmw16.and_u" => .{ .code = (2 << 8) | 2, .res64 = true },
        .@"i64.atomic.rmw16.or_u" => .{ .code = (3 << 8) | 2, .res64 = true },
        .@"i64.atomic.rmw16.xor_u" => .{ .code = (4 << 8) | 2, .res64 = true },
        .@"i64.atomic.rmw16.xchg_u" => .{ .code = (5 << 8) | 2, .res64 = true },
        .@"i64.atomic.rmw32.add_u" => .{ .code = (0 << 8) | 4, .res64 = true },
        .@"i64.atomic.rmw32.sub_u" => .{ .code = (1 << 8) | 4, .res64 = true },
        .@"i64.atomic.rmw32.and_u" => .{ .code = (2 << 8) | 4, .res64 = true },
        .@"i64.atomic.rmw32.or_u" => .{ .code = (3 << 8) | 4, .res64 = true },
        .@"i64.atomic.rmw32.xor_u" => .{ .code = (4 << 8) | 4, .res64 = true },
        .@"i64.atomic.rmw32.xchg_u" => .{ .code = (5 << 8) | 4, .res64 = true },
        else => null,
    };
}

/// True for any `tNN.atomic.rmw*` op (the callout family). Used by the
/// regalloc call-clobber + uses-runtime-ptr classifiers.
pub fn isAtomicRmw(op: zir.ZirOp) bool {
    return rmwMapOf(op) != null;
}

/// Production `atomic_cmpxchg_fns[width_log2]` (ADR-0168). Per-width
/// (comptime `W`) compare-exchange: load `old` at `rt.vm_base + ea`,
/// store `replacement` iff `old == wrap_W(expected)`, ALWAYS return
/// `old` zero-extended (spec exec). Alignment trap BEFORE bounds.
/// cmpxchg has no kind (one operation) → per-width fn pointers keep the
/// callout at a clean 4 args (rt, ea, expected, replacement) on every
/// ABI — no 5th stack arg on Win64, no width packed into `ea` (which
/// would be a single-slot-dual-meaning violation + a memory64 hazard).
fn cmpxchgFn(comptime W: type) *const fn (rt: *JitRuntime, ea: u64, expected: u64, replacement: u64) callconv(.c) u64 {
    return &struct {
        fn f(rt: *JitRuntime, ea: u64, expected: u64, replacement: u64) callconv(.c) u64 {
            const width = @sizeOf(W);
            if (ea & (width - 1) != 0) {
                rt.trap_flag = 1;
                rt.trap_kind = 14; // unaligned_atomic
                return 0;
            }
            if (ea + width > rt.mem_limit) {
                rt.trap_flag = 1;
                rt.trap_kind = 6; // oob_memory
                return 0;
            }
            const slot = (rt.vm_base + ea)[0..@sizeOf(W)];
            const old = std.mem.readInt(W, slot, .little);
            if (old == @as(W, @truncate(expected))) {
                std.mem.writeInt(W, slot, @as(W, @truncate(replacement)), .little);
            }
            return @as(u64, old);
        }
    }.f;
}

/// Default `atomic_cmpxchg_fns` array — indexed by width_log2
/// (0=1 B, 1=2 B, 2=4 B, 3=8 B). Production impls (no host state).
pub const default_atomic_cmpxchg_fns = [4]*const fn (rt: *JitRuntime, ea: u64, expected: u64, replacement: u64) callconv(.c) u64{
    cmpxchgFn(u8),
    cmpxchgFn(u16),
    cmpxchgFn(u32),
    cmpxchgFn(u64),
};

/// cmpxchg op metadata: `wlog2` indexes `atomic_cmpxchg_fns`; `res64`
/// selects the i64 result-capture width at the emit site. `null` = not
/// an atomic cmpxchg op.
pub const CmpxchgMap = struct { wlog2: u2, res64: bool };

pub fn cmpxchgMapOf(op: zir.ZirOp) ?CmpxchgMap {
    return switch (op) {
        .@"i32.atomic.rmw.cmpxchg" => .{ .wlog2 = 2, .res64 = false },
        .@"i64.atomic.rmw.cmpxchg" => .{ .wlog2 = 3, .res64 = true },
        .@"i32.atomic.rmw8.cmpxchg_u" => .{ .wlog2 = 0, .res64 = false },
        .@"i32.atomic.rmw16.cmpxchg_u" => .{ .wlog2 = 1, .res64 = false },
        .@"i64.atomic.rmw8.cmpxchg_u" => .{ .wlog2 = 0, .res64 = true },
        .@"i64.atomic.rmw16.cmpxchg_u" => .{ .wlog2 = 1, .res64 = true },
        .@"i64.atomic.rmw32.cmpxchg_u" => .{ .wlog2 = 2, .res64 = true },
        else => null,
    };
}

pub fn isAtomicCmpxchg(op: zir.ZirOp) bool {
    return cmpxchgMapOf(op) != null;
}

/// Production `atomic_notify_fn` (ADR-0168). Align(4)+bounds trap, then
/// return 0 (the single-threaded substrate never has waiters). Valid on
/// a non-shared memory. Args: count was already dropped by the emit.
pub fn defaultAtomicNotify(rt: *JitRuntime, ea: u64) callconv(.c) u32 {
    if (ea & 3 != 0) {
        rt.trap_flag = 1;
        rt.trap_kind = 14; // unaligned_atomic
        return 0;
    }
    if (ea + 4 > rt.mem_limit) {
        rt.trap_flag = 1;
        rt.trap_kind = 6; // oob_memory
        return 0;
    }
    return 0;
}

/// Production `atomic_wait_fns[k]` (ADR-0168), per-width `W`. Align+
/// bounds trap, then trap if memory0 is non-shared, else compare the
/// in-memory value to `expected`: ≠ → 1 ("not equal"); == → 2 ("timed
/// out" — single-thread can't block, no notifier can ever arrive).
fn waitFn(comptime W: type) *const fn (rt: *JitRuntime, ea: u64, expected: u64) callconv(.c) u32 {
    return &struct {
        fn f(rt: *JitRuntime, ea: u64, expected: u64) callconv(.c) u32 {
            const width = @sizeOf(W);
            if (ea & (width - 1) != 0) {
                rt.trap_flag = 1;
                rt.trap_kind = 14; // unaligned_atomic
                return 0;
            }
            if (ea + width > rt.mem_limit) {
                rt.trap_flag = 1;
                rt.trap_kind = 6; // oob_memory
                return 0;
            }
            if (rt.mem0_shared == 0) {
                rt.trap_flag = 1;
                rt.trap_kind = 15; // expected_shared_memory
                return 0;
            }
            const cur = std.mem.readInt(W, (rt.vm_base + ea)[0..@sizeOf(W)], .little);
            return if (cur != @as(W, @truncate(expected))) 1 else 2;
        }
    }.f;
}

/// Default `atomic_wait_fns` — [0]=wait32 (4B), [1]=wait64 (8B).
pub const default_atomic_wait_fns = [2]*const fn (rt: *JitRuntime, ea: u64, expected: u64) callconv(.c) u32{
    waitFn(u32),
    waitFn(u64),
};

pub fn isAtomicNotify(op: zir.ZirOp) bool {
    return op == .@"memory.atomic.notify";
}

pub fn isAtomicWait(op: zir.ZirOp) bool {
    return op == .@"memory.atomic.wait32" or op == .@"memory.atomic.wait64";
}

/// `atomic_wait_fns` index for a wait op: wait32 → 0, wait64 → 1.
pub fn waitIdxOf(op: zir.ZirOp) u32 {
    return if (op == .@"memory.atomic.wait64") 1 else 0;
}

/// GC-on-JIT struct allocation trampoline (ADR-0128 §2). The
/// per-arch `struct.new` / `struct.new_default` emit materialises
/// this fn's address + `CALL`s it (rt in X0/RDI, typeidx in W1/ESI).
/// Resolves the `StructInfo` from `rt.gc_type_infos_ptr` (so the
/// JIT body needn't know payload_size at emit time), allocates +
/// stamps + zero-inits via the shared `object_alloc.allocStructObject`
/// (the SAME logic the interp `struct_ops.zig` uses), and returns the
/// `GcRef` (u32 slab offset). Returns `0` (null sentinel) on bad
/// typeidx / unmaterialised GC substrate / OOM — the JIT caller maps
/// `0` to a trap. C-ABI; callee-saved regs preserved by the callee.
pub fn jitGcAlloc(rt: *JitRuntime, typeidx: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcAlloc in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (typeidx >= gti.struct_infos.len) return 0;
    const si = gti.struct_infos[typeidx] orelse return 0;
    // D-258 / ADR-0160 — heap-pressure collect (conservative native-stack
    // scan) BEFORE the bump, mirroring the interp `struct_ops` guard.
    root_scope.maybeCollectJit(heap, gti);
    return object_alloc.allocStructObject(heap, typeidx, si.payload_size, true) catch 0;
}

/// GC-on-JIT: the `array.new_default` (and later
/// `array.new` / `array.new_fixed`) emit materialises this fn's address
/// + `CALL`s it (rt in X0/RDI, typeidx in W1/ESI, length in W2/EDX).
/// Resolves the `ArrayInfo` from `rt.gc_type_infos_ptr`, allocates +
/// stamps the `ArrayHeader` (`.array` kind + typeidx + length) + zero-
/// inits the payload via the shared `object_alloc.allocArrayObject` (the
/// SAME logic the interp `array_ops.zig` uses), and returns the `GcRef`.
/// Unlike `jitGcAlloc` (struct, compile-time size), the array total size
/// depends on the runtime `length` operand → the dedicated 3-arg
/// trampoline. Returns `0` (null sentinel) on bad typeidx / unmaterialised
/// GC substrate / OOM — the JIT caller maps `0` to a trap.
pub fn jitGcAllocArray(rt: *JitRuntime, typeidx: u32, length: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcAllocArray in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (typeidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[typeidx] orelse return 0;
    // D-258 / ADR-0160 — heap-pressure collect (conservative native-stack
    // scan) BEFORE the bump, mirroring the interp `array_ops` guard.
    root_scope.maybeCollectJit(heap, gti);
    return object_alloc.allocArrayObject(heap, typeidx, length, ai.element.size, true) catch 0;
}

/// GC-on-JIT: the `array.new` emit materialises this fn's
/// address + `CALL`s it (rt=arg0, typeidx=arg1, length=arg2, init=arg3).
/// Allocates the array, then fills every element with the `init` value
/// (the 8-byte operand, passed as a u64) — the SAME fill the interp
/// `array_ops.zig` arrayNew does. Doing the fill HERE (vs an emitted
/// machine-code loop) keeps the per-arch emit a plain marshal+CALL, since
/// the element count is a runtime value. Returns the `GcRef`, or `0` on
/// bad typeidx / unmaterialised substrate / OOM. NOTE: `init` is the raw
/// 8 bytes of the value; FP element types (f32/f64) would need the emit
/// to marshal from an FP reg — currently GPR-only (see debt; matches the
/// struct.new field-store simplification).
pub fn jitGcAllocArrayFill(rt: *JitRuntime, typeidx: u32, length: u32, init: u64) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcAllocArrayFill in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (typeidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[typeidx] orelse return 0;
    const esz: u32 = ai.element.size;
    // D-495: init value arrives as a u64 (8 bytes); a v128 element (esz=16) can't
    // be reconstructed → trap cleanly (return 0) rather than panic on the OOB
    // slice. Proper fix = pointer-marshal the 16-byte value.
    if (esz > 8) return 0;
    const ref = object_alloc.allocArrayObject(heap, typeidx, length, ai.element.size, false) catch return 0;
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    const init_bytes = std.mem.asBytes(&init);
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const off = ref + ahsz + i * esz;
        @memcpy(heap.bytes[off .. off + esz], init_bytes[0..esz]);
    }
    return ref;
}

/// GC-on-JIT: the `array.fill` emit materialises this fn's
/// address + `CALL`s it (rt=arg0, typeidx=arg1, ref=arg2, idx=arg3,
/// value=arg4, count=arg5). Operates on an EXISTING array (no alloc):
/// null-checks `ref`, bounds-checks `idx + count ≤ length` (overflow-
/// safe via `@addWithOverflow` — a negative i32 idx/count arrives as a
/// large u32 and is rejected here, mirroring the interp's signed check),
/// then fills `count` element slots from `idx` with `value` — the SAME
/// fill the interp `array_ops.zig` arrayFill does. Returns `1` on
/// success, `0` on trap (null ref / OOB); the JIT caller maps `0` to a
/// trap (`CMP result,#0; B.EQ → bounds-fixup stub`). `value` is the raw
/// 8 bytes (GPR-only; FP element types deferred, matching
/// jitGcAllocArrayFill).
/// Distinct return from `jitGcArrayFill`/`jitGcArrayCopy` signalling a NULL
/// array ref (vs `0` = OOB / internal). The array.copy/fill callers route it
/// to null_reference (code 10) and `0` to oob_memory (code 6), so a null array
/// matches array.get/set + interp (D-293 array_oob). `1` = success; funcref/
/// GcRef collisions are impossible (these trampolines return only 0/1/2).
pub const ARRAY_NULL_SENTINEL: u32 = 2;

pub fn jitGcArrayFill(rt: *JitRuntime, typeidx: u32, ref: u32, idx: u32, value: u64, count: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcArrayFill in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (typeidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[typeidx] orelse return 0;
    if (ref == 0) return ARRAY_NULL_SENTINEL; // null-ref → distinct sentinel (D-293 array_oob)
    const len_off: u32 = @offsetOf(gc_type_info.ArrayHeader, "length");
    const length = std.mem.readInt(u32, heap.bytes[ref + len_off ..][0..4], .little);
    const end = @addWithOverflow(idx, count);
    if (end[1] != 0 or end[0] > length) return 0; // OOB trap
    const esz: u32 = ai.element.size;
    // D-495: the fill value arrives as a u64 (8 bytes); a v128 element (esz=16)
    // can't be reconstructed → trap cleanly rather than panic on the OOB slice
    // (guest-triggerable host panic otherwise). Proper fix = pointer-marshal the
    // 16-byte value. esz is 8 for all scalar/ref elements, 16 only for v128.
    if (esz > 8) return 0;
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    const value_bytes = std.mem.asBytes(&value);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const off = ref + ahsz + (idx + i) * esz;
        @memcpy(heap.bytes[off .. off + esz], value_bytes[0..esz]);
    }
    return 1;
}

/// GC-on-JIT: the `array.copy` emit materialises this fn's
/// address + `CALL`s it (rt=arg0, dst_ref=arg1, dst_off=arg2, src_ref=arg3,
/// src_off=arg4, len=arg5). Null-checks both refs, bounds-checks
/// `dst_off + len ≤ dst.length` AND `src_off + len ≤ src.length`
/// (overflow-safe; negative-as-u32 rejected), then copies `len` element
/// slots src→dst with memmove-overlap semantics (backward copy when the
/// same array + dst_off > src_off) — the SAME copy the interp arrayCopy
/// does. Returns `1` on success, `0` on trap (null ref / OOB); the JIT
/// caller maps `0` to a trap. The element slot size is read at runtime from
/// the array's type info (D-460 @5292569e0): `ai.element.size` = 8 for
/// scalar/ref, 16 for v128 — recovered via the dst object's `info` typeidx
/// into `rt.gc_type_infos_ptr` (the trampoline therefore needs `gc_heap` AND
/// `gc_type_infos_ptr`, no per-call typeidx immediate).
pub fn jitGcArrayCopy(rt: *JitRuntime, dst_ref: u32, dst_off: u32, src_ref: u32, src_off: u32, len: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcArrayCopy in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    if (dst_ref == 0 or src_ref == 0) return ARRAY_NULL_SENTINEL; // null-ref → distinct sentinel (D-293 array_oob)
    const len_off: u32 = @offsetOf(gc_type_info.ArrayHeader, "length");
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    const dst_len = std.mem.readInt(u32, heap.bytes[dst_ref + len_off ..][0..4], .little);
    const src_len = std.mem.readInt(u32, heap.bytes[src_ref + len_off ..][0..4], .little);
    const de = @addWithOverflow(dst_off, len);
    if (de[1] != 0 or de[0] > dst_len) return 0; // dst OOB
    const se = @addWithOverflow(src_off, len);
    if (se[1] != 0 or se[0] > src_len) return 0; // src OOB
    // D-460: element slot size from the array's type info (v128 = 16, not the
    // 8-byte scalar/ref slot). The ObjectHeader's `info` field carries the
    // TypeInfo index (low 31 bits; bit 31 is the GC mark bit). array.copy
    // validates dst/src share an element type, so dst's slot size governs both.
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    const info_off: u32 = @offsetOf(gc_type_info.ObjectHeader, "info");
    const dst_tyidx = std.mem.readInt(u32, heap.bytes[dst_ref + info_off ..][0..4], .little) & ~mark_sweep.mark_bit_mask;
    if (dst_tyidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[dst_tyidx] orelse return 0;
    const esz: u32 = ai.element.size; // 8 scalar/ref, 16 v128 (ADR-0116 §3a)
    const overlap_backward = (dst_ref == src_ref and dst_off > src_off);
    var k: u32 = 0;
    while (k < len) : (k += 1) {
        const i = if (overlap_backward) len - 1 - k else k;
        const s = src_ref + ahsz + (src_off + i) * esz;
        const d = dst_ref + ahsz + (dst_off + i) * esz;
        // copyForwards (not @memcpy): a self-region copy with dst_off ==
        // src_off makes these slices identical, which @memcpy rejects as
        // aliasing. Mirrors the interp fix in array_ops.zig arrayCopy.
        std.mem.copyForwards(u8, heap.bytes[d .. d + esz], heap.bytes[s .. s + esz]);
    }
    return 1;
}

/// GC-on-JIT: the `array.new_data` emit materialises this
/// fn's address + `CALL`s it (rt=arg0, typeidx=arg1, segidx=arg2,
/// offset=arg3, size=arg4). Allocates a `size`-element array of $typeidx
/// and copies its payload from data segment $segidx at byte `offset`,
/// reading the element's NATURAL size (i8=1 / i16=2 / i32,f32=4 /
/// i64,f64=8) little-endian zero-extended into the uniform 8-byte slot —
/// the SAME copy the interp arrayNewData does. Reuses the same
/// `data_segments_ptr` / `data_dropped_ptr` descriptors that
/// `memory.init` uses (ADR-0056 m-3b), so no new JitRuntime plumbing.
/// Returns the `GcRef` (≥ 2), or `0` on trap (negative/OOB operand,
/// segidx OOB, segment OOB, dropped segment, unmaterialised GC
/// substrate / non-numeric element). The JIT caller maps `0` to a trap.
pub fn jitGcArrayNewData(rt: *JitRuntime, typeidx: u32, segidx: u32, offset: u32, size: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcArrayNewData in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (typeidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[typeidx] orelse return 0;
    // Element natural (packed) size in the data segment (inline of the
    // interp's dataElemNaturalSize; null/reftype → trap).
    const nat: u64 = switch (ai.element.valtype_byte) {
        0x78 => 1, // i8
        0x77 => 2, // i16
        0x7F, 0x7D => 4, // i32, f32
        0x7E, 0x7C => 8, // i64, f64
        0x7B => 16, // v128 (D-493)
        else => return 0,
    };
    if (segidx >= rt.data_segments_count) return 0;
    const dropped = segidx < rt.data_dropped_count and rt.data_dropped_ptr[segidx] != 0;
    const seg = rt.data_segments_ptr[segidx];
    const seg_len: u64 = if (dropped) 0 else seg.len;
    const off64: u64 = offset; // negative i32 arrives as a large u32 → OOB below
    const byte_len: u64 = @as(u64, size) * nat;
    if (off64 + byte_len > seg_len) return 0; // OOB (also catches negatives)
    const esz: u8 = ai.element.size; // slot size (8 scalars / 16 v128)
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    const ref = object_alloc.allocArrayObject(heap, typeidx, size, esz, false) catch return 0;
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        // D-493: zero slot + copy `nat` natural bytes — handles v128 (nat=16);
        // the prior u64-pack overflowed its shift at nat=16.
        const src: u64 = off64 + @as(u64, i) * nat;
        const dst_off = ref + ahsz + i * @as(u32, esz);
        const slot = heap.bytes[dst_off .. dst_off + esz];
        @memset(slot, 0);
        @memcpy(slot[0..@intCast(nat)], seg.ptr[@intCast(src)..@intCast(src + nat)]);
    }
    return ref;
}

/// GC-on-JIT: the `array.new_elem` emit materialises this
/// fn's address + `CALL`s it (rt=arg0, typeidx=arg1, segidx=arg2,
/// offset=arg3, size=arg4). Trivial variant of `jitGcArrayNewData`:
/// allocates a `size`-element array of $typeidx and copies `size` ref
/// Values DIRECT (no LE-unpack — each entry is already a u64 `Value.ref`)
/// from element segment $segidx starting at `offset` — the SAME copy the
/// interp arrayNewElem does. Reuses the `elem_segments_ptr` /
/// `elem_dropped_ptr` descriptors that `table.init` uses (ADR-0058
/// m-2c-init), so no new JitRuntime plumbing. Returns the `GcRef` (≥ 2),
/// or `0` on trap (negative/OOB operand, segidx OOB, segment OOB, dropped
/// segment, unmaterialised GC substrate). The JIT caller maps `0` to a trap.
pub fn jitGcArrayNewElem(rt: *JitRuntime, typeidx: u32, segidx: u32, offset: u32, size: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcArrayNewElem in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (typeidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[typeidx] orelse return 0;
    if (segidx >= rt.elem_segments_count) return 0;
    const dropped = segidx < rt.elem_dropped_count and rt.elem_dropped_ptr[segidx] != 0;
    const seg = rt.elem_segments_ptr[segidx];
    const seg_len: u64 = if (dropped) 0 else seg.len;
    const off64: u64 = offset; // negative i32 arrives as a large u32 → OOB below
    if (off64 + @as(u64, size) > seg_len) return 0; // OOB (also catches negatives)
    const esz: u8 = ai.element.size; // uniform 8-byte slot (reftype = 8)
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    const ref = object_alloc.allocArrayObject(heap, typeidx, size, esz, false) catch return 0;
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        const v: u64 = seg.refs[@intCast(off64 + @as(u64, i))];
        const dst_off = ref + ahsz + i * @as(u32, esz);
        @memcpy(heap.bytes[dst_off .. dst_off + 8], std.mem.asBytes(&v)[0..8]);
    }
    return ref;
}

/// GC-on-JIT: the `array.init_data` emit materialises this
/// fn's address + `CALL`s it (rt=arg0, segidx=arg1, ref=arg2, dst_off=arg3,
/// src_off=arg4, len=arg5). In-place init of an EXISTING array (no alloc):
/// null-checks `ref`, bounds-checks `dst_off + len ≤ length` (overflow-safe;
/// negative-as-u32 rejected), checks `src_off + len*nat ≤ segment length`,
/// then copies `len` natural-width elements from data segment $segidx (LE
/// zero-extended into the uniform 8-byte slot, mirror array.new_data) into
/// the array at `dst_off` — the SAME copy the interp arrayInitData does. The
/// typeidx immediate is NOT passed (it won't fit the 6-arg SysV register
/// budget alongside the 4 popped operands + segidx); it is read back from the
/// array's `ObjectHeader.info` (mark bit masked) to derive the element's
/// natural width. Reuses the same `data_segments_ptr` / `data_dropped_ptr`
/// descriptors `array.new_data` uses. Returns `1` on success, `0` on trap
/// (null ref / OOB / segidx OOB / dropped segment / non-numeric element). The
/// JIT caller maps `0` to a trap.
pub fn jitGcArrayInitData(rt: *JitRuntime, segidx: u32, ref: u32, dst_off: u32, src_off: u32, len: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcArrayInitData in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const gti_opaque = rt.gc_type_infos_ptr orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    const gti: *const gc_type_info.GcTypeInfos = @ptrCast(@alignCast(gti_opaque));
    if (ref == 0) return 0; // null-ref trap
    const info_off: u32 = @offsetOf(gc_type_info.ArrayHeader, "header") + @offsetOf(gc_type_info.ObjectHeader, "info");
    const raw_info = std.mem.readInt(u32, heap.bytes[ref + info_off ..][0..4], .little);
    const typeidx = raw_info & ~mark_sweep.mark_bit_mask;
    if (typeidx >= gti.array_infos.len) return 0;
    const ai = gti.array_infos[typeidx] orelse return 0;
    // Element natural (packed) size in the data segment (inline of the interp's
    // dataElemNaturalSize; null/reftype → trap).
    const nat: u64 = switch (ai.element.valtype_byte) {
        0x78 => 1, // i8
        0x77 => 2, // i16
        0x7F, 0x7D => 4, // i32, f32
        0x7E, 0x7C => 8, // i64, f64
        0x7B => 16, // v128 (D-493)
        else => return 0,
    };
    const len_off: u32 = @offsetOf(gc_type_info.ArrayHeader, "length");
    const length = std.mem.readInt(u32, heap.bytes[ref + len_off ..][0..4], .little);
    const de = @addWithOverflow(dst_off, len);
    if (de[1] != 0 or de[0] > length) return 0; // dst OOB
    if (segidx >= rt.data_segments_count) return 0;
    const dropped = segidx < rt.data_dropped_count and rt.data_dropped_ptr[segidx] != 0;
    const seg = rt.data_segments_ptr[segidx];
    const seg_len: u64 = if (dropped) 0 else seg.len;
    const so64: u64 = src_off; // negative i32 arrives as a large u32 → src OOB below
    if (so64 + @as(u64, len) * nat > seg_len) return 0; // src OOB (also catches negatives)
    const esz: u8 = ai.element.size; // slot size (8 scalars / 16 v128)
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        // D-493: zero slot + copy `nat` bytes — handles v128 (nat=16).
        const s: u64 = so64 + @as(u64, i) * nat;
        const dst = ref + ahsz + (dst_off + i) * @as(u32, esz);
        const slot = heap.bytes[dst .. dst + esz];
        @memset(slot, 0);
        @memcpy(slot[0..@intCast(nat)], seg.ptr[@intCast(s)..@intCast(s + nat)]);
    }
    return 1;
}

/// GC-on-JIT: the `array.init_elem` emit materialises this
/// fn's address + `CALL`s it (rt=arg0, segidx=arg1, ref=arg2, dst_off=arg3,
/// src_off=arg4, len=arg5). Trivial variant of `jitGcArrayInitData`: in-place
/// init of an EXISTING array, copying `len` ref Values DIRECT (no LE-unpack —
/// each entry is already a u64 `Value.ref`; esz=8 uniform per ADR-0116 §3a)
/// from element segment $segidx into the array at `dst_off` — the SAME copy
/// the interp arrayInitElem does. The typeidx immediate is NOT needed (uniform
/// 8-byte slot, no element-width derivation), so the header is not read.
/// Reuses the `elem_segments_ptr` / `elem_dropped_ptr` descriptors
/// `array.new_elem` uses. Returns `1` on success, `0` on trap (null ref / OOB
/// / segidx OOB / dropped segment). The JIT caller maps `0` to a trap.
pub fn jitGcArrayInitElem(rt: *JitRuntime, segidx: u32, ref: u32, dst_off: u32, src_off: u32, len: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcArrayInitElem in a sub-v3 build (unreachable — validator rejects GC ops)");
    const heap_opaque = rt.gc_heap orelse return 0;
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(heap_opaque));
    if (ref == 0) return 0; // null-ref trap
    const len_off: u32 = @offsetOf(gc_type_info.ArrayHeader, "length");
    const length = std.mem.readInt(u32, heap.bytes[ref + len_off ..][0..4], .little);
    const de = @addWithOverflow(dst_off, len);
    if (de[1] != 0 or de[0] > length) return 0; // dst OOB
    if (segidx >= rt.elem_segments_count) return 0;
    const dropped = segidx < rt.elem_dropped_count and rt.elem_dropped_ptr[segidx] != 0;
    const seg = rt.elem_segments_ptr[segidx];
    const seg_len: u64 = if (dropped) 0 else seg.len;
    const so64: u64 = src_off; // negative i32 arrives as a large u32 → src OOB below
    if (so64 + @as(u64, len) > seg_len) return 0; // src OOB (also catches negatives)
    const esz: u32 = 8; // uniform element slot (ADR-0116 §3a)
    const ahsz: u32 = @sizeOf(gc_type_info.ArrayHeader);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const v: u64 = seg.refs[@intCast(so64 + @as(u64, i))];
        const dst = ref + ahsz + (dst_off + i) * esz;
        @memcpy(heap.bytes[dst .. dst + 8], std.mem.asBytes(&v)[0..8]);
    }
    return 1;
}

/// GC-on-JIT: the `ref.test` / `ref.test_null` emit materialises this
/// fn's address + `CALL`s it (rt=arg0, ref=arg1 [the full 64-bit reftype
/// value], ht_nullbit=arg2). Returns 1 if the ref is a non-null instance of
/// heap-type `ht_nullbit` (with the null flag masked off; Wasm 3.0 GC
/// §3.3.5.3), else 0. Null is folded in: a null ref returns
/// `(ht_nullbit >> 30) & 1` — 0 for `ref.test` (null flag clear), 1 for
/// `ref.test_null` (null flag = 0x4000_0000) — so emit stays straight-line
/// (no inline null branch). The non-null match reuses the SAME
/// `gcRefMatchesNonNullCore` the interp uses (gti + heap read off JitRuntime).
pub fn jitGcRefTest(rt: *JitRuntime, ref: u64, ht_nullbit: u32) callconv(.c) u32 {
    if (comptime !wasm_v3_plus) @panic("jitGcRefTest in a sub-v3 build (unreachable — validator rejects GC ops)");
    if (ref == Value.null_ref) return (ht_nullbit >> 30) & 1;
    // D-453 trampoline ABI bit layout: concrete-tag = bit 31, null-flag =
    // bit 30, concrete idx = bits 0..29 (a bare wire byte otherwise). The
    // null flag sits just below the concrete-tag and above any in-range
    // typeidx, so it can never collide with the index (the old bit-8 flag
    // collided with idx ≥ 256). Mask out the null flag before the core.
    const ht: u32 = ht_nullbit & ~@as(u32, 0x4000_0000);
    const gti: ?*const gc_type_info.GcTypeInfos = if (rt.gc_type_infos_ptr) |p| @ptrCast(@alignCast(p)) else null;
    const heap: ?*const heap_mod.Heap = if (rt.gc_heap) |p| @ptrCast(@alignCast(p)) else null;
    return @intFromBool(ref_test_ops.gcRefMatchesNonNullCore(gti, heap, .{ .ref = ref }, ht));
}

/// GC-on-JIT: the `ref.cast` (non-null target) emit materialises this
/// fn's address + `CALL`s it (rt=arg0, ref=arg1 [full 64-bit reftype value],
/// ht=arg2). Returns the ref UNCHANGED on a successful cast (Wasm 3.0 GC
/// §4.4.5), or `0` to signal a trap — a null operand (non-null target
/// rejects it) OR a runtime type that is not a subtype of `ht`. `0` is an
/// unambiguous trap sentinel here: a successful non-null cast always returns
/// a non-zero ref. The match reuses the SAME `gcRefMatchesNonNullCore` the
/// interp + jitGcRefTest use. (ref.cast_null — which lets null pass — needs
/// an inline null-skip branch in emit and is a separate chunk.)
pub fn jitGcRefCast(rt: *JitRuntime, ref: u64, ht: u32) callconv(.c) u64 {
    if (comptime !wasm_v3_plus) @panic("jitGcRefCast in a sub-v3 build (unreachable — validator rejects GC ops)");
    if (ref == Value.null_ref) return 0; // null → trap (non-null target)
    const gti: ?*const gc_type_info.GcTypeInfos = if (rt.gc_type_infos_ptr) |p| @ptrCast(@alignCast(p)) else null;
    const heap: ?*const heap_mod.Heap = if (rt.gc_heap) |p| @ptrCast(@alignCast(p)) else null;
    // D-453: `ht` is the full encoded u32 (no null flag on the cast path).
    if (!ref_test_ops.gcRefMatchesNonNullCore(gti, heap, .{ .ref = ref }, ht)) return 0;
    return ref;
}

/// Wasm 3.0 §3.3.5.5 — JIT `call_indirect` resolve + runtime subtype check for
/// SUBTYPING modules (gti materialised; D-235). Returns the slot's native
/// funcptr iff `idx` is in-bounds for table `table_idx` AND the slot's stored
/// declared func type is a SUBTYPE of the call site's `expected_typeidx`
/// (self-inclusive, via the gti supertype chain / canonical-id,
/// D-232/ADR-0131); else `0` (trap). Replaces the inline D-111 structural `CMP`
/// for these modules, which is finality- AND subtype-blind: it over-accepts a
/// `(sub final (func))` callee for a `(sub (func))` expected (structurally
/// equal, distinct identity) and under-accepts a covariant-result subtype
/// (structurally distinct). For subtyping modules `setup.zig` stores the RAW
/// typeidx in `typeidx_base` (not the D-111 canonical) so this sees the true
/// callee identity. An empty slot (sentinel typeidx `maxInt(u32)`) reaches no
/// type → 0 → trap. An imported-function slot returns the bridge thunk and IS
/// callable (D-586 — it used to hold 0 and the inline sites dereferenced it);
/// a MEMORY-class signature is the one shape the thunk cannot carry, and it is
/// mis-called rather than rejected — D-586 (g). Both arches treat a `0` return
/// as a trap; arm64 then calls the returned funcptr directly (it survives the
/// arg marshal in a reserved scratch reg), x86_64 re-derives the funcptr inline
/// (its idx survives in the all-callee-saved regalloc pool). gti null is
/// impossible here (the module uses subtyping) but is handled as 0 for safety.
pub fn jitCallIndirectResolve(rt: *JitRuntime, table_idx: u32, idx: u64, expected_typeidx: u32) callconv(.c) u64 {
    if (comptime !wasm_v3_plus) @panic("jitCallIndirectResolve in a sub-v3 build (unreachable — no subtyping modules below Wasm 3.0)");
    const gti: *const gc_type_info.GcTypeInfos = if (rt.gc_type_infos_ptr) |p| @ptrCast(@alignCast(p)) else return 0;
    var funcptr_base: [*]const u64 = undefined;
    var typeidx_base: [*]const u32 = undefined;
    var size: u64 = undefined;
    if (table_idx == 0) {
        funcptr_base = rt.funcptr_base;
        typeidx_base = rt.typeidx_base;
        size = rt.table_size;
    } else {
        if (table_idx >= rt.tables_jit_ci_count or table_idx >= rt.tables_count) return 0;
        funcptr_base = rt.tables_jit_ci_ptr[table_idx].funcptr_base;
        typeidx_base = rt.tables_jit_ci_ptr[table_idx].typeidx_base;
        size = rt.tables_ptr[table_idx].len;
    }
    if (idx >= size) return 0;
    // D-294 residual: a NULL (uninitialized) element has the maxInt(u32) no-func
    // sentinel typeidx (compile_init.zig pre-seeds it; same indicator the inline
    // non-subtyping path's `CMN typeidx,#1` checks). Return the distinct NULL
    // sentinel (1) so the caller emits uninitialized_elem (code 13), matching
    // interp + wasmtime/wasmer, instead of collapsing it into the generic
    // sig-mismatch (code 3) the `return 0` path traps as. Funcptrs are mmap'd
    // code addresses, never 0/1, so both sentinels are unambiguous.
    if (typeidx_base[idx] == std.math.maxInt(u32)) return NULL_ELEM_SENTINEL;
    if (!ref_test_ops.concreteReachesGti(gti, typeidx_base[idx], expected_typeidx)) return 0;
    return funcptr_base[idx];
}

/// Distinct return value from `jitCallIndirectResolve` signalling a null/
/// uninitialized table element (vs `0` = generic OOB / sig-subtype failure).
/// The subtyping call_indirect caller (op_call.zig both arches) routes it to
/// the uninitialized_elem (code 13) trap stub. D-294 residual.
pub const NULL_ELEM_SENTINEL: u64 = 1;

// ============================================================
// Comptime offset constants — consumed by prologue emit (per-arch
// `compile()` writes `LDR Xn, [X0, #vm_base_off]` etc.).
//
// Each offset must fit in the LDR/STR imm12 budget:
//   X-form (8-byte): scaled by 8, max byte_off = 8*4095 = 32760
//   W-form (4-byte): scaled by 4, max byte_off = 4*4095 = 16380
// JitRuntime fits trivially within imm12 today (40 bytes total);
// future tail-extensions remain within 32760 by construction
// because the prologue only loads the head fields.
// ============================================================

pub const vm_base_off: u12 = @offsetOf(JitRuntime, "vm_base");
pub const mem_limit_off: u12 = @offsetOf(JitRuntime, "mem_limit");
pub const funcptr_base_off: u12 = @offsetOf(JitRuntime, "funcptr_base");
pub const table_size_off: u12 = @offsetOf(JitRuntime, "table_size");
pub const typeidx_base_off: u12 = @offsetOf(JitRuntime, "typeidx_base");
pub const trap_flag_off: u12 = @offsetOf(JitRuntime, "trap_flag");
pub const trap_kind_off: u12 = @offsetOf(JitRuntime, "trap_kind");
pub const globals_base_off: u12 = @offsetOf(JitRuntime, "globals_base");
pub const globals_count_off: u12 = @offsetOf(JitRuntime, "globals_count");
pub const host_dispatch_base_off: u12 = @offsetOf(JitRuntime, "host_dispatch_base");
pub const host_dispatch_count_off: u12 = @offsetOf(JitRuntime, "host_dispatch_count");
pub const jit_executed_flag_off: u12 = @offsetOf(JitRuntime, "jit_executed_flag");
pub const func_entities_ptr_off: u12 = @offsetOf(JitRuntime, "func_entities_ptr");
pub const func_entities_count_off: u12 = @offsetOf(JitRuntime, "func_entities_count");
pub const data_dropped_ptr_off: u12 = @offsetOf(JitRuntime, "data_dropped_ptr");
pub const data_dropped_count_off: u12 = @offsetOf(JitRuntime, "data_dropped_count");
pub const elem_dropped_ptr_off: u12 = @offsetOf(JitRuntime, "elem_dropped_ptr");
pub const elem_dropped_count_off: u12 = @offsetOf(JitRuntime, "elem_dropped_count");
pub const data_segments_ptr_off: u12 = @offsetOf(JitRuntime, "data_segments_ptr");
pub const data_segments_count_off: u12 = @offsetOf(JitRuntime, "data_segments_count");
pub const tables_ptr_off: u12 = @offsetOf(JitRuntime, "tables_ptr");
pub const tables_count_off: u12 = @offsetOf(JitRuntime, "tables_count");
pub const elem_segments_ptr_off: u12 = @offsetOf(JitRuntime, "elem_segments_ptr");
pub const elem_segments_count_off: u12 = @offsetOf(JitRuntime, "elem_segments_count");
pub const host_state_off: u12 = @offsetOf(JitRuntime, "host_state");
pub const memory_grow_fn_off: u12 = @offsetOf(JitRuntime, "memory_grow_fn");
pub const tables_jit_ci_ptr_off: u12 = @offsetOf(JitRuntime, "tables_jit_ci_ptr");
pub const tables_jit_ci_count_off: u12 = @offsetOf(JitRuntime, "tables_jit_ci_count");
pub const table_grow_fn_off: u12 = @offsetOf(JitRuntime, "table_grow_fn");
/// ADR-0168 — `atomic_rmw_fn` slot; X-form (8-byte fn pointer).
pub const atomic_rmw_fn_off: u12 = @offsetOf(JitRuntime, "atomic_rmw_fn");
/// ADR-0168 — base of the `atomic_cmpxchg_fns[4]` array; entry k at
/// `atomic_cmpxchg_fns_off + k*8` (k = width_log2). X-form pointers.
pub const atomic_cmpxchg_fns_off: u12 = @offsetOf(JitRuntime, "atomic_cmpxchg_fns");
/// ADR-0168 — `atomic_notify_fn` slot; X-form (8-byte fn pointer).
pub const atomic_notify_fn_off: u12 = @offsetOf(JitRuntime, "atomic_notify_fn");
/// ADR-0168 — base of `atomic_wait_fns[2]`; entry k at
/// `atomic_wait_fns_off + k*8` (k = width_log2 - 2). X-form pointers.
pub const atomic_wait_fns_off: u12 = @offsetOf(JitRuntime, "atomic_wait_fns");
/// ADR-0168 v0.2 — memory0's page_size_log2; W-form (u32). The JIT
/// memory.size emit reads it as a variable shift amount.
pub const mem0_page_size_log2_off: u12 = @offsetOf(JitRuntime, "mem0_page_size_log2");
/// ADR-0105 D1 / D2 — stack-probe threshold field offset. X-form
/// (8-byte usize); prologue emits `LDR Xn, [vmctx, #stack_limit_off]`.
pub const stack_limit_off: u12 = @offsetOf(JitRuntime, "stack_limit");
/// D-165 — trap-stub entry counter; W-form (4-byte u32).
/// x86_64 trap stub emits `INC DWORD PTR [R15 + this]` as its
/// first instruction; arm64 unchanged.
pub const trap_stub_entry_count_off: u12 = @offsetOf(JitRuntime, "trap_stub_entry_count");
/// EH dispatcher integration. Trampoline
/// reads ptr+count via `[X19/R15 + off]` to materialize
/// `ExceptionTable` + `CodeMap` slices for `dispatchThrow`.
pub const eh_table_entries_off: u12 = @offsetOf(JitRuntime, "eh_table_entries");
// ADR-0203 D1 (D-516) — de-baked helper slots; X-form (8-byte fn pointers)
// read via `LDR Xn, [X19, #off]` / `MOV rax, [R15 + off]` then BLR/CALL.
pub const call_indirect_resolve_fn_off: u12 = @offsetOf(JitRuntime, "call_indirect_resolve_fn");
pub const gc_alloc_fn_off: u12 = @offsetOf(JitRuntime, "gc_alloc_fn");
pub const gc_alloc_array_fn_off: u12 = @offsetOf(JitRuntime, "gc_alloc_array_fn");
pub const gc_alloc_array_fill_fn_off: u12 = @offsetOf(JitRuntime, "gc_alloc_array_fill_fn");
pub const gc_array_fill_fn_off: u12 = @offsetOf(JitRuntime, "gc_array_fill_fn");
pub const gc_array_copy_fn_off: u12 = @offsetOf(JitRuntime, "gc_array_copy_fn");
pub const gc_array_new_data_fn_off: u12 = @offsetOf(JitRuntime, "gc_array_new_data_fn");
pub const gc_array_new_elem_fn_off: u12 = @offsetOf(JitRuntime, "gc_array_new_elem_fn");
pub const gc_array_init_data_fn_off: u12 = @offsetOf(JitRuntime, "gc_array_init_data_fn");
pub const gc_array_init_elem_fn_off: u12 = @offsetOf(JitRuntime, "gc_array_init_elem_fn");
pub const gc_ref_test_fn_off: u12 = @offsetOf(JitRuntime, "gc_ref_test_fn");
pub const gc_ref_cast_fn_off: u12 = @offsetOf(JitRuntime, "gc_ref_cast_fn");
pub const rethrow_exnref_fn_off: u12 = @offsetOf(JitRuntime, "rethrow_exnref_fn");
pub const throw_trampoline_fn_off: u12 = @offsetOf(JitRuntime, "throw_trampoline_fn");
pub const eh_table_count_off: u12 = @offsetOf(JitRuntime, "eh_table_count");
pub const eh_code_map_entries_off: u12 = @offsetOf(JitRuntime, "eh_code_map_entries");
pub const eh_code_map_count_off: u12 = @offsetOf(JitRuntime, "eh_code_map_count");
/// Handler-dispatch fields read by
/// the naked-stub trampoline's branch after `trampolineCore` returns.
pub const eh_handler_active_off: u12 = @offsetOf(JitRuntime, "eh_handler_active");
pub const eh_handler_sp_off: u12 = @offsetOf(JitRuntime, "eh_handler_sp");
pub const eh_handler_pc_off: u12 = @offsetOf(JitRuntime, "eh_handler_pc");
pub const eh_handler_fp_off: u12 = @offsetOf(JitRuntime, "eh_handler_fp");
/// JIT payload staging region (ADR-0120). throw.emit writes
/// pop-N+store-at-`[runtime_ptr
/// + eh_payload_buf_off + i*8]`; try_table.emit's landing-pad
/// synthesis loads from the same. Base is 8-aligned (u64 slot
/// array); per-slot stride is 8 bytes.
pub const eh_payload_buf_off: u16 = @offsetOf(JitRuntime, "eh_payload_buf");
pub const eh_payload_len_off: u16 = @offsetOf(JitRuntime, "eh_payload_len");

/// D-327 / ADR-0120 D6 — exnref reify callout slot (X-form, 8-byte fn
/// pointer); the catch_ref / catch_all_ref landing pad BLRs through it.
pub const reify_exnref_fn_off: u16 = @offsetOf(JitRuntime, "reify_exnref_fn");

/// GC-on-JIT (ADR-0128 §2) — both X-form (8-byte pointer)
/// loads: `gc_heap` read by the alloc trampoline + struct.get/set
/// slab-base load; `gc_type_infos_ptr` read by the trampoline for
/// payload_size lookup.
pub const gc_heap_off: u12 = @offsetOf(JitRuntime, "gc_heap");
pub const gc_type_infos_ptr_off: u12 = @offsetOf(JitRuntime, "gc_type_infos_ptr");
/// ADR-0179 #3a / D-314 — host cooperative-interruption flag pointer, read
/// by the prologue/back-edge poll. Trailing field; no existing offset shifts.
pub const interrupt_ptr_off: u12 = @offsetOf(JitRuntime, "interrupt_ptr");
/// ADR-0179 #3b / D-314 — JIT fuel enable flag (W-form) + budget cell
/// (X-form), read/written by the fuel poll beside each interrupt poll.
/// Trailing fields.
pub const fuel_metered_off: u12 = @offsetOf(JitRuntime, "fuel_metered");
pub const fuel_cell_off: u12 = @offsetOf(JitRuntime, "fuel_cell");

/// Total size of the head section consumed by the prologue.
pub const head_size: u32 = @sizeOf(JitRuntime);

// Comptime guards — catching layout drift at build time, the
// W54-class regression-prevention discipline applied to ABI.
comptime {
    // Each X-form load offset must be 8-aligned (imm12 scales
    // by 8). Pointer + u64 fields are naturally 8-aligned by
    // the extern struct layout, but assert explicitly so a
    // future tail-extension that breaks alignment trips here.
    if ((vm_base_off & 7) != 0) @compileError("vm_base_off not 8-aligned");
    if ((mem_limit_off & 7) != 0) @compileError("mem_limit_off not 8-aligned");
    if ((funcptr_base_off & 7) != 0) @compileError("funcptr_base_off not 8-aligned");
    if ((typeidx_base_off & 7) != 0) @compileError("typeidx_base_off not 8-aligned");
    if ((interrupt_ptr_off & 7) != 0) @compileError("interrupt_ptr_off not 8-aligned");
    if ((fuel_metered_off & 3) != 0) @compileError("fuel_metered_off not 4-aligned");
    if ((fuel_cell_off & 7) != 0) @compileError("fuel_cell_off not 8-aligned");
    // table_size is X-form (u64 per D-475 table64); imm12 scales
    // by 8. Must be 8-aligned.
    if ((table_size_off & 7) != 0) @compileError("table_size_off not 8-aligned");
    if ((trap_flag_off & 3) != 0) @compileError("trap_flag_off not 4-aligned");
    // imm12 budget. With current 6 fields all near offset 0, this
    // is comfortable; future tail-extensions could exceed it.
    if (vm_base_off > 32760) @compileError("vm_base_off exceeds X-form imm12 budget");
    if (mem_limit_off > 32760) @compileError("mem_limit_off exceeds X-form imm12 budget");
    if (funcptr_base_off > 32760) @compileError("funcptr_base_off exceeds X-form imm12 budget");
    if (typeidx_base_off > 32760) @compileError("typeidx_base_off exceeds X-form imm12 budget");
    if (table_size_off > 32760) @compileError("table_size_off exceeds X-form imm12 budget");
    if (trap_flag_off > 16380) @compileError("trap_flag_off exceeds W-form imm12 budget");
    // ADR-0027: globals_base + globals_count alignment + budget.
    if ((globals_base_off & 7) != 0) @compileError("globals_base_off not 8-aligned");
    if ((globals_count_off & 3) != 0) @compileError("globals_count_off not 4-aligned");
    if (globals_base_off > 32760) @compileError("globals_base_off exceeds X-form imm12 budget");
    if (globals_count_off > 16380) @compileError("globals_count_off exceeds W-form imm12 budget");
    // Chunk 7.9-d: host_dispatch_base + host_dispatch_count.
    if ((host_dispatch_base_off & 7) != 0) @compileError("host_dispatch_base_off not 8-aligned");
    if ((host_dispatch_count_off & 3) != 0) @compileError("host_dispatch_count_off not 4-aligned");
    if (host_dispatch_base_off > 32760) @compileError("host_dispatch_base_off exceeds X-form imm12 budget");
    if (host_dispatch_count_off > 16380) @compileError("host_dispatch_count_off exceeds W-form imm12 budget");
    // ADR-0034: jit_executed_flag is W-form (4 bytes); imm12 scales by 4.
    if ((jit_executed_flag_off & 3) != 0) @compileError("jit_executed_flag_off not 4-aligned");
    if (jit_executed_flag_off > 16380) @compileError("jit_executed_flag_off exceeds W-form imm12 budget");
    // func_entities_ptr is X-form (8-byte pointer); count is W-form.
    if ((func_entities_ptr_off & 7) != 0) @compileError("func_entities_ptr_off not 8-aligned");
    if ((func_entities_count_off & 3) != 0) @compileError("func_entities_count_off not 4-aligned");
    if (func_entities_ptr_off > 32760) @compileError("func_entities_ptr_off exceeds X-form imm12 budget");
    if (func_entities_count_off > 16380) @compileError("func_entities_count_off exceeds W-form imm12 budget");
    // data_dropped / elem_dropped pointer + count.
    if ((data_dropped_ptr_off & 7) != 0) @compileError("data_dropped_ptr_off not 8-aligned");
    if ((data_dropped_count_off & 3) != 0) @compileError("data_dropped_count_off not 4-aligned");
    if (data_dropped_ptr_off > 32760) @compileError("data_dropped_ptr_off exceeds X-form imm12 budget");
    if (data_dropped_count_off > 16380) @compileError("data_dropped_count_off exceeds W-form imm12 budget");
    if ((elem_dropped_ptr_off & 7) != 0) @compileError("elem_dropped_ptr_off not 8-aligned");
    if ((elem_dropped_count_off & 3) != 0) @compileError("elem_dropped_count_off not 4-aligned");
    if (elem_dropped_ptr_off > 32760) @compileError("elem_dropped_ptr_off exceeds X-form imm12 budget");
    if (elem_dropped_count_off > 16380) @compileError("elem_dropped_count_off exceeds W-form imm12 budget");
    // data_segments_ptr is X-form (8-byte pointer); count is W-form.
    if ((data_segments_ptr_off & 7) != 0) @compileError("data_segments_ptr_off not 8-aligned");
    if ((data_segments_count_off & 3) != 0) @compileError("data_segments_count_off not 4-aligned");
    if (data_segments_ptr_off > 32760) @compileError("data_segments_ptr_off exceeds X-form imm12 budget");
    if (data_segments_count_off > 16380) @compileError("data_segments_count_off exceeds W-form imm12 budget");
    // SegmentSlice layout: 16 bytes (ptr + u64 len). JIT relies on
    // this for `LDR Xn, [seg_base, #(idx*16)+0]` (ptr) and
    // `LDR Xn, [seg_base, #(idx*16)+8]` (len).
    if (@sizeOf(SegmentSlice) != 16) @compileError("SegmentSlice size != 16; JIT memory.init stride assumption broken");
    // tables_ptr is X-form (8-byte pointer); count is W-form.
    if ((tables_ptr_off & 7) != 0) @compileError("tables_ptr_off not 8-aligned");
    if ((tables_count_off & 3) != 0) @compileError("tables_count_off not 4-aligned");
    if (tables_ptr_off > 32760) @compileError("tables_ptr_off exceeds X-form imm12 budget");
    if (tables_count_off > 16380) @compileError("tables_count_off exceeds W-form imm12 budget");
    // TODO(audit): table storage shape — see D-126 / ADR-0068.
    // TableSlice layout: 32 bytes after the D-475 u64 len/max widen
    // (refs ptr + u64 len + u64 max + funcptrs ptr). JIT relies on
    // `LDR Xn, [tbl_base, #(idx*32)+0]` (refs),
    // `LDR Xn, [tbl_base, #(idx*32)+8]` (len),
    // `LDR Xn, [tbl_base, #(idx*32)+16]` (max),
    // `LDR Xn, [tbl_base, #(idx*32)+24]` (funcptrs).
    if (@sizeOf(TableSlice) != 32) @compileError("TableSlice size != 32; JIT table.get stride assumption broken");
    if (@offsetOf(TableSlice, "refs") != 0) @compileError("TableSlice.refs offset != 0");
    if (@offsetOf(TableSlice, "len") != 8) @compileError("TableSlice.len offset != 8");
    if (@offsetOf(TableSlice, "max") != 16) @compileError("TableSlice.max offset != 16");
    if (@offsetOf(TableSlice, "funcptrs") != 24) @compileError("TableSlice.funcptrs offset != 24");
    // elem_segments_ptr is X-form; count is W-form.
    if ((elem_segments_ptr_off & 7) != 0) @compileError("elem_segments_ptr_off not 8-aligned");
    if ((elem_segments_count_off & 3) != 0) @compileError("elem_segments_count_off not 4-aligned");
    if (elem_segments_ptr_off > 32760) @compileError("elem_segments_ptr_off exceeds X-form imm12 budget");
    if (elem_segments_count_off > 16380) @compileError("elem_segments_count_off exceeds W-form imm12 budget");
    if (@sizeOf(ElemSlice) != 16) @compileError("ElemSlice size != 16; JIT table.init stride assumption broken");
    // (ADR-0059): host_state + memory_grow_fn
    // are both X-form (8-byte pointer) — natural 8-alignment from
    // extern struct layout; assert explicitly for future tail growth.
    if ((host_state_off & 7) != 0) @compileError("host_state_off not 8-aligned");
    if ((memory_grow_fn_off & 7) != 0) @compileError("memory_grow_fn_off not 8-aligned");
    if (host_state_off > 32760) @compileError("host_state_off exceeds X-form imm12 budget");
    if (memory_grow_fn_off > 32760) @compileError("memory_grow_fn_off exceeds X-form imm12 budget");
    // (D-112): tables_jit_ci_ptr is X-form (8-byte pointer); count is W-form.
    if ((tables_jit_ci_ptr_off & 7) != 0) @compileError("tables_jit_ci_ptr_off not 8-aligned");
    if ((tables_jit_ci_count_off & 3) != 0) @compileError("tables_jit_ci_count_off not 4-aligned");
    if (tables_jit_ci_ptr_off > 32760) @compileError("tables_jit_ci_ptr_off exceeds X-form imm12 budget");
    if (tables_jit_ci_count_off > 16380) @compileError("tables_jit_ci_count_off exceeds W-form imm12 budget");
    // TableJitCallInfo layout: 16 bytes (funcptr_base + typeidx_base, both pointers).
    // JIT call_indirect indexes the per-table descriptor array at stride 16.
    if (@sizeOf(TableJitCallInfo) != 16) @compileError("TableJitCallInfo size != 16; JIT call_indirect stride assumption broken");
    if (@offsetOf(TableJitCallInfo, "funcptr_base") != 0) @compileError("TableJitCallInfo.funcptr_base offset != 0");
    if (@offsetOf(TableJitCallInfo, "typeidx_base") != 8) @compileError("TableJitCallInfo.typeidx_base offset != 8");
    // (D-122 / D-125): table_grow_fn is X-form pointer.
    if ((table_grow_fn_off & 7) != 0) @compileError("table_grow_fn_off not 8-aligned");
    if (table_grow_fn_off > 32760) @compileError("table_grow_fn_off exceeds X-form imm12 budget");
    // ADR-0168: atomic_rmw_fn is X-form pointer.
    if ((atomic_rmw_fn_off & 7) != 0) @compileError("atomic_rmw_fn_off not 8-aligned");
    if (atomic_rmw_fn_off > 32760) @compileError("atomic_rmw_fn_off exceeds X-form imm12 budget");
    // ADR-0168: atomic_cmpxchg_fns base + last entry (k=3 → +24) X-form.
    if ((atomic_cmpxchg_fns_off & 7) != 0) @compileError("atomic_cmpxchg_fns_off not 8-aligned");
    if (atomic_cmpxchg_fns_off + 24 > 32760) @compileError("atomic_cmpxchg_fns_off exceeds X-form imm12 budget");
    // ADR-0168: atomic_notify_fn + atomic_wait_fns[2] (last entry +8) X-form.
    if ((atomic_notify_fn_off & 7) != 0) @compileError("atomic_notify_fn_off not 8-aligned");
    if (atomic_notify_fn_off > 32760) @compileError("atomic_notify_fn_off exceeds X-form imm12 budget");
    if ((atomic_wait_fns_off & 7) != 0) @compileError("atomic_wait_fns_off not 8-aligned");
    if (atomic_wait_fns_off + 8 > 32760) @compileError("atomic_wait_fns_off exceeds X-form imm12 budget");
    if ((mem0_page_size_log2_off & 3) != 0) @compileError("mem0_page_size_log2_off not 4-aligned");
    if (mem0_page_size_log2_off > 16380) @compileError("mem0_page_size_log2_off exceeds W-form imm12 budget");
    // ADR-0105 D1: stack_limit is X-form (usize); imm12 scales by 8.
    if ((stack_limit_off & 7) != 0) @compileError("stack_limit_off not 8-aligned");
    if (stack_limit_off > 32760) @compileError("stack_limit_off exceeds X-form imm12 budget");
    // EH ptr+count fields. Ptrs are X-form
    // (8-byte); counts are W-form (4-byte). The trampoline's read
    // sequence requires both alignment + within-imm12 budget.
    if ((eh_table_entries_off & 7) != 0) @compileError("eh_table_entries_off not 8-aligned");
    if ((eh_table_count_off & 3) != 0) @compileError("eh_table_count_off not 4-aligned");
    if (eh_table_entries_off > 32760) @compileError("eh_table_entries_off exceeds X-form imm12 budget");
    if (eh_table_count_off > 16380) @compileError("eh_table_count_off exceeds W-form imm12 budget");
    if ((eh_code_map_entries_off & 7) != 0) @compileError("eh_code_map_entries_off not 8-aligned");
    if ((eh_code_map_count_off & 3) != 0) @compileError("eh_code_map_count_off not 4-aligned");
    if (eh_code_map_entries_off > 32760) @compileError("eh_code_map_entries_off exceeds X-form imm12 budget");
    if (eh_code_map_count_off > 16380) @compileError("eh_code_map_count_off exceeds W-form imm12 budget");
    // GC-on-JIT: both X-form (8-byte pointer) loads.
    if ((gc_heap_off & 7) != 0) @compileError("gc_heap_off not 8-aligned");
    if ((gc_type_infos_ptr_off & 7) != 0) @compileError("gc_type_infos_ptr_off not 8-aligned");
    if (gc_heap_off > 32760) @compileError("gc_heap_off exceeds X-form imm12 budget");
    if (gc_type_infos_ptr_off > 32760) @compileError("gc_type_infos_ptr_off exceeds X-form imm12 budget");
    // ADR-0203 D1 (D-516): de-baked helper slots — all X-form fn pointers.
    for ([_]u12{
        call_indirect_resolve_fn_off, gc_alloc_fn_off,          gc_alloc_array_fn_off,
        gc_alloc_array_fill_fn_off,   gc_array_fill_fn_off,     gc_array_copy_fn_off,
        gc_array_new_data_fn_off,     gc_array_new_elem_fn_off, gc_array_init_data_fn_off,
        gc_array_init_elem_fn_off,    gc_ref_test_fn_off,       gc_ref_cast_fn_off,
        rethrow_exnref_fn_off,        throw_trampoline_fn_off,
    }) |off| {
        if ((off & 7) != 0) @compileError("ADR-0203 helper fn slot not 8-aligned");
        if (off > 32760) @compileError("ADR-0203 helper fn slot exceeds X-form imm12 budget");
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "JitRuntime: layout offsets match documented prologue load sequence" {
    try testing.expectEqual(@as(u12, 0), vm_base_off);
    try testing.expectEqual(@as(u12, 8), mem_limit_off);
    try testing.expectEqual(@as(u12, 16), funcptr_base_off);
    try testing.expectEqual(@as(u12, 24), table_size_off);
    try testing.expectEqual(@as(u12, 32), typeidx_base_off);
    try testing.expectEqual(@as(u12, 40), trap_flag_off);
    try testing.expectEqual(@as(u12, 64), host_dispatch_base_off);
    try testing.expectEqual(@as(u12, 72), host_dispatch_count_off);
    try testing.expectEqual(@as(u12, 80), jit_executed_flag_off);
}

test "JitRuntime: total size = 720 bytes" {
    // EH dispatcher fields appended
    // (+32 bytes = 2 ptrs × 8 B + 2 u32 × 4 B + 2 u32 pads × 4 B).
    // The handler-dispatch result fields
    // (+24 bytes = u32 active replacing the prior pad
    // + 3 usize for SP, PC, FP).
    // Payload staging (ADR-0120)
    // (+136 bytes = 16 × 8 B buf + u32 len + u32 pad).
    // GC-on-JIT (ADR-0128 §2) appends gc_heap + gc_type_infos_ptr
    // (+16 bytes = 2 × 8 B opaque pointers) → 432 + 16 = 448.
    // Tag-identity fields (ADR-0134 D3) append tag_ids_ptr + count + pad
    // (+16 bytes = 8 B ptr + 2 × 4 B) → 448 + 16 = 464.
    // D-244 (JIT-WASI) appends `wasi_host` (+8 B opaque ptr) → 464 + 8 = 472.
    // ADR-0168 appends `atomic_rmw_fn` (+8 B fn ptr, trailing) → 472 + 8 = 480.
    // ADR-0168 appends `atomic_cmpxchg_fns[4]` (+32 B, trailing) → 480 + 32 = 512.
    // ADR-0168 appends atomic_notify_fn (+8) + atomic_wait_fns[2] (+16) +
    // mem0_shared (u32 +4, pad +4) → 512 + 32 = 544.
    // D-314 appends `interrupt_ptr` (?*const atomic, +8 B, trailing) → 544 + 8 = 552.
    // D-314 #3b appends `fuel_metered`+pad+`fuel_cell` (+16 B, trailing) → 552 + 16 = 568.
    // D-327 (ADR-0120 D6) appends `reify_exnref_fn` (+8) + `eh_reify_ctx` (+8) +
    // `eh_thrown_tag_idx` (u32 +4) + `_pad_reify` (+4) → 568 + 24 = 592.
    // D-314(b) appends `store_table_elements_max` (u64 +8, trailing) → 592 + 8 = 600.
    // D-478 appends `host_payloads_base` (?[*]const usize +8 B, trailing) → 600 + 8 = 608.
    // ADR-0203 D1 appends 14 de-baked helper fn slots (trailing) → 608 + 112 = 720.
    try testing.expectEqual(@as(u32, 720), head_size);
}

test "jitGcAlloc: allocates struct{i32} via the *JitRuntime bridge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sections = @import("../../../parse/sections.zig");
    // 1 type: struct { i32 mut } → body `01 5F 01 7F 01`.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    var types = try sections.decodeTypes(testing.allocator, &body);
    defer types.deinit();
    var gti = try gc_type_info.materialiseGcTypes(a, types);
    var heap = heap_mod.Heap.init(a);

    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    rt.gc_heap = &heap;
    rt.gc_type_infos_ptr = &gti;

    const ref = jitGcAlloc(&rt, 0);
    try testing.expect(ref >= 2); // non-null GcRef
    const ObjectHeader = gc_type_info.ObjectHeader;
    const hsz = @sizeOf(ObjectHeader);
    var hdr: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..hsz], heap.bytes[ref .. ref + hsz]);
    try testing.expectEqual(gc_type_info.ObjectKind.struct_, hdr.kind);
    try testing.expectEqual(@as(u32, 0), hdr.info);
    // payload (1 i32 field, 8-byte slot) is zero-inited by the trampoline.
    var payload: u64 = undefined;
    @memcpy(std.mem.asBytes(&payload), heap.bytes[ref + hsz .. ref + hsz + 8]);
    try testing.expectEqual(@as(u64, 0), payload);
}

test "jitGcAlloc: null gc_heap → returns 0 (null sentinel)" {
    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    // gc_heap left null → trampoline returns the null sentinel.
    try testing.expectEqual(@as(u32, 0), jitGcAlloc(&rt, 0));
}

test "jitGcAllocArray: allocates array(mut i32) length 3 via the *JitRuntime bridge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sections = @import("../../../parse/sections.zig");
    // 1 type: array (mut i32) → body `01 5E 7F 01`.
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    var types = try sections.decodeTypes(testing.allocator, &body);
    defer types.deinit();
    var gti = try gc_type_info.materialiseGcTypes(a, types);
    var heap = heap_mod.Heap.init(a);

    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    rt.gc_heap = &heap;
    rt.gc_type_infos_ptr = &gti;

    const ref = jitGcAllocArray(&rt, 0, 3);
    try testing.expect(ref >= 2); // non-null GcRef
    const ArrayHeader = gc_type_info.ArrayHeader;
    const ahsz = @sizeOf(ArrayHeader);
    var hdr: ArrayHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..ahsz], heap.bytes[ref .. ref + ahsz]);
    try testing.expectEqual(gc_type_info.ObjectKind.array, hdr.header.kind);
    try testing.expectEqual(@as(u32, 0), hdr.header.info);
    try testing.expectEqual(@as(u32, 3), hdr.length);
    // 3 element slots (8-byte each) zero-inited by the trampoline.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const off = ref + ahsz + i * 8;
        var slot: u64 = undefined;
        @memcpy(std.mem.asBytes(&slot), heap.bytes[off .. off + 8]);
        try testing.expectEqual(@as(u64, 0), slot);
    }
}

test "jitGcAllocArray: null gc_heap → returns 0 (null sentinel)" {
    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    try testing.expectEqual(@as(u32, 0), jitGcAllocArray(&rt, 0, 3));
}

test "jitGcAllocArrayFill: allocates array(mut i32) len 2 filled with init" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sections = @import("../../../parse/sections.zig");
    // 1 type: array (mut i32) → body `01 5E 7F 01`.
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    var types = try sections.decodeTypes(testing.allocator, &body);
    defer types.deinit();
    var gti = try gc_type_info.materialiseGcTypes(a, types);
    var heap = heap_mod.Heap.init(a);

    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    rt.gc_heap = &heap;
    rt.gc_type_infos_ptr = &gti;

    const ref = jitGcAllocArrayFill(&rt, 0, 2, 7);
    try testing.expect(ref >= 2);
    const ArrayHeader = gc_type_info.ArrayHeader;
    const ahsz = @sizeOf(ArrayHeader);
    var hdr: ArrayHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..ahsz], heap.bytes[ref .. ref + ahsz]);
    try testing.expectEqual(@as(u32, 2), hdr.length);
    // Both element slots filled with 7 (not zero-inited).
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        const off = ref + ahsz + i * 8;
        var slot: u64 = undefined;
        @memcpy(std.mem.asBytes(&slot), heap.bytes[off .. off + 8]);
        try testing.expectEqual(@as(u64, 7), slot);
    }
}

test "JitRuntime: eh_payload_buf + eh_payload_len offsets (ADR-0120)" {
    // 8-aligned (X-form u64 array stride).
    if ((eh_payload_buf_off & 7) != 0) @compileError("eh_payload_buf_off not 8-aligned");
    // 4-aligned (W-form u32 store).
    if ((eh_payload_len_off & 3) != 0) @compileError("eh_payload_len_off not 4-aligned");
    // eh_payload_len immediately follows the 16×u64 buf.
    try testing.expectEqual(@as(u16, eh_payload_buf_off) + 128, eh_payload_len_off);
}

test "reifyExnref: snapshots thrown tag + payload into a *Exception (ADR-0120 D6 / D-327)" {
    // reify_exnref_fn_off is an X-form (8-byte) fn-pointer load.
    if ((reify_exnref_fn_off & 7) != 0) @compileError("reify_exnref_fn_off not 8-aligned");

    var ctx: EhReifyCtx = .{ .allocator = testing.allocator };
    defer ctx.deinit();

    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    rt.eh_reify_ctx = &ctx;
    rt.eh_thrown_tag_idx = 7;
    rt.eh_payload_len = 2;
    rt.eh_payload_buf[0] = 88;
    rt.eh_payload_buf[1] = 0xDEAD_BEEF;

    const handle = reifyExnref(&rt);
    try testing.expect(handle != 0);
    const exc: *exception_mod.Exception = @ptrFromInt(handle);
    try testing.expectEqual(@as(u32, 7), exc.tag_idx);
    try testing.expectEqual(@as(u32, 2), exc.payload_len);
    try testing.expectEqual(@as(u64, 88), exc.payload[0].bits64);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), exc.payload[1].bits64);

    // Snapshot, not alias: clobbering the shared buffer + reifying again
    // must not disturb the first exnref (it may be held + re-thrown later).
    rt.eh_payload_buf[0] = 0xAA;
    rt.eh_thrown_tag_idx = 3;
    const handle2 = reifyExnref(&rt);
    try testing.expect(handle2 != 0 and handle2 != handle);
    try testing.expectEqual(@as(u64, 88), exc.payload[0].bits64); // first unchanged
    try testing.expectEqual(@as(u32, 7), exc.tag_idx);
    try testing.expectEqual(@as(usize, 2), ctx.exceptions.items.len); // both tracked
}

test "JitRuntime: trap_stub_entry_count offset (W-form imm12-safe)" {
    try testing.expectEqual(@as(u12, 232), trap_stub_entry_count_off);
    // 4-aligned (W-form); imm12 budget unchecked but 232 << 16380 trivially.
    if ((trap_stub_entry_count_off & 3) != 0) @compileError("trap_stub_entry_count_off not 4-aligned");
}

test "JitRuntime: callout offsets (host_state + memory_grow_fn)" {
    try testing.expectEqual(@as(u12, 184), host_state_off);
    try testing.expectEqual(@as(u12, 192), memory_grow_fn_off);
}

test "JitRuntime: tables_jit_ci offsets" {
    try testing.expectEqual(@as(u12, 200), tables_jit_ci_ptr_off);
    try testing.expectEqual(@as(u12, 208), tables_jit_ci_count_off);
}

test "JitRuntime: table_grow_fn offset" {
    try testing.expectEqual(@as(u12, 216), table_grow_fn_off);
}

test "JitRuntime: ADR-0105 D1 stack_limit offset (tail field; X-form imm12-safe)" {
    try testing.expectEqual(@as(u12, 224), stack_limit_off);
}

test "TableJitCallInfo: layout is 16 bytes with funcptr_base/typeidx_base at expected offsets" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(TableJitCallInfo));
    try testing.expectEqual(@as(usize, 0), @offsetOf(TableJitCallInfo, "funcptr_base"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TableJitCallInfo, "typeidx_base"));
}

test "JitRuntime: new field offsets" {
    try testing.expectEqual(@as(u12, 88), func_entities_ptr_off);
    try testing.expectEqual(@as(u12, 96), func_entities_count_off);
    try testing.expectEqual(@as(u12, 104), data_dropped_ptr_off);
    try testing.expectEqual(@as(u12, 112), data_dropped_count_off);
    try testing.expectEqual(@as(u12, 120), elem_dropped_ptr_off);
    try testing.expectEqual(@as(u12, 128), elem_dropped_count_off);
    try testing.expectEqual(@as(u12, 136), data_segments_ptr_off);
    try testing.expectEqual(@as(u12, 144), data_segments_count_off);
    try testing.expectEqual(@as(u12, 152), tables_ptr_off);
    try testing.expectEqual(@as(u12, 160), tables_count_off);
    try testing.expectEqual(@as(u12, 168), elem_segments_ptr_off);
    try testing.expectEqual(@as(u12, 176), elem_segments_count_off);
}

test "TableSlice: layout is 32 bytes with refs/len/max/funcptrs at expected offsets (ADR-0068 + D-475 u64 widen)" {
    try testing.expectEqual(@as(u32, 32), table_slice_size);
    try testing.expectEqual(@as(usize, 0), @offsetOf(TableSlice, "refs"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TableSlice, "len"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(TableSlice, "max"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(TableSlice, "funcptrs"));
    try testing.expectEqual(@as(usize, 8), tableslice_len_off);
    try testing.expectEqual(@as(usize, 24), tableslice_funcptrs_off);
}

test "ElemSlice: layout is 16 bytes with refs/len at expected offsets" {
    try testing.expectEqual(@as(u32, 16), elem_slice_size);
    try testing.expectEqual(@as(usize, 0), @offsetOf(ElemSlice, "refs"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ElemSlice, "len"));
}

test "JitRuntime: round-trip construction + field reads" {
    var memory: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const funcptrs = [_]u64{0xCAFE0000};
    const typeidxs = [_]u32{7};
    var globals = [_]Value{ Value.fromI32(11), Value.fromI32(22) };
    const dispatch = [_]usize{0xDEADBEEF};
    const rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = &funcptrs,
        .table_size = 1,
        .typeidx_base = &typeidxs,
        .trap_flag = 0,
        .globals_base = &globals,
        .globals_count = globals.len,
        .host_dispatch_base = &dispatch,
        .host_dispatch_count = dispatch.len,
    };
    try testing.expectEqual(@as(u64, 16), rt.mem_limit);
    try testing.expectEqual(@as(u64, 1), rt.table_size);
    try testing.expectEqual(@as(u8, 0xDE), rt.vm_base[0]);
    try testing.expectEqual(@as(u64, 0xCAFE0000), rt.funcptr_base[0]);
    try testing.expectEqual(@as(u32, 7), rt.typeidx_base[0]);
    try testing.expectEqual(@as(u32, 0), rt.trap_flag);
    try testing.expectEqual(@as(i32, 11), rt.globals_base[0].i32);
    try testing.expectEqual(@as(i32, 22), rt.globals_base[1].i32);
    try testing.expectEqual(@as(u32, 2), rt.globals_count);
    try testing.expectEqual(@as(usize, 0xDEADBEEF), rt.host_dispatch_base[0]);
    try testing.expectEqual(@as(u32, 1), rt.host_dispatch_count);
}

test "JitRuntime: EH ptr+count fields populate and are readable" {
    // Verify the new EH dispatcher
    // fields (`eh_table_entries` + `eh_table_count` +
    // `eh_code_map_entries` + `eh_code_map_count`) can be
    // populated by instance setup and read back via the same
    // offsets the trampoline will use. Layout-stable proof:
    // the comptime guards above already assert imm12-budget +
    // alignment; this runtime test exercises the write/read
    // round-trip a real `setup` pass will produce.
    const eh_table = [_]exception_table.HandlerEntry{
        .{ .pc_start = 0, .pc_end = 100, .tag_idx = 5, .landing_pad_pc = 42, .kind = .catch_ },
    };
    const eh_map = [_]code_map.Entry{
        .{ .start_addr = 0x1000, .len = 256, .func_idx = 0, .frame_bytes = 48 },
    };
    var rt: JitRuntime = std.mem.zeroes(JitRuntime);
    rt.eh_table_entries = eh_table[0..].ptr;
    rt.eh_table_count = eh_table.len;
    rt.eh_code_map_entries = eh_map[0..].ptr;
    rt.eh_code_map_count = eh_map.len;

    // Default-zero state proves the `?[*]const` + `= null` /
    // `u32 = 0` defaults from earlier construction sites stay
    // intact for non-EH modules.
    const rt_default: JitRuntime = std.mem.zeroes(JitRuntime);
    try testing.expectEqual(@as(?[*]const exception_table.HandlerEntry, null), rt_default.eh_table_entries);
    try testing.expectEqual(@as(u32, 0), rt_default.eh_table_count);
    try testing.expectEqual(@as(?[*]const code_map.Entry, null), rt_default.eh_code_map_entries);
    try testing.expectEqual(@as(u32, 0), rt_default.eh_code_map_count);

    // Populated-state round-trip — the trampoline will read these
    // via `[X19, #eh_table_entries_off]` (arm64) / `[R15 +
    // eh_table_entries_off]` (x86_64).
    try testing.expectEqual(@as(u32, 1), rt.eh_table_count);
    try testing.expectEqual(@as(u32, 5), rt.eh_table_entries.?[0].tag_idx.?);
    try testing.expectEqual(@as(u32, 42), rt.eh_table_entries.?[0].landing_pad_pc);
    try testing.expectEqual(@as(u32, 1), rt.eh_code_map_count);
    try testing.expectEqual(@as(usize, 0x1000), rt.eh_code_map_entries.?[0].start_addr);
    try testing.expectEqual(@as(u32, 0), rt.eh_code_map_entries.?[0].func_idx);
    try testing.expectEqual(@as(u32, 48), rt.eh_code_map_entries.?[0].frame_bytes);
}
