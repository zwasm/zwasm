//! x86_64 emit pass — `table.get` / `table.set` / `table.size`
//! handlers (per ADR-0058).
//!
//! Mirror of `arm64/op_table.zig`. The JIT body reads the
//! per-table `TableSlice` descriptor from `[R15 + tables_ptr_off]`,
//! indexes by `tableidx * jit_abi.table_slice_size` (= 16 pre-ADR-
//! 0068, 24 post-ADR-0068 dual-view extension),
//! and performs a bounds-checked load/store against `refs[idx]`.
//!
//! Per-op shape (Wasm spec §4.4.10–12):
//!
//!   table.get x:
//!     MOV  RAX, [R15 + tables_ptr_off]            ; tables_ptr
//!     MOV  R11, [RAX + (tableidx*32)]             ; refs ptr
//!     MOV  R10, [RAX + (tableidx*32)+8]           ; len (u64, D-475)
//!     MOV  EDX, W_idx                              ; stage idx in EDX
//!     CMP  RDX, R10                                ; .q width (D-475)
//!     JAE  trap_stub                               ; oobtable_fixups
//!     MOV  Rdst, [R11 + RDX*8]                     ; refs[idx]
//!     (store back to spill slot if needed)
//!
//!   table.set x:
//!     (same prologue + bounds check)
//!     MOV  [R11 + RDX*8], Rval
//!
//!   table.size x:
//!     MOV  RAX, [R15 + tables_ptr_off]
//!     MOV  Rdst, [RAX + (tableidx*32)+8]           ; push len
//!
//! RAX / R10 / R11 / RDX are private scratch within the handler
//! (RAX is global scratch outside the regalloc pool; R10/R11 are
//! reserved for memory-op style scratch; RDX is the idx holder
//! mirror of op_memory.emitMemoryInit's pattern).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");
const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_mem = @import("inst_mem.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");
const trace = @import("../../../diagnostic/trace.zig");
const op_call = @import("op_call.zig");
const emitShadowAlloc = op_call.emitShadowAlloc;
const emitShadowFree = op_call.emitShadowFree;

/// `(ctx, ins)` adapters for the
/// table ops cohort (7 ops). Seven distinct adapters
/// (heterogeneous signatures — most take func_idx+tableidx;
/// table.copy/init use both `ins.payload` (dst) + `ins.extra`
/// (src)).
pub fn emitTableGetCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableGet(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.oobtable_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        @as(u32, @intCast(ins.payload)),
        ctx.func.tableIdxType(@intCast(ins.payload)) == .i64,
    );
}

pub fn emitTableSetCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableSet(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oobtable_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        @as(u32, @intCast(ins.payload)),
        ctx.func.tableIdxType(@intCast(ins.payload)) == .i64,
    );
}

pub fn emitTableSizeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableSize(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        @as(u32, @intCast(ins.payload)),
    );
}

pub fn emitTableGrowCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableGrow(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ctx.outgoing_max_bytes,
        @as(u32, @intCast(ins.payload)),
        ctx.func.tableIdxType(@intCast(ins.payload)) == .i64,
    );
}

pub fn emitTableFillCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableFill(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oobtable_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        @as(u32, @intCast(ins.payload)),
        ctx.func.tableIdxType(@intCast(ins.payload)) == .i64,
    );
}

pub fn emitTableCopyCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableCopy(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oobtable_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        @as(u32, @intCast(ins.payload)),
        ins.extra,
        ctx.func.tableIdxType(@intCast(ins.payload)) == .i64,
        ctx.func.tableIdxType(ins.extra) == .i64,
    );
}

