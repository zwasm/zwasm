//! ARM64 emit pass — `global.get` / `global.set` handlers.
//!
//! Per ADR-0027 / ADR-0052: each defined global lives at byte
//! offset `ctx.globals_offsets[idx]` within `[X23 =
//! globals_base_save_gpr]`. Scalar globals (i32/i64/f32/f64/refs)
//! use 8-byte slots and the legacy `idx*8` offset; v128 globals
//! use 16-byte slots aligned to 16 bytes, addressed via Q-form
//! LDR/STR. X23 is pre-loaded from `[X0 + globals_base_off]` at
//! the function prologue when the function actually touches a
//! global op (prescan-driven; functions without globals skip the
//! X23 load).
//!
//! i32 globals access the low 4 bytes of the 8-byte slot via
//! W-form LDR / STR. i64 globals use X-form (full 64-bit). f32 /
//! f64 globals use S-form / D-form on V-class regs (FP scalar).
//! funcref / externref share the i64 X-form path — reftype values
//! occupy an 8-byte slot identical in shape to i64 per ADR-0061
//! (the host stores `*FuncInstance` / `*ExternRefRecord` pointers
//! interchangeably with i64 bit patterns; nullity is the all-zero
//! pattern shared with `ref.null t`).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const dbg = @import("../../../support/dbg.zig");
const call_profile = @import("../../../support/call_profile.zig");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const abi = @import("abi.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// Look up the byte offset + valtype for global `idx`. Returns
/// the uniform 16-byte stride fallback when the index falls outside
/// the per-defined-global metadata range (imports beyond the table;
/// v128 imports path tracked under D-079). Post-ADR-0110 widen:
/// stride is 16 (matches `@sizeOf(Value)`).
fn lookupGlobalShape(ctx: *const EmitCtx, idx: u32) struct { byte_off: u32, vt: zir.ValType } {
    if (idx < ctx.globals_offsets.len) {
        return .{ .byte_off = ctx.globals_offsets[idx], .vt = ctx.globals_valtypes[idx] };
    }
    return .{ .byte_off = idx * 16, .vt = .i32 };
}

/// Wasm spec §4.4.5 (global.get N) — push the value of global N
/// onto the operand stack. Dispatch on the global's valtype:
///
///   i32 → `LDR Wd, [X23, #byte_off]` (W-form imm12 scaled by 4)
///   v128 → `LDR Qd, [X23, #byte_off]` (Q-form imm12 scaled by 16)
///
/// Caller MUST have ensured `uses_globals` was true at prologue
/// time; otherwise X23 is undefined.
pub fn emitGlobalGet(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const globalidx: u32 = @intCast(ins.payload);
    const shape = lookupGlobalShape(ctx, globalidx);
    switch (shape.vt) {
        .i32 => try emitI32GlobalGet(ctx, globalidx, shape.byte_off),
        .i64, .ref => try emitI64GlobalGet(ctx, globalidx, shape.byte_off),
        .f32 => try emitF32GlobalGet(ctx, globalidx, shape.byte_off),
        .f64 => try emitF64GlobalGet(ctx, globalidx, shape.byte_off),
        .v128 => try emitV128GlobalGet(ctx, globalidx, shape.byte_off),
    }
}

/// Wasm spec §4.4.5 (global.set N).
pub fn emitGlobalSet(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const globalidx: u32 = @intCast(ins.payload);
    const shape = lookupGlobalShape(ctx, globalidx);
    switch (shape.vt) {
        .i32 => try emitI32GlobalSet(ctx, globalidx, shape.byte_off),
        .i64, .ref => try emitI64GlobalSet(ctx, globalidx, shape.byte_off),
        .f32 => try emitF32GlobalSet(ctx, globalidx, shape.byte_off),
        .f64 => try emitF64GlobalSet(ctx, globalidx, shape.byte_off),
        .v128 => try emitV128GlobalSet(ctx, globalidx, shape.byte_off),
    }
}

fn emitI32GlobalGet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    // imm12 in W-form scales by 4 → max byte_offset = 4 * 4095 = 16380.
    if (byte_off > 16380) {
        dbg.print("codegen", "arm64/op_globals: global.get SlotOverflow func[{d}] idx={d} byte_off={d}>16380\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) {
        dbg.print("codegen", "arm64/op_globals: global.get SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ ctx.func.func_idx, result, ctx.alloc.slots.len });
        return Error.SlotOverflow;
    }
    const wd = try gpr.gprDefSpilled(ctx.alloc, result, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(wd, abi.globals_base_save_gpr, @intCast(byte_off)));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

fn emitI32GlobalSet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 16380) {
        dbg.print("codegen", "arm64/op_globals: global.set SlotOverflow func[{d}] idx={d} byte_off={d}>16380\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = ctx.pushed_vregs.pop().?;
    const ws = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(ws, abi.globals_base_save_gpr, @intCast(byte_off)));

    // D-494 global.trace (ZWASM_DEBUG=global.trace): record the just-set value of
    // a low global into the process-global `g_last[idx]` so a JIT run captures the
    // FINAL asyncify-state values. X16 (IP0) is a short-lived scratch — safe here
    // (global.set is not mid-call_indirect). `ws` is still live (just stored).
    if (dbg.on("global.trace") and idx < call_profile.max_globals) {
        const addr: u64 = @intFromPtr(&call_profile.g_last[idx]);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(16, @truncate(addr)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, @truncate(addr >> 16), 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, @truncate(addr >> 32), 2));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, @truncate(addr >> 48), 3));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(ws, 16, 0));
        // bump g_count[idx] (X16=addr, X17=loaded count); both IP regs, short-lived.
        const caddr: u64 = @intFromPtr(&call_profile.g_count[idx]);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(16, @truncate(caddr)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, @truncate(caddr >> 16), 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, @truncate(caddr >> 32), 2));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, @truncate(caddr >> 48), 3));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(17, 16, 0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(17, 16, 0));
    }
}

