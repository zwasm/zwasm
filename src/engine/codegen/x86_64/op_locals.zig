//! x86_64 local-ops emit handlers: `local.get` / `local.set` /
//! `local.tee`.
//!
//! Wasm spec §3.5.3 / §4.4.5.{1,2,3}. Per-local RBP-relative
//! storage; valtype-dispatched 4 / 8 / 16-byte slot transfer.
//!
//! Reads ctx.{func, alloc, pushed_vregs, next_vreg,
//! spill_base_off, total_locals, local_disps, allocator, buf}.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const inst = @import("inst.zig");
const rbp_disp = @import("rbp_disp.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;
const ZirFunc = zir.ZirFunc;

const rbpStoreR32 = rbp_disp.rbpStoreR32;
const rbpLoadR32 = rbp_disp.rbpLoadR32;
const rbpStoreR64 = rbp_disp.rbpStoreR64;
const rbpLoadR64 = rbp_disp.rbpLoadR64;
const rbpStoreXmmF32 = rbp_disp.rbpStoreXmmF32;
const rbpLoadXmmF32 = rbp_disp.rbpLoadXmmF32;
const rbpStoreXmmF64 = rbp_disp.rbpStoreXmmF64;
const rbpLoadXmmF64 = rbp_disp.rbpLoadXmmF64;
const rbpStoreXmmV128 = rbp_disp.rbpStoreXmmV128;
const rbpLoadXmmV128 = rbp_disp.rbpLoadXmmV128;

/// `local.get K` — push a fresh vreg holding the value loaded
/// from [RBP + local_disps[K]].
pub fn emitLocalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    func: *const ZirFunc,
    total_locals: u32,
    disps: []const i32,
    idx: u32,
) Error!void {
    if (idx >= total_locals) return Error.UnsupportedOp;
    const disp = disps[idx];
    const vreg = next_vreg.*;
    next_vreg.* += 1;
    if (vreg >= alloc.slots.len) return Error.SlotOverflow;
    switch (func.localValType(idx)) {
        .i32 => {
            const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadR32(dst_r, disp).slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .i64, .ref => {
            const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadR64(dst_r, disp).slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .f32 => {
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadXmmF32(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .f64 => {
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadXmmF64(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .v128 => {
            const dst_x = try gpr.xmmDefSpilledV128(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadXmmV128(dst_x, disp).slice());
            try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
    }
    try pushed_vregs.append(allocator, vreg);
}

/// `local.set K` — pop the top vreg and store its value into
/// [RBP + local_disps[K]].
pub fn emitLocalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    total_locals: u32,
    disps: []const i32,
    idx: u32,
) Error!void {
    if (idx >= total_locals) return Error.UnsupportedOp;
    const disp = disps[idx];
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    switch (func.localValType(idx)) {
        .i32 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR32(disp, src_r).slice());
        },
        .i64, .ref => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR64(disp, src_r).slice());
        },
        .f32 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF32(disp, src_x).slice());
        },
        .f64 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF64(disp, src_x).slice());
        },
        .v128 => {
            const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmV128(disp, src_x).slice());
        },
    }
}

/// `local.tee K` — store the top vreg's value into
/// [RBP + local_disps[K]] WITHOUT popping.
pub fn emitLocalTee(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    total_locals: u32,
    disps: []const i32,
    idx: u32,
) Error!void {
    if (idx >= total_locals) return Error.UnsupportedOp;
    const disp = disps[idx];
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.items[pushed_vregs.items.len - 1];
    switch (func.localValType(idx)) {
        .i32 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR32(disp, src_r).slice());
        },
        .i64, .ref => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR64(disp, src_r).slice());
        },
        .f32 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF32(disp, src_x).slice());
        },
        .f64 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF64(disp, src_x).slice());
        },
        .v128 => {
            const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmV128(disp, src_x).slice());
        },
    }
}