pub fn emitTableInitCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitTableInit(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oobtable_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        @as(u32, @intCast(ins.payload)),
        ins.extra,
        // ins.extra = tableidx (dst); ins.payload = elemidx.
        ctx.func.tableIdxType(ins.extra) == .i64,
    );
}
const func_mod = @import("../../../runtime/instance/func.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
/// Emit the "derive funcptr from funcref value with null check"
/// sequence for x86_64. Result lands in `dst`; `val` is the
/// FuncEntity pointer register (Value.null_ref == 0 for null).
/// Mirror of arm64's `emitDeriveFuncptrFromFuncref`.
///   TEST val, val
///   JZ .null
///   MOV dst, [val + funcentity_funcptr_offset]
///   JMP .end
///   .null: XOR dst, dst (zero-extends u64)
///   .end:
fn emitDeriveFuncptrFromFuncref(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    dst: inst.Gpr,
    val: inst.Gpr,
) Error!void {
    try buf.appendSlice(allocator, inst.encTestRR(.q, val, val).slice());
    const jz_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try buf.appendSlice(allocator, inst_mem.encMovR64FromMemDisp32(dst, val, @intCast(func_mod.funcentity_funcptr_offset)).slice());
    const jmp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    const null_arm: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encXorRR(.d, dst, dst).slice());
    const end_byte: u32 = @intCast(buf.items.len);

    const jz_disp: i32 = @as(i32, @intCast(null_arm)) - (@as(i32, @intCast(jz_at)) + 6);
    @memcpy(buf.items[jz_at..][0..6], inst.encJccRel32(.e, jz_disp).slice()[0..6]);
    const jmp_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(jmp_at)) + 5);
    @memcpy(buf.items[jmp_at..][0..5], inst.encJmpRel32(jmp_disp).slice()[0..5]);
}

/// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
/// Derive typeidx (u32) from FuncEntity ptr; null → sentinel
/// `maxInt(u32) = 0xFFFFFFFF`. Result lands in `dst` (low 32 bits).
///   TEST val, val
///   JZ .null
///   MOV Edst, [val + funcentity_typeidx_offset]
///   JMP .end
///   .null: MOV Edst, 0xFFFFFFFF
///   .end:
fn emitDeriveTypeidxFromFuncref(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    dst: inst.Gpr,
    val: inst.Gpr,
) Error!void {
    try buf.appendSlice(allocator, inst.encTestRR(.q, val, val).slice());
    const jz_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try buf.appendSlice(allocator, inst_mem.encMovR32FromMemDisp32(dst, val, @intCast(func_mod.funcentity_typeidx_offset)).slice());
    const jmp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    const null_arm: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encMovImm32W(dst, 0xFFFFFFFF).slice());
    const end_byte: u32 = @intCast(buf.items.len);

    const jz_disp: i32 = @as(i32, @intCast(null_arm)) - (@as(i32, @intCast(jz_at)) + 6);
    @memcpy(buf.items[jz_at..][0..6], inst.encJccRel32(.e, jz_disp).slice()[0..6]);
    const jmp_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(jmp_at)) + 5);
    @memcpy(buf.items[jmp_at..][0..5], inst.encJmpRel32(jmp_disp).slice()[0..5]);
}

/// Wasm spec §4.4.10 (table.get) — pop i32 idx, push tables[x][idx]
/// as a reference Value (8-byte). Traps `OutOfBoundsTableAccess` on
/// idx >= table.len via the shared `oobtable_fixups` channel.
pub fn emitTableGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oobtable_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    tableidx: u32,
    idx64: bool,
) Error!void {
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Encoding-budget guard. disp32 always suffices; cap matches
    // arm64's 512 (stride 24 per ADR-0068, 32 after D-475).
    if (tableidx >= 512) return Error.UnsupportedOp;
    const tbl_disp: i32 = @intCast(tableidx * jit_abi.table_slice_size);

    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;

    // Snapshot idx into RDX BEFORE the descriptor loads. r10/r11 are BOTH the
    // spill-stage regs AND the descriptor regs (refs/len), so with the loads
    // first a SPILLED idx would land in r10 on top of the length, and
    // `CMP RDX, R10` would compare the index with itself — `JAE` always fired,
    // in-bounds or not (D-590). Two facts keep the snapshot alive to the CMP:
    // RDX is outside the allocatable pool and the spill stages, so nothing
    // lives there and no later spill re-load can stage over it; and the
    // descriptor loads write only RAX/R11/R10. Mirrors `emitTableSet` below
    // and arm64's Step-A X17 snapshot. Staging in EDX zero-extends to RDX
    // implicitly; an i64 table stages the full 64-bit index (.q, D-475).
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (idx64) .q else .d, .rdx, idx_r).slice());

    // Load tables_ptr → RAX; refs → R11; len → R10 (u64, D-475; r10/r11 free now).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r11, .rax, tbl_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_len_off))).slice());

    // CMP RDX, R10 ; JAE trap. .q width (D-475: len is u64).
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdx, .r10).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // Allocate result vreg and load.
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    // MOV Rdst, [R11 + RDX*8]
    try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(dst_r, .r11, .rdx).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.11 (table.set) — pop reftype value then i32 idx,
