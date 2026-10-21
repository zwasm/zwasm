//! x86_64 emit pass — per-function emit context (Zone 2 backbone).
//!
//! Mirror of `arm64/ctx.zig::EmitCtx` per ADR-0075 (x86_64
//! `(ctx, ins)` shape unification): bundles the per-function state
//! that op-handler modules (`op_alu_int.zig`, `op_memory.zig`, …)
//! need so the per-arch dispatcher signature in
//! `src/engine/codegen/dispatch_collector.zig::ArchAxis = .x86_64`
//! can collapse from the current positional 7-arg form to the
//! 2-arg `(ctx: *EmitCtx, ins: *const ZirInstr)` form.
//!
//! The struct is initialised at the top of `emit.zig::compile()`.
//! `Error`, `CallFixup`, `SimdConstFixup` continue to live in
//! `types.zig` to avoid breaking external re-exports from `emit.zig`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");

const zir = @import("../../../ir/zir.zig");
const sections = @import("../../../parse/sections.zig");
const regalloc = @import("../shared/regalloc.zig");
const exception_table = @import("../shared/exception_table.zig");
const trap_registry = @import("../../../platform/trap_registry.zig"); // ADR-0202 D3
const label_mod = @import("label.zig");
const types = @import("types.zig");
const local_homing = @import("../../../ir/analysis/local_homing.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Label = label_mod.Label;

pub const Error = types.Error;
pub const CallFixup = types.CallFixup;
pub const SimdConstFixup = types.SimdConstFixup;

/// Init parameter bundle for `EmitCtx.init` — mirrors the
/// EmitCtx fields supplied by `compile()` (the `simd_consts_base`
/// + `func_idx` fields are derived inside `init` from `func`).
pub const InitArgs = struct {
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    labels: *std.ArrayList(Label),
    bounds_fixups: *std.ArrayList(u32),
    unreach_fixups: *std.ArrayList(u32),
    divzero_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    invalid_conv_fixups: *std.ArrayList(u32),
    null_ref_fixups: *std.ArrayList(u32),
    cast_fail_fixups: *std.ArrayList(u32),
    uncaught_exc_fixups: *std.ArrayList(u32),
    oob_fixups: *std.ArrayList(u32),
    oobtable_fixups: *std.ArrayList(u32),
    cind_sig_fixups: *std.ArrayList(u32),
    uninit_elem_fixups: *std.ArrayList(u32),
    /// D-303 — atomic load/store unaligned-access (code 14 = unaligned_atomic).
    unaligned_atomic_fixups: *std.ArrayList(u32),
    /// ADR-0179 #3a / D-314 — loop back-edge interrupt poll (code 16,
    /// POST-frame stub via emitTrapExitStub; the PROLOGUE poll's
    /// `interrupt_fixup` is a separate pre-frame single fixup, fb=0).
    back_edge_interrupt_fixups: *std.ArrayList(u32),
    /// ADR-0179 #3b / D-314 — see EmitCtx field of the same name.
    back_edge_fuel_fixups: *std.ArrayList(u32),
    call_fixups: *std.ArrayList(CallFixup),
    simd_const_fixups: *std.ArrayList(SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
    num_imports: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    dead_code: *bool,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    total_locals: u32,
    local_disps: []const i32,
    /// ADR-0105 D2/D3 — see EmitCtx field of the same name.
    stack_probe_fixup: u32,
    /// ADR-0179 #3a / D-314 — see EmitCtx field of the same name.
    interrupt_fixup: u32,
    /// ADR-0179 #3b / D-314 — see EmitCtx field of the same name.
    fuel_fixup: u32,
    /// ADR-0111 D4 — see EmitCtx field of the same name.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// ADR-0202 D4 — see EmitCtx field of the same name.
    bounds_elided: bool = false,
    /// EH integration — see EmitCtx field of the same name.
    /// Defaults to `null`; populated by `compile()` only when the
    /// function contains a `try_table` op.
    exception_table_builder: ?*exception_table.Builder = null,
    /// EH integration — see EmitCtx field of the same name.
    /// Non-null iff `exception_table_builder` is non-null.
    open_try_tables: ?*std.ArrayList(exception_table.OpenTryTable) = null,
    /// EH integration — see EmitCtx field of the same
    /// name. Non-null iff `exception_table_builder` is non-null.
    landing_pad_fixups: ?*std.ArrayList(exception_table.LandingPadFixup) = null,
    /// ADR-0120 — see EmitCtx
    /// field of the same name. Default-empty preserves existing
    /// InitArgs construction sites.
    tag_typeidxs: []const u32 = &.{},
    /// D-235 — see the EmitCtx field of the same name. Default `false`
    /// preserves existing InitArgs construction sites.
    uses_type_subtyping: bool = false,
    /// ADR-0155 stage 4 (D-265 Phase IV) — see the EmitCtx fields of the same
    /// names. Default-empty (`count == 0`) preserves every non-homing
    /// construction site (test helpers, linker).
    homing: local_homing.Plan = .{},
    n_temp: u32 = 0,
    local_offsets: []const i32 = &.{},
    home_save_base_disp: i32 = 0,
};

/// Per-function emit context for x86_64. Threaded as `*EmitCtx`
/// to per-op handler modules with the `(ctx, ins)` signature. All
/// mutable fields are pointers into `compile()`'s local state so
/// the legacy positional-arg handlers and the new ctx-shape
/// handlers can coexist.
pub const EmitCtx = struct {
    allocator: Allocator,
    /// Output instruction stream. Handlers append bytes via the
    /// `inst.*` encoder helpers + `buf.appendSlice(allocator, …)`.
    buf: *std.ArrayList(u8),
    /// Source ZIR function (read-only).
    func: *const ZirFunc,
    /// Register allocation for `func` (read-only).
    alloc: regalloc.Allocation,
    /// `func_sigs[k]` is the FuncType of function index `k`;
    /// consulted by `call N` to pick result reg class.
    func_sigs: []const zir.FuncType,
    /// `module_types[t]` is the FuncType for type index `t`;
    /// consulted by `call_indirect type_idx`.
    module_types: []const zir.FuncType,
    /// Operand stack of pushed vreg ids.
    pushed_vregs: *std.ArrayList(u32),
    /// Cursor for the next vreg id to allocate.
    next_vreg: *u32,
    /// Control-stack frames (block / loop / if / else).
    labels: *std.ArrayList(Label),
    /// Memory-bounds-trap fixups awaiting trap-stub emission at
    /// function-final `end`. `JAE rel32` placeholders (6 bytes:
    /// `0x0F 0x83 <disp32>`).
    bounds_fixups: *std.ArrayList(u32),
    /// `unreachable` placeholders — `JMP rel32` (5 bytes:
    /// `0xE9 <disp32>`). Distinct from `bounds_fixups` because
    /// the disp formula differs by 1 byte. Patched alongside
    /// `bounds_fixups` at function-end trap-stub block.
    unreach_fixups: *std.ArrayList(u32),
    /// ADR-0164 A2 / D-292 — div-by-zero (code 7) + div_s signed-overflow
    /// (code 8) trap fixups, demuxed out of `bounds_fixups` so each lands in
    /// a dedicated trap stub that records its precise `trap_kind`. Both are
    /// `JE rel32` (6-byte) placeholders.
    divzero_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    /// D-293 slice-3 — trapping-trunc NaN (`JP rel32`, 6-byte) fixups, demuxed
    /// out of `bounds_fixups` → code 9 = invalid_conversion. The trunc range
    /// checks reuse `overflow_fixups` (code 8).
    invalid_conv_fixups: *std.ArrayList(u32),
    /// D-293 slice-4b — call_ref-null + ref.as_non_null null-reference (`JE rel32`,
    /// 6-byte) fixups, demuxed out of `bounds_fixups` → code 10 = null_reference.
    null_ref_fixups: *std.ArrayList(u32),
    /// D-293 slice-4d — ref.cast / ref.cast_null subtype-mismatch (`JE rel32`,
    /// 6-byte, on the jitGcRefCast 0-return) fixups → code 11 = cast_failure.
    cast_fail_fixups: *std.ArrayList(u32),
    /// D-292 C — throw / throw_ref uncaught-exception (`JMP rel32`, 5-byte, after
    /// the zwasm_throw trampoline returns `.uncaught`) fixups → code 12 =
    /// uncaught_exception. Was mis-routed to `unreach_fixups` (code 5).
    uncaught_exc_fixups: *std.ArrayList(u32),
    /// ADR-0164 A3 / D-292 — memory load/store/bulk-memory out-of-bounds
    /// (`JA rel32`, 6-byte) fixups, demuxed out of `bounds_fixups` so oob_memory
    /// reaches a dedicated trap stub recording code 6. Other `bounds_fixups`
    /// kinds (ref-null / cast / array-oob) stay generic (D-293).
    oob_fixups: *std.ArrayList(u32),
    /// D-303 — atomic load/store unaligned-access (`JNE rel32`, 6-byte, on
    /// `TEST EDX, size-1`) fixups → code 14 = unaligned_atomic. The inline
    /// load/store path had no alignment check (interp-only); RMW/cmpxchg/wait/
    /// notify check it in the jit_abi helper. Mirrors arm64 unaligned_atomic_fixups.
    unaligned_atomic_fixups: *std.ArrayList(u32),
    /// ADR-0179 #3a / D-314 — loop back-edge cooperative-interruption poll
    /// (`JNE rel32`, 6-byte) fixups → code 16 = interrupted. Distinct from the
    /// PROLOGUE poll's `interrupt_fixup` (single u32, fires pre-frame, fb=0):
    /// a back-edge poll fires POST-frame, so its stub is the full
    /// emitTrapExitStub epilogue (fb-restore + homed-reg restore), same shape
    /// as oob_fixups. Mirrors arm64 back_edge_interrupt_fixups.
    back_edge_interrupt_fixups: *std.ArrayList(u32),
    /// ADR-0179 #3b / D-314 — loop back-edge fuel poll (`JS rel32`, 6-byte)
    /// fixups → code 17 = out_of_fuel. Emitted beside each back-edge
    /// interrupt poll; same POST-frame emitTrapExitStub shape. Mirrors arm64
    /// back_edge_fuel_fixups.
    back_edge_fuel_fixups: *std.ArrayList(u32),
    /// D-293 — table-access + call_indirect-bounds out-of-bounds (oob_table, code 2)
    /// fixups (`JAE rel32`, 6-byte), demuxed from `bounds_fixups` to a dedicated
    /// stub. Unifies x86_64 with arm64 (which already produces code 2 for cind).
    oobtable_fixups: *std.ArrayList(u32),
    /// D-293 slice-2 — call_indirect signature-mismatch (indirect_call_mismatch,
    /// code 3) fixups (`JNE rel32`, 6-byte), demuxed from `bounds_fixups` to a
    /// dedicated stub. Unifies x86_64 with arm64 (which already produces code 3
    /// for cind sig via `cind_sig_fixups`). Bounds (code 2) stay in `oobtable_fixups`.
    cind_sig_fixups: *std.ArrayList(u32),
    /// D-294 — call_indirect on a NULL (uninitialized) in-bounds table element
    /// (uninitialized_elem, code 13) fixups (`JE rel32`, 6-byte). A null slot's
    /// typeidx is `maxInt(u32)` (the no-func sentinel); the `CMP typeidx,
    /// 0xFFFFFFFF; JE` PRECEDES the sig CMP so null reports code 13, not the
    /// sig-mismatch code 3. Spec order: bounds → null → sig.
    uninit_elem_fixups: *std.ArrayList(u32),
    /// `CALL rel32` fixups exposed via `EmitOutput` for the
    /// post-emit linker.
    call_fixups: *std.ArrayList(CallFixup),
    /// SIMD const-pool fixups (per ADR-0042; mirror of arm64's
    /// `simd_const_fixups`). Each entry records a MOVUPS-RIP-rel
    /// placeholder's disp32 byte offset + post-instruction byte
    /// + flat const_idx. Patched at function close after both
    /// `func.simd_consts` (lower-time literals) and
    /// `extra_consts` (emit-time derived) are appended past the
    /// trap stub (16-byte aligned).
    simd_const_fixups: *std.ArrayList(SimdConstFixup),
    /// Emit-time-derived 16-byte SIMD constants discovered by
    /// per-op handlers (per ADR-0051; popcnt LUTs, broadcast
    /// masks, per-shape magic constants). Appended to the flat
    /// const-pool *after* lower-time entries at function close.
    extra_consts: *std.ArrayList([16]u8),
    /// Number of lower-time entries in the flat const-pool.
    /// Equals `func.simd_consts.?.len` when non-null, 0 otherwise.
    /// Handlers compute the global const_idx as `simd_consts_base
    /// + position-in-extra_consts`.
    simd_consts_base: u32,
    /// Absolute SP-relative byte offset of spill slot 0. Equals
    /// `locals_bytes + r15_save_bytes + 8`; the +8 puts spill
    /// slot 0 in the next 8-byte cell below the deepest local.
    /// `gpr.zig`'s `rbpDispNegI8` consumes it as `disp =
    /// -(spill_base_off + spill_off)`.
    spill_base_off: u32,
    /// Outgoing-args region pre-allocated at the
    /// BOTTOM of the frame. For SysV: pure overflow bytes; for
    /// Win64: includes the 32-byte shadow space when any call
    /// exists. Consumed by `op_call.emitCall` to decide whether
    /// the per-call `emitShadowAlloc` / `Free` are no-ops.
    outgoing_max_bytes: u32,
    /// True iff this function's return tuple is MEMORY-class per
    /// SysV §3.2.3 (v2 trigger: `sig.results.len > 2` under SysV;
    /// Win64 MEMORY-class deferred).
    return_is_memory_class: bool,
    /// RBP-negative byte offset (= absolute value) of the
    /// captured-RDI slot when `return_is_memory_class` is true;
    /// meaningless otherwise. Slot sits below the spill region.
    /// `compile()` stores RDI at `[RBP - indirect_result_slot_neg_off]`
    /// after the SUB-RSP prologue.
    indirect_result_slot_neg_off: u32,
    /// Leading wasm-space function indices that name imports.
    /// `op_call.emitCall` checks `callee_idx < num_imports` to
    /// switch between host-import dispatch and a normal
    /// `CALL rel32 + CallFixup`.
    num_imports: u32,
    /// Per-function EH handler-entry accumulator.
    /// `op_exception_handling.try_table` appends one `HandlerEntry`
    /// per catch clause (per ADR-0114 D2); the post-emit linker
    /// finalises into the per-Instance ExceptionTable consumed by
    /// the FP-walk unwinder. Optional: null for functions that
    /// contain no try_table (back-compat for every existing
    /// EmitCtx construction site).
    exception_table_builder: ?*exception_table.Builder = null,
    /// See arm64/ctx.zig field of the same name.
    open_try_tables: ?*std.ArrayList(exception_table.OpenTryTable) = null,
    /// See arm64/ctx.zig field.
    landing_pad_fixups: ?*std.ArrayList(exception_table.LandingPadFixup) = null,
    /// Per-defined-global metadata (ADR-0052).
    /// Indexed by **defined** global idx (= wasm-space global
    /// idx minus the leading imported-global count). Parallel
    /// arrays: `globals_offsets[i]` is the byte offset of
    /// global i inside the runtime's globals byte buffer;
    /// `globals_valtypes[i]` selects the emit path
    /// (i32/i64/f32/f64/ref → 8-byte slot; v128 → 16-byte slot).
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    /// Cached `func.func_idx`. Consumed by trace.writeBounds /
    /// trace.writeCallTrap and the per-arch trap-stub epilogue.
    func_idx: u32,
    /// Pointer to compile()'s dead_code local.
    /// Set true by `unreachable` (and select arm) to skip
    /// emitting until the next control-flow boundary resets it.
    dead_code: *bool,
    /// Per-function frame size in bytes (set once
    /// at function entry; consumed by return + br family for
    /// `ADD RSP, frame_bytes` in the epilogue).
    frame_bytes: u32,
    /// Whether the function reserves R15 for the
    /// runtime_ptr_save (set once at function entry; consumed by
    /// the epilogue to decide POP R15).
    uses_runtime_ptr: bool,
    /// Total local count (= num_params +
    /// num_declared_locals). Set once at function entry;
    /// consumed by emitLocalGet/Set/Tee for the bound check.
    total_locals: u32,
    /// Per-local RBP-relative disps. Set once at
    /// function entry from `layout.disps`; consumed by
    /// emitLocalGet/Set/Tee.
    local_disps: []const i32,
    /// ADR-0105 D2/D3 — byte offset of the JIT-prologue stack-probe's
    /// `JBE rel32` placeholder. `0` = probe not emitted (no
    /// uses_runtime_ptr → function cannot recurse → no probe needed).
    /// When non-zero, the function-end handler in op_control.zig
    /// emits a dedicated stack-overflow trap stub with fb=0 (probe
    /// fires BEFORE the SUB RSP) and patches this fixup to its
    /// disp32.
    stack_probe_fixup: u32,
    /// ADR-0179 #3a / D-314 — when non-zero, op_control.zig emits a
    /// dedicated interrupted trap stub (kind 16, fb=0; the poll fires
    /// BEFORE the SUB RSP, same as the probe) and patches this JNE fixup.
    interrupt_fixup: u32,
    /// ADR-0179 #3b / D-314 — when non-zero, op_control.zig emits a
    /// dedicated out-of-fuel trap stub (kind 17, fb=0 pre-frame) and
    /// patches this JS fixup (the prologue fuel poll).
    fuel_fixup: u32,
    /// ADR-0202 D3 — OUTPUT: byte offset (from body start) of the
    /// kind=6 oob trap stub, the guard-fault PC-redirect target. Set
    /// by `emitEndInter` when the stub is emitted; read back by
    /// `emit.zig` into `EmitOutput.oob_stub_off`. `no_stub` when the
    /// function has no bounds-checked memory access.
    oob_stub_off: u32 = trap_registry.FuncEntry.no_stub,
    /// ADR-0111 D4 — memory 0's idx_type. `.i32` (legacy ≤ 4 GiB;
    /// byte-identical fast path) or `.i64` (memory64 64-bit MOV
    /// + u64 offset materialise). Per-module constant; codegen
    /// branches on it at emitMemOp's entry. Default `.i32` keeps
    /// existing init args ergonomic.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// ADR-0202 D4 — drop the inline memory0 scalar bounds check
    /// (guard-page + fault→trap redirect own oob detection); the
    /// kind=6 stub is force-emitted as the redirect target. Set only
    /// for qualifying modules under the `.auto` knob. Default false.
    bounds_elided: bool = false,
    /// ADR-0120 — per-tag index into `module_types`, for `throw.emit` /
    /// `try_table.emit` payload-marshalling (read through `tagParams`).
    /// Default-empty preserves existing EmitCtx construction sites.
    tag_typeidxs: []const u32 = &.{},
    /// D-235 — true iff this module declares func subtyping. When true,
    /// `op_call.emitCallIndirect` replaces the inline D-111 structural sig
    /// `CMP` with a `jitCallIndirectSubtypeOk` trampoline call. Default
    /// `false` keeps non-subtyping modules + test helpers on the
    /// byte-identical inline path.
    uses_type_subtyping: bool = false,

    /// ADR-0155 stage 4 (D-265 Phase IV) — the register-homing plan for this
    /// function (the SSOT shared with liveness / regalloc). `op_locals` consults
    /// it: a homed `local.get` reads the home register (no LOAD), a homed
    /// `local.set`/`tee` MOVs into the home register (no STORE). Default-empty
    /// (`count == 0`) keeps every non-homing EmitCtx construction site (test
    /// helpers, linker) on the un-homed slot path.
    homing: local_homing.Plan = .{},
    /// Count of temporary vregs (= `alloc.slots.len - homing.count`). The home
    /// pseudo-vreg of rank r is `n_temp + r`. Threaded so `op_locals` / `op_call`
    /// resolve a homed local's physical home register.
    n_temp: u32 = 0,
    /// `local_offsets[local_idx]` is the in-frame RBP-relative disp of wasm
    /// local `local_idx` — i.e. `layout.disps` (already negative on x86_64).
    /// `op_call` uses it for a homed local's call-site spill slot. Empty when
    /// no homing.
    local_offsets: []const i32 = &.{},
    /// ADR-0155 stage 4 — RBP-relative disp of the rank-0 callee-saved home save
    /// slot; rank j sits at `home_save_base_disp - j*8`. The prologue snapshots
    /// each register-resident home reg's incoming (caller) value here, and every
    /// return path restores it (callee-saved ABI contract). `0` when no homing.
    home_save_base_disp: i32 = 0,

    /// Wasm 3.0 EH (ADR-0120) — the params of tag `tag_idx`; empty when the
    /// tag or its type index is out of range.
    pub fn tagParams(self: *const EmitCtx, tag_idx: u32) []const zir.ValType {
        if (tag_idx >= self.tag_typeidxs.len) return &.{};
        const type_idx = self.tag_typeidxs[tag_idx];
        if (type_idx >= self.module_types.len) return &.{};
        return self.module_types[type_idx].params;
    }

    pub fn init(args: InitArgs) EmitCtx {
        const simd_consts_base: u32 =
            if (args.func.simd_consts) |sc| @intCast(sc.len) else 0;
        return .{
            .allocator = args.allocator,
            .buf = args.buf,
            .func = args.func,
            .alloc = args.alloc,
            .func_sigs = args.func_sigs,
            .module_types = args.module_types,
            .pushed_vregs = args.pushed_vregs,
            .next_vreg = args.next_vreg,
            .labels = args.labels,
            .bounds_fixups = args.bounds_fixups,
            .unreach_fixups = args.unreach_fixups,
            .divzero_fixups = args.divzero_fixups,
            .overflow_fixups = args.overflow_fixups,
            .invalid_conv_fixups = args.invalid_conv_fixups,
            .null_ref_fixups = args.null_ref_fixups,
            .cast_fail_fixups = args.cast_fail_fixups,
            .uncaught_exc_fixups = args.uncaught_exc_fixups,
            .oob_fixups = args.oob_fixups,
            .bounds_elided = args.bounds_elided,
            .unaligned_atomic_fixups = args.unaligned_atomic_fixups,
            .back_edge_interrupt_fixups = args.back_edge_interrupt_fixups,
            .back_edge_fuel_fixups = args.back_edge_fuel_fixups,
            .oobtable_fixups = args.oobtable_fixups,
            .cind_sig_fixups = args.cind_sig_fixups,
            .uninit_elem_fixups = args.uninit_elem_fixups,
            .call_fixups = args.call_fixups,
            .simd_const_fixups = args.simd_const_fixups,
            .extra_consts = args.extra_consts,
            .simd_consts_base = simd_consts_base,
            .spill_base_off = args.spill_base_off,
            .outgoing_max_bytes = args.outgoing_max_bytes,
            .return_is_memory_class = args.return_is_memory_class,
            .indirect_result_slot_neg_off = args.indirect_result_slot_neg_off,
            .num_imports = args.num_imports,
            .globals_offsets = args.globals_offsets,
            .globals_valtypes = args.globals_valtypes,
            .func_idx = args.func.func_idx,
            .dead_code = args.dead_code,
            .frame_bytes = args.frame_bytes,
            .uses_runtime_ptr = args.uses_runtime_ptr,
            .total_locals = args.total_locals,
            .local_disps = args.local_disps,
            .stack_probe_fixup = args.stack_probe_fixup,
            .interrupt_fixup = args.interrupt_fixup,
            .fuel_fixup = args.fuel_fixup,
            .memory0_idx_type = args.memory0_idx_type,
            .exception_table_builder = args.exception_table_builder,
            .open_try_tables = args.open_try_tables,
            .landing_pad_fixups = args.landing_pad_fixups,
            .tag_typeidxs = args.tag_typeidxs,
            .uses_type_subtyping = args.uses_type_subtyping,
            .homing = args.homing,
            .n_temp = args.n_temp,
            .local_offsets = args.local_offsets,
            .home_save_base_disp = args.home_save_base_disp,
        };
    }

    /// Pop two operands + allocate a result vreg. Shared header
    /// for every binary op-handler.
    pub fn popBinary(self: *EmitCtx) Error!struct { lhs: u32, rhs: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        const rhs = self.pushed_vregs.pop().?;
        const lhs = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            dbg.print(
                "codegen",
                "x86_64/ctx: popBinary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .lhs = lhs, .rhs = rhs, .result = result };
    }

    /// Pop one operand + allocate a result vreg.
    pub fn popUnary(self: *EmitCtx) Error!struct { src: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        const src = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            dbg.print(
                "codegen",
                "x86_64/ctx: popUnary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .src = src, .result = result };
    }
};
