//! ARM64 emit pass — `table.get` / `table.set` / `table.size`
//! handlers (per ADR-0058).
//!
//! Each declared table has a `TableSlice` descriptor in the JIT
//! runtime's `tables_ptr` array (stride `jit_abi.table_slice_size`
//! bytes — 16 per ADR-0058, then 24 after ADR-0068's dual-view
//! `funcptrs: [*]u64` extension);
//! the JIT body loads `refs` + `len` from the indexed descriptor
//! then performs a bounds-checked load/store against
//! `refs[idx]` (8-byte ref slot).
//!
//! Per-op shape (Wasm spec §4.4.10–12):
//!
//!   table.get x:
//!     LDR  X10, [X19, #tables_ptr_off]        ; tables_ptr
//!     LDR  X11, [X10, #(tableidx*32)]         ; refs ptr
//!     LDR  X12, [X10, #(tableidx*32)+8]       ; len (u64, D-475)
//!     ORR  W17, WZR, W_idx                    ; zero-ext idx into ip1
//!     CMP  X17, X12                           ; idx vs len (X-width)
//!     B.HS trap_stub                          ; bounds_fixups
//!     LDR  Xresult, [X11, X17, LSL #3]        ; refs[idx]
//!     (store back to spill slot if needed)
//!
//!   table.set x:
//!     (same prologue + bounds check)
//!     STR  Xval, [X11, X17, LSL #3]
//!
//!   table.size x:
//!     LDR  X14, [X19, #tables_ptr_off]
//!     LDR  X_result, [X14, #(tableidx*32)+8]  ; push len
//!
//! Intra-op scratch convention (D-132/D-133): table.get /
//! table.set / table.size use X14
//! (= `abi.spill_stage_gprs[0]`, non-allocatable) for the
//! `tables_ptr` pre-load so a live-across-op vreg cannot be
//! silently clobbered. The remaining op_table sites
//! (emitTableFill / emitTableGrow / emitTableCopy / emitTableInit)
//! still hardcode X10/X11/X12 — those need >2 scratch slots and
//! are queued for a unified comptime-disjointness mechanism.
//! X17 remains the
//! bounds-check scratch (already disjoint from regalloc pool
//! per the ip_gprs reservation).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const trace = @import("../../../diagnostic/trace.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const func_mod = @import("../../../runtime/instance/func.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

// ADR-0077 — op-internal scratch slot bindings used by the 5 D-133
// bulk handlers (emitTableFill / emitTableCopy / emitTableInit + the
// emitMemoryInit mirror in op_memory.zig). Regalloc guarantees these
// slots are free for vregs whose live range crosses the op's PC —
// see arm64/abi.zig::op_scratch_reservation_table. The handler bodies
// reference `sx9..sx13` instead of magic numerals so
// `check_invariant_comments.sh` no longer counts them as latent
// D-133-class overlap sites. Per-handler role docs live in the
// handler's own prose (the roles differ across handlers; the
// constants only document the pool membership).
const sx9: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[0];
const sx10: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[1];
const sx11: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[2];
const sx12: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[3];
const sx13: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[4];

/// TODO: table storage shape — see D-126 / ADR-0068.
/// Emit the "derive funcptr from funcref value with null check"
/// sequence. Result lands in `dst_reg`; `val_reg` is the
/// FuncEntity pointer (Value.null_ref == 0 for null funcref).
/// Used by emitTableSet / emitTableFill / emitTableInit per
/// ADR-0068 §A1 single-site discipline.
///
///   CBZ Xval, .null
///   LDR Xdst, [Xval, #funcentity_funcptr_offset]
///   B .end
///   .null: MOVZ Xdst, #0
///   .end:
fn emitDeriveFuncptrFromFuncref(
    ctx: *EmitCtx,
    dst_reg: inst.Xn,
    val_reg: inst.Xn,
) Error!void {
    const cbz_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(val_reg, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(dst_reg, val_reg, @intCast(func_mod.funcentity_funcptr_offset)));
    const b_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    const null_arm: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(dst_reg, 0));
    const end_byte: u32 = @intCast(ctx.buf.items.len);

    const cbz_disp = @divExact(@as(i32, @intCast(null_arm)) - @as(i32, @intCast(cbz_at)), 4);
    std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbz(val_reg, cbz_disp), .little);
    const b_disp = @divExact(@as(i32, @intCast(end_byte)) - @as(i32, @intCast(b_at)), 4);
    std.mem.writeInt(u32, ctx.buf.items[b_at..][0..4], inst.encB(b_disp), .little);
}

