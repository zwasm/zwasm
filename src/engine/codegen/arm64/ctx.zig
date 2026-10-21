//! ARM64 emit pass — shared error set, output types, and the
//! per-function emit context.
//!
//! Per ADR-0023 §3 reference table + ADR-0021 sub-deliverable b
//! (emit.zig 9-module split): EmitCtx is the
//! parameter bundle that op-handler modules (`op_const.zig`,
//! `op_alu.zig`, …) take as their sole context argument. Fields
//! are *pointers* into compile()'s local state so that any
//! handler — whether already extracted or still inlined in
//! emit.zig — observes the same backing storage. This permits
//! incremental migration of one op-group at a time without
//! forcing a single big-bang refactor.
//!
//! `Error` and `CallFixup` live here (not in emit.zig) so that
//! op-handler modules can reach for them without circular
//! imports back to emit.zig.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");

const zir = @import("../../../ir/zir.zig");
const sections = @import("../../../parse/sections.zig");
const regalloc = @import("../shared/regalloc.zig");
const exception_table = @import("../shared/exception_table.zig");
const label_mod = @import("label.zig");
const local_homing = @import("../../../ir/analysis/local_homing.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Label = label_mod.Label;

/// Errors raised by the ARM64 emit pass and its op-handler
/// modules. `OutOfMemory` is propagated from buffer growth and
/// fixup-list appends.
pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

/// Pending `BL` / `B` site requiring linker patch. The post-emit
/// caller (linker / runtime harness) computes the target
/// address relative to `byte_offset` and rewrites the imm26
/// field. `target_func_idx` is the Wasm function index the call
/// targets.
///
/// `is_tail` selects the opcode the linker writes (ADR-0112 D4):
/// `false` → `BL` (regular call, LR saved); `true` → `B`
/// (tail-call, no LR). The two share the same `imm26` field
/// layout — only bit 31 differs — so the same fixup record
/// drives both with a single dispatch in `shared/linker.zig`.
pub const CallFixup = struct {
    byte_offset: u32,
    target_func_idx: u32,
    is_tail: bool = false,
};

/// Pending `LDR Q<rt>, <label>` site requiring const-pool patch
/// (per ADR-0042). At function close, after the trap stub, the
/// per-function const-pool is appended (16-byte aligned) and the
/// imm19 field of every SimdConstFixup is patched to the
/// PC-relative offset of `func.simd_consts[const_idx]`.
pub const SimdConstFixup = struct {
    byte_offset: u32, // location of the LDR-Q-literal placeholder
    const_idx: u32, // index into func.simd_consts
};

/// Per-function emit context. Built by `compile()` once after
/// the function prologue lands; threaded as `*EmitCtx` to every
/// op-handler module so each handler can append code, manage the
/// pushed-vreg stack, register fixups, and look up call targets
/// uniformly. All mutable fields are pointers; this lets
/// compile()'s local state and the EmitCtx view coexist while
/// op-groups migrate one by one.
pub const EmitCtx = struct {
    allocator: Allocator,
    /// Output instruction stream. Handlers append `u32` words
    /// (little-endian) via the standard `writeU32` helper.
    buf: *std.ArrayList(u8),
    /// Source ZIR function (read-only).
    func: *const ZirFunc,
    /// Register allocation for `func` (read-only).
    alloc: regalloc.Allocation,
    /// `func_sigs[k]` is the FuncType of function index `k`;
    /// consulted by `call N` to pick the result register class.
    func_sigs: []const zir.FuncType,
    /// `module_types[t]` is the FuncType for type index `t`;
    /// consulted by `call_indirect type_idx`.
    module_types: []const zir.FuncType,
    /// Operand stack of pushed vreg ids. Handlers pop their
    /// operands and append the result vreg.
    pushed_vregs: *std.ArrayList(u32),
    /// Cursor for the next vreg id to allocate.
    next_vreg: *u32,
    /// Control-stack frames (block / loop / if / else).
    labels: *std.ArrayList(Label),
    /// Memory-bounds-trap fixups awaiting trap-stub emission at
    /// function-final `end`.
    bounds_fixups: *std.ArrayList(u32),
    /// call_indirect bounds-check
    /// (B.HS) fixups. Patched to a dedicated trap stub that writes
    /// `trap_kind = 2`. Permanent diagnostic infra: every future
    /// call_indirect bounds trap localises its source via
    /// `printCallTrap`'s `kind=` emit.
    cind_bounds_fixups: *std.ArrayList(u32),
    /// call_indirect sig-mismatch
    /// (B.NE) fixups. Patched to a dedicated trap stub that
    /// writes `trap_kind = 3`. See `cind_bounds_fixups`.
    cind_sig_fixups: *std.ArrayList(u32),
    /// D-294 — call_indirect on a NULL (uninitialized) in-bounds table element
    /// (uninitialized_elem, code 13) fixups. A null slot's typeidx is
    /// `maxInt(u32)` (the no-func sentinel); `CMN W16, #1` (= W16 == 0xFFFFFFFF)
    /// + B.EQ PRECEDES the sig CMP so null reports code 13, not sig code 3.
    uninit_elem_fixups: *std.ArrayList(u32),
    /// ADR-0164 A2 / D-292 — div-by-zero (B.EQ → code 7) + div_s signed-overflow
    /// (B.VS → code 8) fixups, demuxed out of `bounds_fixups` so each reaches a
    /// dedicated trap stub recording its precise `trap_kind`.
    divzero_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    /// D-303 — atomic load/store unaligned-access (B.NE on `ea & (size-1)` →
    /// code 14 = unaligned_atomic) fixups. The RMW/cmpxchg/wait/notify family
    /// checks alignment in the jit_abi helper; inline atomic load/store had NO
    /// check (interp-only), so this demuxed stub closes the JIT/interp gap.
    unaligned_atomic_fixups: *std.ArrayList(u32),
    /// D-293 slice-3 — trapping-trunc NaN (B.VS → code 9 = invalid_conversion)
    /// fixups, demuxed out of `bounds_fixups`. The trunc range checks reuse
    /// `overflow_fixups` (code 8). Other `bounds_fixups` kinds stay generic.
    invalid_conv_fixups: *std.ArrayList(u32),
    /// D-293 slice-4b — call_ref-null + ref.as_non_null null-reference (B.EQ →
    /// code 10 = null_reference) fixups, demuxed out of `bounds_fixups`. NOTE the
    /// arm64 call_ref null check previously appended to `cind_bounds_fixups`
    /// (mis-reporting oob_table code 2); slice-4b re-routes it here.
    null_ref_fixups: *std.ArrayList(u32),
    /// D-293 slice-4d — ref.cast / ref.cast_null subtype-mismatch (B.EQ on the
    /// jitGcRefCast 0-return → code 11 = cast_failure) fixups, demuxed out of
    /// `bounds_fixups`.
    cast_fail_fixups: *std.ArrayList(u32),
    /// D-292 C — throw / throw_ref uncaught-exception (the unconditional `B` to
    /// the trap stub after `zwasm_throw` returns `.uncaught` → code 12 =
    /// uncaught_exception) fixups, demuxed out of `bounds_fixups`.
    uncaught_exc_fixups: *std.ArrayList(u32),
    /// ADR-0164 A3 / D-292 — memory load/store/bulk-memory out-of-bounds
    /// (B.HI → code 6) fixups, demuxed out of `bounds_fixups` so oob_memory
    /// reaches a dedicated trap stub. Other `bounds_fixups` kinds (oob_table /
    /// conversion / ref-null / cast / array-oob) stay generic (D-293).
    oob_fixups: *std.ArrayList(u32),
    /// ADR-0179 #3a / D-314 — loop back-edge cooperative-interruption poll
    /// (B.NE → code 16) fixups. Distinct from the PROLOGUE interrupt poll (a
    /// separate single fixup, fb=0): a back-edge poll fires POST-frame, so its
    /// stub restores frame_bytes before LDP/RET (fb=frame_bytes, same as oob).
    back_edge_interrupt_fixups: *std.ArrayList(u32),
    /// ADR-0179 #3b / D-314 — loop back-edge fuel poll (B.MI → code 17 =
    /// out_of_fuel) fixups. Emitted beside each back-edge interrupt poll;
    /// same POST-frame stub shape (fb=frame_bytes).
    back_edge_fuel_fixups: *std.ArrayList(u32),
    /// `return` / `br <function-depth>` placeholders; patched at
    /// function-final `end` to share the regular epilogue path.
    return_fixups: *std.ArrayList(u32),
    /// `BL` fixups exposed via `EmitOutput` for the post-emit
    /// linker.
    call_fixups: *std.ArrayList(CallFixup),
    /// SIMD const-pool fixups (per ADR-0042). Each entry records
    /// the byte offset of an LDR-Q-literal placeholder and a
    /// global const_idx into the flat per-function pool. The pool
    /// concatenates `func.simd_consts` (lower-time literals) and
    /// `extra_consts` (emit-time derived constants per ADR-0051);
    /// const_idx ∈ [0, simd_consts_base) addresses the former,
    /// const_idx ∈ [simd_consts_base, ...) the latter. Patched at
    /// function close after both lists are appended (16-byte
    /// aligned) past the trap stub.
    simd_const_fixups: *std.ArrayList(SimdConstFixup),
    /// Emit-time-derived 16-byte SIMD constants discovered by
    /// per-op handlers (per ADR-0051; mirror of x86_64's
    /// `extra_consts`). Per-shape masks, magic constants, LUTs.
    /// Appended to the flat const-pool *after* lower-time entries
    /// at function close. Handlers register entries via
    /// `op_simd.lookupOrAppendExtraConst`.
    extra_consts: *std.ArrayList([16]u8),
    /// Number of lower-time entries in the flat const-pool.
    /// Equals `func.simd_consts.?.len` when non-null, 0 otherwise.
    /// Handlers compute global const_idx as `simd_consts_base +
    /// position-in-extra_consts`.
    simd_consts_base: u32,
    /// Absolute SP-relative byte offset of local slot 0.
    /// Equals `outgoing_max_bytes`, the bottom-of-
    /// frame region pre-allocated for caller-side stack args. Zero
    /// for functions that make no calls or whose every callee fits
    /// args in X1..X7 + V0..V7. Locals at `[SP, #(local_base_off +
    /// p_idx*8)]`.
    local_base_off: u32,
    /// Absolute SP-relative byte offset of spill slot 0.
    /// Equals `local_base_off + locals_bytes`;
    /// the spill region sits above locals which sits above the
    /// outgoing-args region. Read by `gprLoadSpilled` /
    /// `gprStoreSpilled` to address spill slots.
    spill_base_off: u32,
    /// Per ADR-0017 (2026-05-18 amend;
    /// ADR-0069 §Phase 2): true iff this function's return tuple
    /// is MEMORY-class per AAPCS64 §6.8.2 — caller passes a hidden
    /// indirect-result-pointer in X8 which the prologue captures
    /// to `[SP, #indirect_result_slot_off]` and the epilogue
    /// (`marshalFunctionReturn`) writes each result to
    /// `[X8, #(i*8)]` via X16. v2 classifies MEMORY-class as
    /// `sig.results.len > 2` (each FuncRet_* field 8 B per
    /// ADR-0069 Class A convention; 3+ results force struct > 16 B).
    return_is_memory_class: bool,
    /// SP-relative byte offset of the captured X8 slot when
    /// `return_is_memory_class` is true; meaningless otherwise.
    /// Slot sits above the spill region inside the function frame.
    indirect_result_slot_off: u32,
    /// Leading wasm-space function indices that name imports.
    /// `op_call.emitCall` checks
    /// `ins.payload < num_imports` to decide between a normal
    /// BL + CallFixup (defined function call) and an
    /// import-as-trap branch (B → trap stub via bounds_fixups).
    num_imports: u32,
    /// Per-function EH handler-entry accumulator.
    /// `op_exception_handling.try_table` appends one `HandlerEntry`
    /// per catch clause (per ADR-0114 D2); the post-emit linker
    /// finalises into the per-Instance ExceptionTable consumed by
    /// the FP-walk unwinder. Optional: null for functions that
    /// contain no try_table (back-compat for every existing
    /// EmitCtx construction site).
    exception_table_builder: ?*exception_table.Builder = null,
    /// Stack of open `try_table` blocks; one
    /// `OpenTryTable` entry per try_table currently between its
    /// emit and its matching `end`. The end-op patches pc_end of
    /// the `entry_start..entry_start+entry_count` Builder rows
    /// when popping a label whose stack position matches
    /// `labels_depth`. Optional: null for functions without any
    /// try_table; non-null iff `exception_table_builder` is non-null.
    open_try_tables: ?*std.ArrayList(exception_table.OpenTryTable) = null,
    /// Per-catch landing_pad_pc forward
    /// fixup list. `try_table.emit` appends one per catch clause
    /// (key = labels-stack depth of the target br-label); the
    /// matching label's `end` patches `Builder.entries[entry_idx]
    /// .landing_pad_pc` to the post-end buf offset. Non-null iff
    /// `exception_table_builder` is non-null.
    landing_pad_fixups: ?*std.ArrayList(exception_table.LandingPadFixup) = null,
    /// Per-defined-global metadata (ADR-0052).
    /// Indexed by **defined** global idx (= wasm-space global
    /// idx minus the leading imported-global count). Parallel
    /// arrays: `globals_offsets[i]` is the byte offset of
    /// global i inside the runtime's globals byte buffer;
    /// `globals_valtypes[i]` selects the JIT emit path
    /// (i32/i64/f32/f64/ref → 8-byte slot via existing
    /// `globals_base: [*]Value`; v128 → 16-byte slot via
    /// `LDR Q [X23, #off]`). Empty slices when the module has
    /// no defined globals. v128 globals as cross-module imports
    /// are out of scope this chunk (D-079 follow-up); imported
    /// global idx beyond `globals_offsets.len` falls back to
    /// the i32 emit shape with `idx*8` byte offset.
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    /// Memory 0's address-space discriminator (Wasm 3.0 §5.4.4
    /// memory64 proposal; ADR-0111 D2/D4). `.i32` for legacy
    /// (≤ 4 GiB) modules — the byte-identical fast path; `.i64`
    /// for memory64 modules — triggers the 64-bit offset
    /// materialise + wrap-check emit shape in `op_memory.zig::
    /// emitMemOp`. Multi-memory (`memories[memidx]` for memidx > 0)
    /// is rejected at runtime instantiate today; codegen only sees
    /// memory 0 per the `MemArgExtra.memidx == 0` assert.
    /// Default `.i32` keeps the 36 existing compile() call sites
    /// behaviour-preserving when they pass struct-literal default.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// ADR-0202 D4 — when true, memory0 scalar/atomic/SIMD accesses
    /// SKIP the inline `ADD/CMP/B.HI` bounds check (the guard-page
    /// reservation + fault→trap redirect own oob detection) and the
    /// kind=6 stub is force-emitted as the redirect target. Set only
    /// when memory0 qualifies (i32 × 64 KiB pages × guarded host) AND
    /// the engine knob is `.auto`. memory64 / bulk / GC-array checks
    /// are NEVER elided. Default false = explicit checks (status quo).
    bounds_elided: bool = false,
    /// Wasm 3.0 EH (ADR-0120) — per-tag index into `module_types`.
    /// `throw.emit` / `try_table.emit` marshal each payload value between
    /// the regalloc stack and the per-Runtime `eh_payload_buf` by its type
    /// (read through `tagParams`). Default-empty preserves the existing
    /// EmitCtx construction sites (entry / linker / wrapper_thunk test
    /// helpers and any pre-EH compile path).
    tag_typeidxs: []const u32 = &.{},

    /// ADR-0112 D3 — total frame size
    /// (16-byte aligned) the function's prologue allocated via
    /// `SUB SP, SP, #frame_bytes`. Consumed by `op_tail_call.zig`
    /// to drive `frame_teardown.emit(...)` ahead of the tail-jump,
    /// since the regular epilogue is bypassed for tail-call.
    /// Default 0 preserves existing EmitCtx construction sites
    /// that don't yet care (entry / linker / wrapper_thunk test
    /// helpers); compile() populates it for real bodies.
    frame_bytes: u32 = 0,

    /// ADR-0155 stage 2 (D-265 Phase IV) — the register-homing plan for this
    /// function (the SSOT shared with liveness / regalloc). `op_call` consults
    /// it to spill caller-saved homed locals around a BL/BLR. Default-empty
    /// (`count == 0`) keeps every non-homing EmitCtx construction site (test
    /// helpers, linker) on the un-homed path.
    homing: local_homing.Plan = .{},
    /// Count of temporary vregs (= `alloc.slots.len - homing.count`). The home
    /// pseudo-vreg of rank r is `n_temp + r`. Threaded so `op_call` can resolve
    /// a homed local's physical home register at the call site.
    n_temp: u32 = 0,
    /// `local_offsets[local_idx]` is the in-frame byte offset (relative to
    /// `local_base_off`) of wasm local `local_idx` — i.e. `layout.offsets`.
    /// `op_call` uses `local_base_off + local_offsets[lidx]` as the spill/reload
    /// slot address for a homed local. Empty when no homing.
    local_offsets: []const u32 = &.{},

    /// D-235 — true iff this module declares func subtyping (`sub` /
    /// `sub final` / declared super; `usesTypeSubtyping`). When true,
    /// `op_call.emitCallIndirect` replaces the inline D-111 structural sig
    /// `CMP` with a `jitCallIndirectSubtypeOk` trampoline call (the inline
    /// compare is finality/subtype-blind). Default `false` keeps every
    /// existing EmitCtx construction site (non-subtyping modules + test
    /// helpers) on the byte-identical inline path.
    uses_type_subtyping: bool = false,

    /// Pop two operands + allocate a result vreg. Shared header
    /// for every binary op-handler. Returns the lhs / rhs / result
    /// vreg ids or `AllocationMissing` (stack underflow) /
    /// `SlotOverflow` (allocator out of slots).
    /// Wasm 3.0 EH (ADR-0120) — the params of tag `tag_idx`; empty when the
    /// tag or its type index is out of range.
    pub fn tagParams(self: *const EmitCtx, tag_idx: u32) []const zir.ValType {
        if (tag_idx >= self.tag_typeidxs.len) return &.{};
        const type_idx = self.tag_typeidxs[tag_idx];
        if (type_idx >= self.module_types.len) return &.{};
        return self.module_types[type_idx].params;
    }

    pub fn popBinary(self: *EmitCtx) Error!struct { lhs: u32, rhs: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        const rhs = self.pushed_vregs.pop().?;
        const lhs = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            dbg.print(
                "codegen",
                "arm64/ctx: popBinary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .lhs = lhs, .rhs = rhs, .result = result };
    }

    /// Pop one operand + allocate a result vreg. Shared header
    /// for every unary op-handler.
    pub fn popUnary(self: *EmitCtx) Error!struct { src: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        const src = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            dbg.print(
                "codegen",
                "arm64/ctx: popUnary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .src = src, .result = result };
    }
};