/// ADR-0155 stage 4 (D-265 Phase IV) — homed `local.get`: read the home
/// register into the fresh temporary via reg→reg MOV (no LOAD-from-slot). The
/// fresh temp insulates this value from a later `local.set $same` (which
/// rewrites the home register) and keeps `next_vreg` in lockstep with liveness.
/// i32/i64 share the 64-bit MOV: an i32 home holds a zero-extended value (the
/// prologue seed + the W-form set MOV below), so the full-width copy is correct.
/// Mirror of arm64/emit.zig's homed local.get.
fn emitHomedLocalGet(ctx: *ctx_mod.EmitCtx, home_vreg: u32) Error!void {
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const src_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, home_vreg, 0);
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, vreg, 1);
    try gpr.writeBytes(ctx.allocator, ctx.buf, inst.encMovRR(.q, dst_r, src_r));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// ADR-0155 stage 4 — homed `local.set` (`pop` = true) / `local.tee`
/// (`pop` = false): MOV the source temporary into the home register (reg→reg,
/// no STORE-to-slot). i32 uses the 32-bit MOV so the home stays zero-extended;
/// i64 the 64-bit MOV. Mirror of arm64/emit.zig's homed local.set/tee.
fn emitHomedLocalSetTee(ctx: *ctx_mod.EmitCtx, home_vreg: u32, local_idx: u32, pop: bool) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = if (pop) ctx.pushed_vregs.pop().? else ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
    const src_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, home_vreg, 1);
    const width: inst.Width = switch (ctx.func.localValType(local_idx)) {
        .i32 => .d,
        .i64 => .q,
        // local_homing.isHomeableType only homes i32/i64.
        .f32, .f64, .v128, .ref => unreachable,
    };
    try gpr.writeBytes(ctx.allocator, ctx.buf, inst.encMovRR(width, dst_r, src_r));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, home_vreg, 1);
}

/// `(ctx, ins)` adapter for `local.get`.
///
/// Wasm spec §3.5.3 / §4.4.5.1.
pub fn emitLocalGetCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const idx: u32 = @intCast(ins.payload);
    if (idx >= ctx.total_locals) return Error.UnsupportedOp;
    // ADR-0155 stage 4 — register-homed local: reg→reg MOV, no slot LOAD.
    if (ctx.homing.pseudoVreg(idx, ctx.n_temp)) |home_vreg| {
        return emitHomedLocalGet(ctx, home_vreg);
    }
    return emitLocalGet(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ctx.func,
        ctx.total_locals,
        ctx.local_disps,
        @as(u32, @intCast(ins.payload)),
    );
}

/// `(ctx, ins)` adapter for `local.set`.
///
/// Wasm spec §3.5.3 / §4.4.5.2.
pub fn emitLocalSetCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const idx: u32 = @intCast(ins.payload);
    if (idx >= ctx.total_locals) return Error.UnsupportedOp;
    // ADR-0155 stage 4 — register-homed local: reg→reg MOV into home, no STORE.
    if (ctx.homing.pseudoVreg(idx, ctx.n_temp)) |home_vreg| {
        return emitHomedLocalSetTee(ctx, home_vreg, idx, true);
    }
    return emitLocalSet(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.spill_base_off,
        ctx.func,
        ctx.total_locals,
        ctx.local_disps,
        @as(u32, @intCast(ins.payload)),
    );
}

/// `(ctx, ins)` adapter for `local.tee`.
///
/// Wasm spec §3.5.3 / §4.4.5.3.
pub fn emitLocalTeeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const idx: u32 = @intCast(ins.payload);
    if (idx >= ctx.total_locals) return Error.UnsupportedOp;
    // ADR-0155 stage 4 — register-homed local: MOV the peeked src into home.
    if (ctx.homing.pseudoVreg(idx, ctx.n_temp)) |home_vreg| {
        return emitHomedLocalSetTee(ctx, home_vreg, idx, false);
    }
    return emitLocalTee(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.spill_base_off,
        ctx.func,
        ctx.total_locals,
        ctx.local_disps,
        @as(u32, @intCast(ins.payload)),
    );
}