/// TODO: table storage shape — see D-126 / ADR-0068.
/// Derive typeidx (u32) from FuncEntity ptr; null-funcref → sentinel
/// `maxInt(u32)` (the JIT sig-check's never-matches value).
///
///   CBZ Xval, .null
///   LDR Wdst, [Xval, #funcentity_typeidx_offset]
///   B .end
///   .null: MOVN Wdst, #0   ; = 0xFFFFFFFF sentinel
///   .end:
fn emitDeriveTypeidxFromFuncref(
    ctx: *EmitCtx,
    dst_w: inst.Xn,
    val_reg: inst.Xn,
) Error!void {
    const cbz_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(val_reg, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(dst_w, val_reg, @intCast(func_mod.funcentity_typeidx_offset)));
    const b_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    const null_arm: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovnImmW(dst_w, 0));
    const end_byte: u32 = @intCast(ctx.buf.items.len);

    const cbz_disp = @divExact(@as(i32, @intCast(null_arm)) - @as(i32, @intCast(cbz_at)), 4);
    std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbz(val_reg, cbz_disp), .little);
    const b_disp = @divExact(@as(i32, @intCast(end_byte)) - @as(i32, @intCast(b_at)), 4);
    std.mem.writeInt(u32, ctx.buf.items[b_at..][0..4], inst.encB(b_disp), .little);
}

/// Wasm spec §4.4.10 (table.get) — pop i32 idx, push tables[x][idx]
/// as a reference Value (8-byte). Traps `OutOfBoundsTableAccess` on
/// idx >= table.len via the shared `bounds_fixups` channel.
///
/// Operand capture happens BEFORE the X10/X11/X12 LDR sequence
/// because the regalloc may have parked the operand vreg in
/// X9..X13 — clobbering it without snapshotting first would lose
/// the operand's value (silent miscompile mirror of the m-5 trap-
/// stub R15 prescan bug).
pub fn emitTableGet(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx: u32 = @intCast(ins.payload);
    // TODO: table storage shape — see D-126 / ADR-0068.
    // imm12 budget with stride 32 (D-475 u64 len/max): X-form
    // descriptor loads (byte_off ≤ 32760, scaled by 8) cap tableidx
    // at (32760-24)/32 = 1023. Cap 512 keeps comfortable margin
    // while remaining far above any realistic module's table count.
    if (tableidx >= 512) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * jit_abi.table_slice_size);

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot idx into W17/X17 (intra-procedure scratch, never
    // in the regalloc pool). D-475: an i64 table pops a full 64-bit
    // index (X-form ORR); an i32 table keeps the zero-extending W-form.
    const idx64 = ctx.func.tableIdxType(tableidx) == .i64;
    const w_idx_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(17, 31, w_idx_src) else inst.encOrrRegW(17, 31, w_idx_src));

    // Step B: read TableSlice[tableidx]. Use X14 / X15 (spill-
    // stage regs, non-allocatable) as scratch — they are free
    // after Step A's load completed. D-132: an earlier
    // revision used X10 / X11 / X12 which are in
    // `allocatable_caller_saved_scratch_gprs`, so vregs landed
    // on those slots got silently clobbered when their live
    // range crossed a table.get / table.set. The fix re-targets
    // the intra-op scratch to the non-allocatable pool.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 14, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_len_off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, 14, tbl_off));

    // Step C: CMP X17, X15 ; B.HS trap. X-width (D-475): len is u64.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 15));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D: allocate the result vreg and load.
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const xd = try gpr.gprDefSpilled(ctx.alloc, result, 0);

    // LDR Xd, [X14, X17, LSL #3] — X14 now holds refs ptr.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(xd, 14, 17));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Wasm spec §4.4.11 (table.set) — pop reftype value then i32 idx,