/// write `tables[x][idx] = val`.
pub fn emitTableSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oobtable_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    tableidx: u32,
    idx64: bool,
) Error!void {
    if (tableidx >= 512) return Error.UnsupportedOp;
    const tbl_disp: i32 = @intCast(tableidx * jit_abi.table_slice_size);

    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const val_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;

    // Snapshot operands into non-allocatable scratch BEFORE loading the
    // table descriptor. r10/r11 are BOTH the spill-stage regs AND the
    // descriptor regs (refs/len), so a SPILLED idx/val load would clobber
    // the descriptor — a non-null struct.new result spills → its load into
    // r11 destroys the refs base → the store targets `[val_addr + idx*8]`
    // (a wasm-trap / bad address), only when the value is non-null/spilled.
    // Mirrors arm64's X16/X17 snapshot. idx → EDX; val → R9 (full 64-bit;
    // R9 is fenced for this op (`abi.op_regs`), not a spill stage, untouched by the descriptor
    // loads and the funcptr/typeidx mirror below).
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (idx64) .q else .d, .rdx, idx_r).slice());
    const val_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 1);
    try buf.appendSlice(allocator, inst.encMovRR(.q, .r9, val_r).slice());

    // Load tables_ptr → RAX; refs → R11; len → R10 (u64, D-475; r10/r11 free now).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r11, .rax, tbl_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_len_off))).slice());

    // CMP RDX, R10 ; JAE trap. .q width (D-475: len is u64).
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdx, .r10).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // MOV [R11 + RDX*8], R9 (val).
    try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .r11, .rdx).slice());

    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Mirror funcptrs + typeidx views, guarded on null funcptrs
    // base (externref tables): RAX = funcptrs base; TEST/JZ skip;
    // derive into RCX; STR. Then derive typeidx into RCX and STR
    // to typeidx_base from tables_jit_ci_ptr.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_funcptrs_off))).slice());
    try buf.appendSlice(allocator, inst.encTestRR(.q, .rax, .rax).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try emitDeriveFuncptrFromFuncref(allocator, buf, .rcx, .r9);
    try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.rcx, .rax, .rdx).slice());
    // typeidx mirror (γ.2):
    try emitDeriveTypeidxFromFuncref(allocator, buf, .rcx, .r9);
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, @intCast(tableidx * 16 + 8)).slice());
    try buf.appendSlice(allocator, inst_mem.encStoreR32MemBaseIdxLsl2(.rcx, .rax, .rdx).slice());
    const end_byte: u32 = @intCast(buf.items.len);
    const skip_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_at)) + 6);
    @memcpy(buf.items[skip_at..][0..6], inst.encJccRel32(.e, skip_disp).slice()[0..6]);
}

/// Wasm spec §4.4.12 (table.size) — push tables[x].len as i32.
/// No trap conditions; validator pre-rejects out-of-range tableidx.
pub fn emitTableSize(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    tableidx: u32,
) Error!void {
    if (tableidx >= 512) return Error.UnsupportedOp;
    const len_disp: i32 = @intCast(tableidx * jit_abi.table_slice_size + jit_abi.tableslice_len_off);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());

    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    // MOV Rdst, [RAX + len_disp] (64-bit, D-475: len is u64; an i32
    // table's len < 2^32 so the value matches the old 32-bit load).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(dst_r, .rax, len_disp).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.13 (table.grow x) — pop n:i32, init:reftype;