/// i64 global.get — X-form `LDR Xd, [X23, #byte_off]`. The X-form
/// imm12 scales by 8, so max byte_offset = 8 * 4095 = 32760
/// (≈4095 8-byte globals fit immediate-form addressing).
fn emitI64GlobalGet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 32760 or (byte_off & 7) != 0) {
        dbg.print("codegen", "arm64/op_globals: i64 global.get SlotOverflow func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const xd = try gpr.gprDefSpilled(ctx.alloc, result, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(xd, abi.globals_base_save_gpr, @intCast(byte_off)));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

fn emitI64GlobalSet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 32760 or (byte_off & 7) != 0) {
        dbg.print("codegen", "arm64/op_globals: i64 global.set SlotOverflow func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = ctx.pushed_vregs.pop().?;
    const xs = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(xs, abi.globals_base_save_gpr, @intCast(byte_off)));
}

/// f32 global.get — S-form `LDR Sd, [X23, #byte_off]` into a fresh
/// FP vreg. The 8-byte slot stride is 4-aligned by construction
/// (S-form imm12 scales by 4). The producer vreg is FP-class;
/// downstream FP-op handlers (f32.add etc.) read it as FPR.
fn emitF32GlobalGet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 16380 or (byte_off & 3) != 0) {
        dbg.print("codegen", "arm64/op_globals: f32 global.get SlotOverflow func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const vd = try gpr.fpDefSpilled(ctx.alloc, result, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrSImm(vd, abi.globals_base_save_gpr, @intCast(byte_off)));
    try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

fn emitF32GlobalSet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 16380 or (byte_off & 3) != 0) {
        dbg.print("codegen", "arm64/op_globals: f32 global.set SlotOverflow func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = ctx.pushed_vregs.pop().?;
    const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrSImm(vs, abi.globals_base_save_gpr, @intCast(byte_off)));
}

/// f64 global.get — D-form `LDR Dd, [X23, #byte_off]`. 8-aligned;
/// imm12 scales by 8 (max 32760).
fn emitF64GlobalGet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 32760 or (byte_off & 7) != 0) {
        dbg.print("codegen", "arm64/op_globals: f64 global.get SlotOverflow func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const vd = try gpr.fpDefSpilled(ctx.alloc, result, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrDImm(vd, abi.globals_base_save_gpr, @intCast(byte_off)));
    try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

fn emitF64GlobalSet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 32760 or (byte_off & 7) != 0) {
        dbg.print("codegen", "arm64/op_globals: f64 global.set SlotOverflow func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = ctx.pushed_vregs.pop().?;
    const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrDImm(vs, abi.globals_base_save_gpr, @intCast(byte_off)));
}

/// `global.get N` (v128) — load 16 bytes from `[X23 + byte_off]`
/// into a fresh v128 vreg via `LDR Q`. ADR-0052 §3 — imm12 in
/// Q-form scales by 16 with max byte_off = 16 * 4095 = 65520
/// (~4095 v128 globals fit immediate-form addressing; beyond
/// that, escalation TBD).
fn emitV128GlobalGet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 65520) {
        dbg.print("codegen", "arm64/op_globals: v128 global.get SlotOverflow func[{d}] idx={d} byte_off={d}>65520\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }
    if ((byte_off & 0xF) != 0) {
        // Q-form imm12 scales by 16; encoder shifts >> 4.
        dbg.print("codegen", "arm64/op_globals: v128 global.get UnalignedOffset func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.UnsupportedOp;
    }

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrQImm(result_v, abi.globals_base_save_gpr, @intCast(byte_off)));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `global.set N` (v128) — pop a v128 vreg, store 16 bytes to
/// `[X23 + byte_off]` via `STR Q`.
fn emitV128GlobalSet(ctx: *EmitCtx, idx: u32, byte_off: u32) Error!void {
    if (byte_off > 65520) {
        dbg.print("codegen", "arm64/op_globals: v128 global.set SlotOverflow func[{d}] idx={d} byte_off={d}>65520\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.SlotOverflow;
    }
    if ((byte_off & 0xF) != 0) {
        dbg.print("codegen", "arm64/op_globals: v128 global.set UnalignedOffset func[{d}] idx={d} byte_off={d}\n", .{ ctx.func.func_idx, idx, byte_off });
        return Error.UnsupportedOp;
    }

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encStrQImm(src_v, abi.globals_base_save_gpr, @intCast(byte_off)));
}