/// write `tables[x][idx] = val`. Traps `OutOfBoundsTableAccess` on
/// idx >= table.len.
pub fn emitTableSet(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx: u32 = @intCast(ins.payload);
    if (tableidx >= 512) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * jit_abi.table_slice_size);

    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const val_v = ctx.pushed_vregs.pop().?;
    const idx_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands into intra-procedure scratch
    // (X16/X17, never in the regalloc pool). idx → W17 (X17 for an
    // i64 table, D-475); val → X16 (full 64-bit ref).
    const idx64 = ctx.func.tableIdxType(tableidx) == .i64;
    const w_idx_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(17, 31, w_idx_src) else inst.encOrrRegW(17, 31, w_idx_src));
    const x_val_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(16, 31, x_val_src));

    // Step B: read TableSlice[tableidx]. D-132: use X14 / X15
    // (spill-stage regs, non-allocatable)
    // as scratch — an earlier revision used X10 / X11 / X12 which collide
    // with the regalloc pool, silently clobbering vregs whose
    // live range crossed the op. See emitTableGet for the
    // detailed rationale.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 14, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_len_off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, 14, tbl_off));

    // Step C: CMP X17, X15 ; B.HS trap. X-width (D-475): len is u64.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 15));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D: STR X16 (val), [X14 + X17 * 8] — write refs[idx].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(16, 14, 17));

    // TODO: table storage shape — see D-126 / ADR-0068.
    // Mirror funcptrs + typeidx views. Load funcptrs base into X14
    // first; externref tables carry a null funcptrs base (setup
    // discipline), so CBZ skips both mirrors. For funcref tables,
    // derive funcptr/typeidx from val (X16) and STR to both views.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, 14, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_funcptrs_off)));
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(14, 0));
    try emitDeriveFuncptrFromFuncref(ctx, 15, 16);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 14, 17));
    // typeidx mirror: reuse X14 / X15.
    try emitDeriveTypeidxFromFuncref(ctx, 15, 16);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, 14, @intCast(@as(u32, tableidx) * jit_abi.table_jit_ci_size + 8)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrWRegLsl2(15, 14, 17));
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp = @divExact(@as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)), 4);
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], inst.encCbz(14, skip_disp), .little);
}

/// Wasm spec §4.4.12 (table.size) — push current `tables[x].len`
/// as i32. No trap conditions; the validator already rejected
/// out-of-range tableidx.
///
/// Scratch register choice (D-133 partial): use X14
/// (= `abi.spill_stage_gprs[0]`, non-
/// allocatable) for the `tables_ptr` load rather than X10. X10
/// is in `abi.allocatable_caller_saved_scratch_gprs`, so a
/// live-across-`table.size` vreg landing on X10 would be
/// silently clobbered by the pre-load. The bug is latent on
/// the current corpus (no trigger pattern observed) but shares
/// the failure mode surfaced for `emitTableGet` /
/// `emitTableSet` via the `funcref_roundtrip` reproducer.
pub fn emitTableSize(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx: u32 = @intCast(ins.payload);
    if (tableidx >= 512) return Error.UnsupportedOp;
    const len_off: u15 = @intCast(@as(u32, tableidx) * jit_abi.table_slice_size + jit_abi.tableslice_len_off);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(14, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const wd = try gpr.gprDefSpilled(ctx.alloc, result, 0);

    // X-form load (D-475: len is u64). For an i32 table len < 2^32,
    // so the value matches the old W-load zero-extension; an i64
    // table pushes the full u64 size.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(wd, 14, len_off));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Wasm spec §4.4.13 (table.grow x) — pop n:i32, init:reftype;
/// push i32 (previous size on success, -1 on failure).
/// D-122/D-125 (mirror of ADR-0059):
/// indirect call through `JitRuntime.table_grow_fn` with AAPCS64
/// args:
///   X0 = runtime_ptr (= X19),
///   W1 = tableidx (immediate),
///   X2 = init reftype value (8-byte raw bits),
///   W3 = delta entries.
/// BLR clobbers all caller-saved regs; AAPCS64 preserves
/// X19..X28 so the cached prologue invariants (X28 vm_base,
/// X27 mem_limit) survive even though the callout did not
/// touch linear memory.
pub fn emitTableGrow(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx: u32 = @intCast(ins.payload);
    if (tableidx >= 512) return Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const delta_v = ctx.pushed_vregs.pop().?;
    const init_v = ctx.pushed_vregs.pop().?;

    // Stage operands into AAPCS64 arg slots BEFORE clobbering X0/X1
    // with marshaling MOVs. Use ORR-ZR (alias for MOV) so partial
    // and full-width transfers share the same encoder. D-475: an i64
    // table's delta is a full u64 (X3); i32 keeps the zero-extending
    // W-form (the callback takes u64, so W-staging is transparent).
    const idx64 = ctx.func.tableIdxType(tableidx) == .i64;
    const w_delta_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, delta_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(3, 31, w_delta_src) else inst.encOrrRegW(3, 31, w_delta_src));
    const x_init_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, init_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(2, 31, x_init_src));

    // W1 = tableidx (16-bit MOVZ covers tableidx < 1024).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(tableidx)));
    // X0 = runtime_ptr.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    // LDR X16, [X19, #table_grow_fn_off]; BLR X16.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.table_grow_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));

    // Capture W0/X0 → result vreg (mirror op_call captureCallResult).
    // D-475: an i64 table's grow result is a full i64 (X-form ORR);
    // the callback returns i64, so the i32 W-capture truncates -1 /
    // the sub-2^32 old size to the correct i32 bit pattern.
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    switch (ctx.alloc.slot(result, .gpr)) {
        .reg => |id| {
            const wd = abi.slotToReg(id) orelse return Error.SlotOverflow;
            if (wd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(wd, 31, 0) else inst.encOrrRegW(wd, 31, 0));
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            // X-form store for an i64 table (D-475): a W-store would
            // leave stale upper bits in the slot, which the X-form
            // spill reload of an i64 result then picks up (the -1
            // failure sentinel becomes garbage). i32 keeps the W-store.
            try gpr.frameStrGpr(ctx.allocator, ctx.buf, 0, abs_off, !idx64, abi.spill_stage_gprs[0]);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);

    // D-497 (ADR-0201): a grow of table 0 changes the entry count cached in the
    // X25 reserved reg (call_indirect's table-0 bounds check reads X25, not the
    // fresh TableSlice.len). X25 is callee-saved, so it survives the BLR with the
    // STALE pre-grow value; reload it so a grown slot is reachable from a
    // call_indirect later in THIS function. Cross-function calls re-establish X25
    // at the callee prologue; x86_64 reads rt.table_size fresh from R15 each time,
    // so this reload is arm64-only.
    if (tableidx == 0)
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(25, abi.runtime_ptr_save_gpr, jit_abi.table_size_off));
}