/// push i32 (previous size on success, -1 on failure). Per
/// D-122/D-125 (mirror of ADR-0059):
/// indirect call through `JitRuntime.table_grow_fn`.
///
/// SysV C-ABI args: RDI = rt, ESI = tableidx, RDX = init (8-byte
/// raw bits), ECX = delta. Result lands in EAX.
pub fn emitTableGrow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    tableidx: u32,
    idx64: bool,
) Error!void {
    if (tableidx >= 512) return Error.UnsupportedOp;

    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const delta_v = pushed_vregs.pop().?;
    const init_v = pushed_vregs.pop().?;

    const arg1 = abi.current.arg_gprs[1]; // tableidx
    const arg2 = abi.current.arg_gprs[2]; // init (8-byte raw)
    const arg3 = abi.current.arg_gprs[3]; // delta

    // Stage delta into arg3 (Cc-dependent). gprLoadSpilled may park
    // it in R10 (spill-stage); MOV to arg3 if needed.
    // D-475: an i64 table's delta is a full u64 (.q); i32 keeps the
    // zero-extending .d (the callback takes u64 — transparent).
    const delta_src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, delta_v, 0);
    if (delta_src != arg3) {
        try buf.appendSlice(allocator, inst.encMovRR(if (idx64) .q else .d, arg3, delta_src).slice());
    }

    // Stage init into arg2 (full 8-byte ref). Stage 1 to avoid
    // colliding with delta's R10 home.
    const init_src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, init_v, 1);
    if (init_src != arg2) {
        try buf.appendSlice(allocator, inst.encMovRR(.q, arg2, init_src).slice());
    }

    // arg1 = tableidx (immediate u32). MOV r32, imm32.
    try buf.appendSlice(allocator, inst.encMovImm32W(arg1, tableidx).slice());

    // arg0 (= entry_arg0_gpr) = runtime_ptr (R15 alias).
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());

    // RAX = JitRuntime.table_grow_fn (8-byte fn ptr).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.table_grow_fn_off).slice());

    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
    try emitShadowFree(allocator, buf, outgoing_max_bytes);

    // Capture EAX/RAX → result vreg. D-475: an i64 table's grow result
    // is a full i64 (.q); the i32 .d capture truncates -1 / the
    // sub-2^32 old size to the correct i32 bit pattern.
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    if (dst_r != abi.return_gpr) {
        try buf.appendSlice(allocator, inst.encMovRR(if (idx64) .q else .d, dst_r, abi.return_gpr).slice());
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.14 (table.fill x) — pop n (i32), val (reftype),
/// dst (i32); write `n` copies of `val` into `tables[x][dst..dst+n]`.
/// Traps `OutOfBoundsTableAccess` if `dst+n > tables[x].len`.
///
/// Holder regs after Step A:
///   RDX = dst (zero-ext u32),
///   R8  = val (full 64-bit ref),
///   R10 = n   (zero-ext u32, used as loop counter).
pub fn emitTableFill(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oobtable_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    tableidx: u32,
    idx64: bool,
) Error!void {
    if (tableidx >= 512) return Error.UnsupportedOp;
    const tbl_disp: i32 = @intCast(tableidx * jit_abi.table_slice_size);

    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const val_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: capture operands into private holders. R8 is written
    // before n is read; the operand fence (`abi.op_regs`) keeps n
    // out of R8.
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (idx64) .q else .d, .rdx, dst_r).slice());
    const val_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 1);
    try buf.appendSlice(allocator, inst.encMovRR(.q, .r8, val_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (idx64) .q else .d, .r10, n_r).slice());

    // Step B: read TableSlice[tableidx]. RAX = tables_ptr; R11 = refs;
    // R9 = len (u64, D-475; using R9 since R10/R11/RDX/R8 are already in use).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r11, .rax, tbl_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_len_off))).slice());

    // Step C: bounds check — RAX = dst + n; CMP RAX, R9; JA trap.
    //   MOV  RAX, RDX
    //   ADD  RAX, R10
    //   CMP  RAX, R9
    //   JA   trap_stub
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rax, .r10).slice());
    if (idx64) {
        // D-475: raw u64 dst+n can wrap past 2^64 — JC (carry) traps
        // the wrap before the length compare (memory64 pattern).
        const wrap_fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.b, 0).slice());
        try oobtable_fixups.append(allocator, wrap_fixup_at);
        trace.writeBounds(func_idx, wrap_fixup_at);
    }
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rax, .r9).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Pre-loop: R9 = funcptrs base (0 = externref → skip mirror).
    // For funcref tables, derive funcptr from R8 (val) into RCX,
    // derive typeidx into RSI, and load typeidx_base into RDI.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_funcptrs_off))).slice());
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r9, .r9).slice());
    const derive_skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try emitDeriveFuncptrFromFuncref(allocator, buf, .rcx, .r8);
    try emitDeriveTypeidxFromFuncref(allocator, buf, .rsi, .r8);
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rdi, .rax, @intCast(tableidx * 16 + 8)).slice());
    {
        const after: u32 = @intCast(buf.items.len);
        const disp: i32 = @as(i32, @intCast(after)) - (@as(i32, @intCast(derive_skip_at)) + 6);
        @memcpy(buf.items[derive_skip_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
    }

    // Step D: if n == 0, skip the loop. TEST R10, R10 ; JE end.
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    // Step E: loop body with mirror.
    //   .loop:
    //     MOV [R11 + RDX*8], R8       ; refs[dst] = val (8-byte)
    //     TEST R9, R9 ; JZ .skip_fp   ; externref → skip funcptrs mirror
    //     MOV [R9 + RDX*8], RCX       ; funcptrs[dst] = derived
    //     .skip_fp:
    //     ADD RDX, 1
    //     ADD R10, -1
    //     JNE .loop
    const loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r8, .r11, .rdx).slice());
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r9, .r9).slice());
    const fill_skip_fp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.rcx, .r9, .rdx).slice());
    try buf.appendSlice(allocator, inst_mem.encStoreR32MemBaseIdxLsl2(.rsi, .rdi, .rdx).slice());
    {
        const after: u32 = @intCast(buf.items.len);
        const disp: i32 = @as(i32, @intCast(after)) - (@as(i32, @intCast(fill_skip_fp_at)) + 6);
        @memcpy(buf.items[fill_skip_fp_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
    }
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jne: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        const disp: i32 = @as(i32, @intCast(loop_start)) - after_jne;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }

    // Step F: patch the skip JE target.
    const end_byte: u32 = @intCast(buf.items.len);
    const skip_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_at)) + 6);
    const patch_enc = inst.encJccRel32(.e, skip_disp);
    @memcpy(buf.items[skip_at..][0..6], patch_enc.slice()[0..6]);
}