/// Wasm spec §4.4.14 (table.fill x) — pop n (i32), val (reftype),
/// dst (i32); write `n` copies of `val` into `tables[x][dst..dst+n]`.
/// Traps `OutOfBoundsTableAccess` if `dst+n > tables[x].len`.
///
/// Operand-capture discipline (per ADR-0058 §"Operand-capture"):
/// snapshot all three operands into intra-procedure scratch
/// (W17 = dst, X16 = val, W14 = n) BEFORE touching X10/X11/X12 for
/// the TableSlice prologue load. Skipping this surfaces as silent
/// miscompile (m-2a class bug).
pub fn emitTableFill(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx: u32 = @intCast(ins.payload);
    if (tableidx >= 512) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * jit_abi.table_slice_size);

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const val_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands into private holders.
    //   W17/X17 ← dst (zero-ext from i32 home; full X for an i64 table, D-475)
    //   X16     ← val (full 64-bit ref)
    //   W14/X14 ← n   (same width rule as dst; used as loop counter)
    const idx64 = ctx.func.tableIdxType(tableidx) == .i64;
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(17, 31, w_dst_src) else inst.encOrrRegW(17, 31, w_dst_src));
    const x_val_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(16, 31, x_val_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(14, 31, w_n_src) else inst.encOrrRegW(14, 31, w_n_src));

    // Step B: read TableSlice[tableidx]. Safe to clobber X10..X12.
    //   X10 = tables_ptr; X11 = refs; X12 = len (u64, D-475); X9 = funcptrs base.
    // TODO: table storage shape — see D-126 / ADR-0068.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx11, 10, tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx12, 10, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_len_off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx9, 10, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_funcptrs_off)));

    // Step C: bounds check — trap if dst + n > len.
    //   X13 = X17 + X14  (i32 table: both upper-bits zero → fits u33,
    //   plain ADD; i64 table: raw u64 operands can wrap past 2^64, so
    //   ADDS + B.HS traps the wrap — the memory64 ea+size pattern.)
    //   CMP X13, X12
    //   B.HI trap
    if (idx64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddsReg(sx13, 17, 14));
        const wrap_fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, wrap_fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, wrap_fixup_at);
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(sx13, 17, 14));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(sx13, 12));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Pre-loop derive funcptr + typeidx from val (X16). X15 =
    // derived funcptr; W13 = derived typeidx; X10 = typeidx_base
    // for this table. Guarded by CBZ X9 — externref tables carry
    // a null funcptrs base so we skip both mirrors. Placed AFTER
    // bounds check so X13 (the bounds scratch) is free.
    const skip_setup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(sx9, 0));
    try emitDeriveFuncptrFromFuncref(ctx, 15, 16);
    try emitDeriveTypeidxFromFuncref(ctx, 13, 16);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, 10, @intCast(@as(u32, tableidx) * jit_abi.table_jit_ci_size + 8)));
    {
        const after_setup: u32 = @intCast(ctx.buf.items.len);
        const disp = @divExact(@as(i32, @intCast(after_setup)) - @as(i32, @intCast(skip_setup_at)), 4);
        std.mem.writeInt(u32, ctx.buf.items[skip_setup_at..][0..4], inst.encCbz(sx9, disp), .little);
    }

    // Step D: if n == 0, skip the loop entirely. X-width test for an
    // i64 table (W-CBZ would read only the low 32 bits of n).
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encCbz(14, 0) else inst.encCbzW(14, 0));

    // Step E: forward loop. Each iteration:
    //   STR X16, [X11, X17, LSL #3]   ; refs[dst] = val
    //   CBZ X9, .skip_fp              ; externref → skip funcptrs mirror
    //   STR X15, [X9, X17, LSL #3]    ; funcptrs[dst] = derived  (ADR-0068)
    //   .skip_fp:
    //   ADD X17, X17, #1              ; (X-form; upper bits stay zero for i32)
    //   SUB X14, X14, #1
    //   CBNZ W14, .loop               ; (X-form for an i64 table)
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(16, 11, 17));
    const fill_skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(sx9, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 9, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrWRegLsl2(sx13, 10, 17));
    {
        const after_skip: u32 = @intCast(ctx.buf.items.len);
        const disp = @divExact(@as(i32, @intCast(after_skip)) - @as(i32, @intCast(fill_skip_at)), 4);
        std.mem.writeInt(u32, ctx.buf.items[fill_skip_at..][0..4], inst.encCbz(sx9, disp), .little);
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const back_disp_words: i32 = @divExact(
        @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encCbnz(14, back_disp_words) else inst.encCbnzW(14, back_disp_words));

    // Step F: patch the n==0 skip target.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp_words: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], if (idx64) inst.encCbz(14, skip_disp_words) else inst.encCbzW(14, skip_disp_words), .little);
}