/// Wasm spec §4.4.15 (table.copy x y) — pop n / src / dst; copy n
/// reftype values from tables[y][src..src+n] into
/// tables[x][dst..dst+n]. memmove semantics on same-table overlap.
///
/// Encoding: ins.payload = dst-tableidx (x); ins.extra = src-tableidx (y).
///
/// Holder regs after Step A: RDX = dst_idx, R8 = src_idx, R10 = n.
/// Long-lived: R11 = dst_refs, RCX = src_refs.
pub fn emitTableCopy(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oobtable_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    dst_tbl: u32,
    src_tbl: u32,
    dst64: bool,
    src64: bool,
) Error!void {
    if (dst_tbl >= 512 or src_tbl >= 512) return Error.UnsupportedOp;
    const dst_tbl_disp: i32 = @intCast(dst_tbl * jit_abi.table_slice_size);
    const src_tbl_disp: i32 = @intCast(src_tbl * jit_abi.table_slice_size);
    const same_table = (dst_tbl == src_tbl);

    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const src_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: capture operands into private holders. D-475 widths per
    // table (validator §3.3.6 table64): dst uses the DST table's
    // idx_type, src the SRC table's, n the narrower of the two.
    const n64 = dst64 and src64;
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (dst64) .q else .d, .rdx, dst_r).slice());
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (src64) .q else .d, .r8, src_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (n64) .q else .d, .r10, n_r).slice());

    // Step B: load tables_ptr → RAX.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());

    // Step C1: bounds dst_idx + n vs tables[x].len.
    // R11 = dst_refs ; R9 = dst_len (u64, D-475) ; bounds via RDI
    // scratch (fenced for this op, `abi.op_regs`).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r11, .rax, dst_tbl_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, dst_tbl_disp + @as(i32, @intCast(jit_abi.tableslice_len_off))).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rdi, .rdx).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdi, .r10).slice());
    if (dst64) {
        // D-475: raw u64 dst+n can wrap — JC traps the wrap.
        const wrap_fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.b, 0).slice());
        try oobtable_fixups.append(allocator, wrap_fixup_at);
        trace.writeBounds(func_idx, wrap_fixup_at);
    }
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdi, .r9).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // Step C2: bounds src_idx + n vs tables[y].len.
    // RCX = src_refs ; R9 = src_len (u64, reused).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rcx, .rax, src_tbl_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, src_tbl_disp + @as(i32, @intCast(jit_abi.tableslice_len_off))).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rdi, .r8).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdi, .r10).slice());
    if (src64) {
        // D-475: raw u64 src+n can wrap — JC traps the wrap.
        const wrap_fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.b, 0).slice());
        try oobtable_fixups.append(allocator, wrap_fixup_at);
        trace.writeBounds(func_idx, wrap_fixup_at);
    }
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdi, .r9).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Load funcptrs bases for the mirror: RSI = dst_funcptrs_base
    // (long-lived). For different-tables case also RDI =
    // src_funcptrs_base. RAX still holds tables_ptr from Step B.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rsi, .rax, dst_tbl_disp + @as(i32, @intCast(jit_abi.tableslice_funcptrs_off))).slice());
    if (!same_table) {
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rdi, .rax, src_tbl_disp + @as(i32, @intCast(jit_abi.tableslice_funcptrs_off))).slice());
    }

    // Step D: if n == 0, skip.
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    if (same_table) {
        // Step E: direction switch — CMP RDX, R8 ; JBE forward.
        try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdx, .r8).slice());
        const fwd_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());

        // .bwd: pre-advance both indices by n.
        try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .r10).slice());
        try buf.appendSlice(allocator, inst.encAddRR(.q, .r8, .r10).slice());
        const bwd_loop_start: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, -1).slice());
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.r8, -1).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rcx, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .r11, .rdx).slice());
        // Mirror funcptrs + typeidx (same-table: src=dst base = RSI;
        // typeidx_base reloaded per-iter via RAX → RDI scratch).
        // D-145 fix: typeidx mirror was missing pre-cycle-10, causing
        // ubuntu 24 fails on table_init/table_copy `check(N)` calls.
        // arm64 sibling (op_table.zig:540-554) already mirrors both.
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rsi, .rsi).slice());
        const bwd_fp_skip_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rsi, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .rsi, .rdx).slice());
        // typeidx mirror: reload typeidx_base via RAX, copy ESI[src]→[dst].
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, @intCast(dst_tbl * 16 + 8)).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR32FromBaseIdxLsl2(.rdi, .rax, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR32MemBaseIdxLsl2(.rdi, .rax, .rdx).slice());
        {
            const after: u32 = @intCast(buf.items.len);
            const disp: i32 = @as(i32, @intCast(after)) - (@as(i32, @intCast(bwd_fp_skip_at)) + 6);
            @memcpy(buf.items[bwd_fp_skip_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
        }
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
        {
            const after_jne: i32 = @as(i32, @intCast(buf.items.len)) + 6;
            const disp: i32 = @as(i32, @intCast(bwd_loop_start)) - after_jne;
            try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
        }
        const bwd_end_jmp_at: u32 = @intCast(buf.items.len);
        // Unconditional JMP rel32 to end — use JE with always-true (impossible)?
        // No, use plain JMP rel32: 0xE9 + disp32.
        try buf.appendSlice(allocator, &[_]u8{ 0xE9, 0, 0, 0, 0 });

        // .fwd: patch JBE to here.
        const fwd_byte: u32 = @intCast(buf.items.len);
        const fwd_disp: i32 = @as(i32, @intCast(fwd_byte)) - (@as(i32, @intCast(fwd_at)) + 6);
        const patch_fwd = inst.encJccRel32(.be, fwd_disp);
        @memcpy(buf.items[fwd_at..][0..6], patch_fwd.slice()[0..6]);

        const fwd_loop_start: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rcx, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .r11, .rdx).slice());
        // Mirror funcptrs + typeidx (same-table forward; D-145 fix).
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rsi, .rsi).slice());
        const fwd_fp_skip_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rsi, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .rsi, .rdx).slice());
        // typeidx mirror via RAX (typeidx_base) + RDI (u32 scratch).
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, @intCast(dst_tbl * 16 + 8)).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR32FromBaseIdxLsl2(.rdi, .rax, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR32MemBaseIdxLsl2(.rdi, .rax, .rdx).slice());
        {
            const after: u32 = @intCast(buf.items.len);
            const disp: i32 = @as(i32, @intCast(after)) - (@as(i32, @intCast(fwd_fp_skip_at)) + 6);
            @memcpy(buf.items[fwd_fp_skip_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
        }
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.r8, 1).slice());
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
        {
            const after_jne: i32 = @as(i32, @intCast(buf.items.len)) + 6;
            const disp: i32 = @as(i32, @intCast(fwd_loop_start)) - after_jne;
            try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
        }

        // Patch bwd→end JMP.
        const end_byte: u32 = @intCast(buf.items.len);
        const jmp_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(bwd_end_jmp_at)) + 5);
        std.mem.writeInt(i32, buf.items[bwd_end_jmp_at + 1 ..][0..4], jmp_disp, .little);
    } else {
        // Different tables: forward only, with funcptrs + typeidx mirror.
        if (jit_abi.table_jit_ci_size != 16) @compileError("x86_64 emitTableCopy assumes TableJitCallInfo stride 16");
        const fwd_loop_start: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rcx, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .r11, .rdx).slice());
        // Mirror funcptrs + typeidx (different-tables case; reloads
        // tables_jit_ci_ptr each iter for typeidx bases — RAX-only
        // scratch budget).
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rsi, .rsi).slice());
        const xt_skip_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rdi, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .rsi, .rdx).slice());
        // typeidx: reload bases per iter.
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, @intCast(dst_tbl * 16 + 8)).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, @intCast(src_tbl * 16 + 8)).slice());
        try buf.appendSlice(allocator, inst_mem.encMovR32FromBaseIdxLsl2(.rax, .rax, .r8).slice());
        try buf.appendSlice(allocator, inst_mem.encStoreR32MemBaseIdxLsl2(.rax, .r9, .rdx).slice());
        {
            const after: u32 = @intCast(buf.items.len);
            const disp: i32 = @as(i32, @intCast(after)) - (@as(i32, @intCast(xt_skip_at)) + 6);
            @memcpy(buf.items[xt_skip_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
        }
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.r8, 1).slice());
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
        {
            const after_jne: i32 = @as(i32, @intCast(buf.items.len)) + 6;
            const disp: i32 = @as(i32, @intCast(fwd_loop_start)) - after_jne;
            try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
        }
    }

    // Patch the n==0 JE skip.
    const end_byte: u32 = @intCast(buf.items.len);
    const skip_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_at)) + 6);
    const patch_skip = inst.encJccRel32(.e, skip_disp);
    @memcpy(buf.items[skip_at..][0..6], patch_skip.slice()[0..6]);
}

/// Wasm spec §4.4.16 (table.init x y) — pop n / src / dst; copy
/// n ref values from elems[y][src..src+n] into tables[x][dst..dst+n].
/// Traps on src+n > seg.len (with seg.len overridden to 0 when
/// elem_dropped[elemidx] is non-zero) or dst+n > tables[x].len.
///
/// Encoding: ins.payload = elemidx (y); ins.extra = tableidx (x).
pub fn emitTableInit(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oobtable_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    elemidx: u32,
    tableidx: u32,
    dst64: bool,
) Error!void {
    // tableidx cap = 512 (TableSlice stride 32 per D-475);
    // elemidx cap stays 1024 (ElemSlice stride still 16).
    if (elemidx >= 1024 or tableidx >= 512) return Error.UnsupportedOp;
    const tbl_disp: i32 = @intCast(tableidx * jit_abi.table_slice_size);
    const elem_disp: i32 = @intCast(elemidx * jit_abi.elem_slice_size);

    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const src_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: capture operands. D-475: dst uses the table's idx_type
    // (.q for i64); src + n are ALWAYS i32 (elem segments are
    // 32-bit-indexed, validator §3.3.6).
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (dst64) .q else .d, .rdx, dst_r).slice());
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .r8, src_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .r10, n_r).slice());

    // Step B1: tables[x] descriptor — R11 = dst_refs, R9 = dst_len (u64, D-475).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r11, .rax, tbl_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_len_off))).slice());

    // Step B2: elems[y] descriptor — RCX = elem_refs, RSI = elem_len.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.elem_segments_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rcx, .rax, elem_disp).slice());
    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rsi, .rax, elem_disp + 8).slice());

    // Step B3: dropped-flag override. MOV RAX = elem_dropped_ptr;
    // MOVZX RDI = byte [RAX + elemidx]; XOR EAX, EAX; TEST RDI, RDI;
    // CMOVNE RSI, RAX (RSI ← 0 if dropped). RDI is fenced for this op
    // (`abi.op_regs`).
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.elem_dropped_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rax, @intCast(elemidx)).slice());
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rdi, .rdi).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.rdi, .rax, .rdi).slice());
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    try buf.appendSlice(allocator, inst.encTestRR(.q, .rdi, .rdi).slice());
    try buf.appendSlice(allocator, inst.encCmovccRR(.q, .ne, .rsi, .rax).slice());

    // Step C1: bounds src+n > seg_len (RSI). RDI = src+n (transient).
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rdi, .r8).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdi, .r10).slice());
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdi, .rsi).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // Step C2: bounds dst+n > dst_len (R9). A 64-bit dst can wrap the
    // sum (n is zero-extended u32) — JC traps the wrap (D-475).
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rdi, .rdx).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdi, .r10).slice());
    if (dst64) {
        const wrap_fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.b, 0).slice());
        try oobtable_fixups.append(allocator, wrap_fixup_at);
        trace.writeBounds(func_idx, wrap_fixup_at);
    }
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rdi, .r9).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try oobtable_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Load dst funcptrs base into RDI — long-lived through loop.
    // (RAX currently holds elem_dropped_ptr from Step B3; reload
    // tables_ptr first.)
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rdi, .rax, tbl_disp + @as(i32, @intCast(jit_abi.tableslice_funcptrs_off))).slice());

    // Step D: if n == 0, skip.
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    // Step E: forward loop — elem_refs[src] → tbl.refs[dst] + mirror funcptrs.
    //   .loop:
    //     MOV R9, [RCX + R8*8]       ; elem_refs[src] (FuncEntity ptr / null)
    //     MOV [R11 + RDX*8], R9      ; tbl.refs[dst]
    //     TEST RDI, RDI ; JZ .skip_fp ; externref → skip mirror
    //     emitDeriveFuncptrFromFuncref(.rsi, .r9)
    //     MOV [RDI + RDX*8], RSI
    //     .skip_fp:
    //     ADD RDX, 1 / ADD R8, 1 / ADD R10, -1 / JNE .loop
    const loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst_mem.encMovR64FromBaseIdxLsl3(.r9, .rcx, .r8).slice());
    try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.r9, .r11, .rdx).slice());
    try buf.appendSlice(allocator, inst.encTestRR(.q, .rdi, .rdi).slice());
    const init_skip_fp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try emitDeriveFuncptrFromFuncref(allocator, buf, .rsi, .r9);
    try buf.appendSlice(allocator, inst_mem.encStoreR64MemBaseIdxLsl3(.rsi, .rdi, .rdx).slice());
    // typeidx mirror (γ.2): reload typeidx_base via RAX per iter.
    try emitDeriveTypeidxFromFuncref(allocator, buf, .rsi, .r9);
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, @intCast(tableidx * 16 + 8)).slice());
    try buf.appendSlice(allocator, inst_mem.encStoreR32MemBaseIdxLsl2(.rsi, .rax, .rdx).slice());
    {
        const after: u32 = @intCast(buf.items.len);
        const disp: i32 = @as(i32, @intCast(after)) - (@as(i32, @intCast(init_skip_fp_at)) + 6);
        @memcpy(buf.items[init_skip_fp_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
    }
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r8, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jne: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        const disp: i32 = @as(i32, @intCast(loop_start)) - after_jne;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }

    const end_byte: u32 = @intCast(buf.items.len);
    const skip_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_at)) + 6);
    const patch_skip = inst.encJccRel32(.e, skip_disp);
    @memcpy(buf.items[skip_at..][0..6], patch_skip.slice()[0..6]);
}