/// Wasm spec §4.4.15 (table.copy x y) — pop n / src / dst; copy n
/// reftype values from tables[y][src..src+n] into
/// tables[x][dst..dst+n]. Traps `OutOfBoundsTableAccess` if either
/// `dst+n > tables[x].len` or `src+n > tables[y].len`. memmove
/// semantics on overlap (only matters when x == y).
///
/// Encoding: ins.payload = dst-tableidx (x); ins.extra = src-tableidx (y).
///
/// Holder regs after Step A:
///   W17 = dst_idx, W16 = src_idx, W14 = n (counter).
///
/// Scratch reused across the handler:
///   X10 = tables_ptr (transient)
///   X11 = dst_refs  (long-lived for the copy loop)
///   X12 = src_refs  (long-lived; loaded after dst bounds check)
///   W13 = dst_len / src_len (transient, reused per bounds check)
///   X15 = ref scratch (per-iter LDR target → STR source)
pub fn emitTableCopy(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const dst_tbl: u32 = @intCast(ins.payload);
    const src_tbl = ins.extra;
    if (dst_tbl >= 512 or src_tbl >= 512) return Error.UnsupportedOp;
    const dst_tbl_off: u15 = @intCast(@as(u32, dst_tbl) * jit_abi.table_slice_size);
    const src_tbl_off: u15 = @intCast(@as(u32, src_tbl) * jit_abi.table_slice_size);
    const same_table = (dst_tbl == src_tbl);

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands into private holders. D-475 widths per
    // table (validator §3.3.6 table64): dst uses the DST table's
    // idx_type, src the SRC table's, n the narrower of the two.
    const dst64 = ctx.func.tableIdxType(dst_tbl) == .i64;
    const src64 = ctx.func.tableIdxType(src_tbl) == .i64;
    const n64 = dst64 and src64;
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (dst64) inst.encOrrReg(17, 31, w_dst_src) else inst.encOrrRegW(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (src64) inst.encOrrReg(16, 31, w_src_src) else inst.encOrrRegW(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (n64) inst.encOrrReg(14, 31, w_n_src) else inst.encOrrRegW(14, 31, w_n_src));

    // Step B: load tables_ptr → X10.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));

    // Step C1: bounds check dst_idx + n vs tables[x].len. A 64-bit dst
    // can wrap the sum → ADDS + B.HS (memory64 pattern); i32 keeps the
    // plain ADD (operands zero-extended, sum fits u33).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx11, 10, dst_tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx13, 10, @intCast(@as(u32, dst_tbl_off) + jit_abi.tableslice_len_off)));
    if (dst64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddsReg(15, 17, 14));
        const wrap_fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, wrap_fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, wrap_fixup_at);
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 17, 14));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 13));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step C2: bounds check src_idx + n vs tables[y].len (same wrap rule).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx12, 10, src_tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx13, 10, @intCast(@as(u32, src_tbl_off) + jit_abi.tableslice_len_off)));
    if (src64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddsReg(15, 16, 14));
        const wrap_fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, wrap_fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, wrap_fixup_at);
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 16, 14));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 13));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // TODO: table storage shape — see D-126 / ADR-0068.
    // Load dst/src funcptrs base addresses for the mirror per-iter
    // writes. X9 = dst_funcptrs, X13 = src_funcptrs. Both alive
    // through the loop (W13 was bounds-scratch — last use was the
    // CMP above; X10 still holds tables_ptr).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx9, 10, @intCast(@as(u32, dst_tbl_off) + jit_abi.tableslice_funcptrs_off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx13, 10, @intCast(@as(u32, src_tbl_off) + jit_abi.tableslice_funcptrs_off)));

    // Also mirror the typeidx view (TableJitCallInfo stride 16,
    // typeidx_base at offset 8). Cross-table copy MUST update the
    // destination's typeidx_base or call_indirect's sig check
    // sees a stale (or sentinel) typeidx — `copy_cross_table`
    // contract fixture surfaces this. X8 = dst_typeidx_base,
    // X7 = src_typeidx_base; X10 transiently reused for
    // tables_jit_ci_ptr.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(8, 10, @intCast(@as(u32, dst_tbl) * jit_abi.table_jit_ci_size + 8)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(7, 10, @intCast(@as(u32, src_tbl) * jit_abi.table_jit_ci_size + 8)));

    // Step D: if n == 0, skip the loop entirely (X-width for i64-n).
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (n64) inst.encCbz(14, 0) else inst.encCbzW(14, 0));

    if (same_table) {
        // Step E (same-table): direction switch. Same table → same
        // idx_type, so the compare width follows dst64.
        //   CMP W17, W16 ; B.LS .fwd  (dst <= src → forward safe)
        try gpr.writeU32(ctx.allocator, ctx.buf, if (dst64) inst.encCmpRegX(17, 16) else inst.encCmpRegW(17, 16));
        const fwd_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ls, 0));

        // .bwd: pre-advance both indices by n (W17 += W14; W16 += W14),
        // then loop with pre-decrement of indices.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 17, 14));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 16, 14));
        const bwd_loop_start: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
        // Mirror funcptrs + typeidx (ADR-0068) — guarded on X9 != 0
        // (externref tables have null funcptrs_base, skip both views).
        const bwd_skip_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(sx9, 0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 13, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 9, 17));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(15, 7, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrWRegLsl2(15, 8, 17));
        {
            const after_skip: u32 = @intCast(ctx.buf.items.len);
            const disp = @divExact(@as(i32, @intCast(after_skip)) - @as(i32, @intCast(bwd_skip_at)), 4);
            std.mem.writeInt(u32, ctx.buf.items[bwd_skip_at..][0..4], inst.encCbz(sx9, disp), .little);
        }
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
        {
            const back: i32 = @divExact(
                @as(i32, @intCast(bwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
                4,
            );
            try gpr.writeU32(ctx.allocator, ctx.buf, if (n64) inst.encCbnz(14, back) else inst.encCbnzW(14, back));
        }
        const bwd_end_jmp_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));

        // .fwd: patch the B.LS to land here.
        const fwd_byte: u32 = @intCast(ctx.buf.items.len);
        {
            const disp: i32 = @divExact(
                @as(i32, @intCast(fwd_byte)) - @as(i32, @intCast(fwd_at)),
                4,
            );
            std.mem.writeInt(u32, ctx.buf.items[fwd_at..][0..4], inst.encBCond(.ls, disp), .little);
        }
        const fwd_loop_start: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
        // Mirror funcptrs + typeidx (ADR-0068) — guarded on X9 != 0.
        const fwd_skip_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(sx9, 0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 13, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 9, 17));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(15, 7, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrWRegLsl2(15, 8, 17));
        {
            const after_skip: u32 = @intCast(ctx.buf.items.len);
            const disp = @divExact(@as(i32, @intCast(after_skip)) - @as(i32, @intCast(fwd_skip_at)), 4);
            std.mem.writeInt(u32, ctx.buf.items[fwd_skip_at..][0..4], inst.encCbz(sx9, disp), .little);
        }
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
        {
            const back: i32 = @divExact(
                @as(i32, @intCast(fwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
                4,
            );
            try gpr.writeU32(ctx.allocator, ctx.buf, if (n64) inst.encCbnz(14, back) else inst.encCbnzW(14, back));
        }

        // Patch the bwd→end jump.
        const end_byte: u32 = @intCast(ctx.buf.items.len);
        {
            const disp: i32 = @divExact(
                @as(i32, @intCast(end_byte)) - @as(i32, @intCast(bwd_end_jmp_at)),
                4,
            );
            std.mem.writeInt(u32, ctx.buf.items[bwd_end_jmp_at..][0..4], inst.encB(disp), .little);
        }
    } else {
        // Different tables: no overlap possible; forward only.
        const fwd_loop_start: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
        // Mirror funcptrs + typeidx (ADR-0068) — guarded on X9 != 0.
        const xt_skip_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(sx9, 0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 13, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 9, 17));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(15, 7, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrWRegLsl2(15, 8, 17));
        {
            const after_skip: u32 = @intCast(ctx.buf.items.len);
            const disp = @divExact(@as(i32, @intCast(after_skip)) - @as(i32, @intCast(xt_skip_at)), 4);
            std.mem.writeInt(u32, ctx.buf.items[xt_skip_at..][0..4], inst.encCbz(sx9, disp), .little);
        }
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
        {
            const back: i32 = @divExact(
                @as(i32, @intCast(fwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
                4,
            );
            try gpr.writeU32(ctx.allocator, ctx.buf, if (n64) inst.encCbnz(14, back) else inst.encCbnzW(14, back));
        }
    }

    // Patch the n==0 skip.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], if (n64) inst.encCbz(14, skip_disp) else inst.encCbzW(14, skip_disp), .little);
}

/// Wasm spec §4.4.16 (table.init x y) — pop n / src / dst; copy n
/// reftype values from elems[y][src..src+n] into tables[x][dst..dst+n].
/// Traps `OutOfBoundsTableAccess` on `src+n > seg.len` (where seg.len
/// is 0 if the segment was dropped via `elem.drop`) OR
/// `dst+n > tables[x].len`.
///
/// Encoding: ins.payload = elemidx (y); ins.extra = tableidx (x).
///
/// Holder regs after Step A: W17 = dst_idx, W16 = src_idx, W14 = n.
/// Long-lived:
///   X11 = dst_refs (from tables[x])
///   X12 = elem_refs (from elems[y]; len-overridden to 0 if dropped)
pub fn emitTableInit(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const elemidx: u32 = @intCast(ins.payload);
    const tableidx = ins.extra;
    // tableidx cap = 512 (TableSlice stride 24, see ADR-0068 +
    // emitTableGet rationale). elemidx: `baseOffLarge` reaches byte
    // offsets below 2^24 (ElemSlice stride 16).
    if (elemidx >= (1 << 20) or tableidx >= 512) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * jit_abi.table_slice_size);

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands. D-475: dst uses the table's idx_type
    // (X-form for i64); src + n are ALWAYS i32 (elem segments are
    // 32-bit-indexed, validator §3.3.6).
    const dst64 = ctx.func.tableIdxType(tableidx) == .i64;
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (dst64) inst.encOrrReg(17, 31, w_dst_src) else inst.encOrrRegW(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B1: read tables[x] descriptor — X11 = dst_refs, X13 = dst_len (u64, D-475).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx11, 10, tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx13, 10, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_len_off)));

    // Step B2: read elems[y] descriptor — X12 = elem_refs, W15 = elem_len.
    // Past the W-form imm12 budget the descriptor address goes through X9.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.elem_segments_ptr_off));
    const elem = try gpr.baseOffLarge(ctx.allocator, ctx.buf, sx10, sx9, elemidx * jit_abi.elem_slice_size, 16380 - 8);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx12, elem.base, @intCast(elem.off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(15, elem.base, @intCast(elem.off + 8)));

    // Step B3: dropped-flag override. If elem_dropped[elemidx] != 0,
    // seg_len → 0 via CSEL X15, X15, XZR, EQ.
    //   LDR X10, [X19, #elem_dropped_ptr_off]
    //   (ADD X9, X10, #(elemidx >> 12), LSL #12)
    //   LDRB W9, [X10|X9, #off]
    //   CMP W9, #0
    //   CSEL X15, X15, XZR, EQ
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.elem_dropped_ptr_off));
    const flag = try gpr.baseOffLarge(ctx.allocator, ctx.buf, sx10, sx9, elemidx, 4095);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(sx9, flag.base, @intCast(flag.off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(sx9, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCselX(15, 15, 31, .eq));

    // Step C1: bounds src+n > seg_len → trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(sx9, 16, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(sx9, 15));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step C2: bounds dst+n > tables[x].len → trap. A 64-bit dst can
    // wrap the sum (n is zero-extended u32) → ADDS + B.HS (D-475).
    if (dst64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddsReg(sx9, 17, 14));
        const wrap_fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, wrap_fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, wrap_fixup_at);
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(sx9, 17, 14));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(sx9, 13));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at); // D-293 oob_table (code 2)
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // TODO: table storage shape — see D-126 / ADR-0068.
    // Load dst funcptrs base into X9 + typeidx base into X13 —
    // long-lived through the loop. Reload tables_ptr first (X10
    // currently holds elem_dropped_ptr from Step B3). X9/X13 are
    // bounds-scratch from Step C1/C2 but free here.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx9, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx9, 9, @intCast(@as(u32, tbl_off) + jit_abi.tableslice_funcptrs_off)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx13, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx13, 13, @intCast(@as(u32, tableidx) * jit_abi.table_jit_ci_size + 8)));

    // Step D: if n == 0, skip.
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    // Step E: forward loop — elem_refs[src] → tbl.refs[dst] + mirror funcptrs.
    //   .loop:
    //     LDR X15, [X12, X16, LSL #3]   ; elem_refs[src] (FuncEntity ptr / null)
    //     STR X15, [X11, X17, LSL #3]   ; tbl.refs[dst]
    //     CBZ X9, .skip_fp              ; externref tables → skip funcptrs mirror
    //     ;; Mirror funcptrs (ADR-0068): derive X10 = FuncEntity(X15).funcptr (null-safe),
    //     ;; STR X10, [X9, X17, LSL #3].
    //     .skip_fp:
    //     ADD W17, W17, #1
    //     ADD W16, W16, #1
    //     SUB W14, W14, #1
    //     CBNZ W14, .loop
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
    const init_skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(sx9, 0));
    try emitDeriveFuncptrFromFuncref(ctx, 10, 15);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(sx10, 9, 17));
    try emitDeriveTypeidxFromFuncref(ctx, 10, 15);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrWRegLsl2(sx10, 13, 17));
    {
        const after_skip: u32 = @intCast(ctx.buf.items.len);
        const disp = @divExact(@as(i32, @intCast(after_skip)) - @as(i32, @intCast(init_skip_at)), 4);
        std.mem.writeInt(u32, ctx.buf.items[init_skip_at..][0..4], inst.encCbz(sx9, disp), .little);
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    {
        const back: i32 = @divExact(
            @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
            4,
        );
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back));
    }

    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], inst.encCbzW(14, skip_disp), .little);
}
