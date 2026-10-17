//! x86_64 emit pass — GPR / XMM resolution + spill staging
//! helpers shared across every op-handler module.
//!
//! Mirror of `arm64/gpr.zig` (per ADR-0023 §3 + ADR-0021 sub-
//! deliverable b) — extracted so op_const / op_alu / op_memory /
//! etc. can reach for these helpers without importing emit.zig.
//!
//! - `writeBytes` — append an x86_64-encoded instruction's bytes
//!   (`EncodedInsn` from `inst.zig`) to the buffer.
//! - `resolveGpr` — vreg → physical Gpr (declines spilled vregs;
//!   the bare-resolution shape used by handlers that haven't been
//!   migrated to spill-aware emission).
//! - `gprLoadSpilled` — spill-aware operand load via stage reg.
//! - `gprDefSpilled` — spill-aware result def via stage reg.
//! - `gprStoreSpilled` — pair of `gprDefSpilled`; flushes stage
//!   reg to spill slot.
//! - `resolveXmm` — XMM-class counterpart of `resolveGpr`.
//! - `xmmLoadSpilled` / `xmmDefSpilled` / `xmmStoreSpilled` —
//!   XMM-class spill-staging trio (mirrors `fpLoadSpilled` etc.
//!   in arm64; uses `abi.fp_spill_stage_xmms` (XMM14/XMM15) and
//!   the F64 spill encoders for class-uniform 8-byte stride).
//!
//! **Spill frame addressing**: x86_64 places locals + spills
//! BELOW RBP (frame grows down). `spill_base_off` is the byte
//! distance from RBP to the start of the spill area; the load /
//! store encoder takes `disp = -(spill_base_off + spill_off)` as
//! a signed i8. With disp8 (-128..127), the spill frame supports
//! up to 16 slots (8-byte stride). disp32 fallback lands in a
//! follow-up chunk if a fixture exceeds disp8 range.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");

const inst = @import("inst.zig");
const abi = @import("abi.zig");
const regalloc = @import("../shared/regalloc.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;
const Gpr = abi.Gpr;
const Xmm = abi.Xmm;

/// Append `enc.bytes[0..enc.len]` to `buf`. Mirrors arm64's
/// `writeU32` but x86_64 instructions are variable-length, so
/// the encoder returns a length-prefixed array (`EncodedInsn`).
pub fn writeBytes(allocator: Allocator, buf: *std.ArrayList(u8), enc: inst.EncodedInsn) !void {
    try buf.appendSlice(allocator, enc.bytes[0..enc.len]);
}

/// Convert a u32 RBP-relative
/// spill distance into the i32 disp the encoders consume. The
/// `[RBP - (spill_base_off + spill_off)]` address must be 8-byte
/// aligned (we use 8-byte spill stride uniformly across both
/// classes). The i32 disp form lifts the spill-region cap to
/// ~268 M slots (an i8 form would cap it at 16 slots), matching
/// the locals-side `localDisp` widening.
fn rbpDispNegI32(spill_base_off: u32, spill_off: u32) Error!i32 {
    const abs = spill_base_off + spill_off;
    if (abs == 0 or (abs & 7) != 0) return Error.SlotOverflow;
    if (abs > 0x7FFF_FFFF) return Error.SlotOverflow;
    return -@as(i32, @intCast(abs));
}

/// Pick disp8 / disp32 form per offset range. Mirrors emit.zig's
/// local-region auto-helpers (`rbpLoadR64`/`rbpStoreR64`/etc.)
/// but kept in gpr.zig so spill helpers don't cross-import. Cost:
/// 4 bytes (disp8) when the spill slot fits in i8, 7 bytes
/// (disp32) otherwise.
fn rbpLoadR64Auto(dst: inst.Gpr, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadR64MemRBP(dst, @intCast(disp));
    return inst.encLoadR64MemRBPDisp32(dst, disp);
}
fn rbpStoreR64Auto(disp: i32, src: inst.Gpr) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreR64MemRBP(@intCast(disp), src);
    return inst.encStoreR64MemRBPDisp32(disp, src);
}
fn rbpLoadXmmF64Auto(dst: inst.Xmm, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadXmmF64MemRBP(dst, @intCast(disp));
    return inst.encLoadXmmF64MemRBPDisp32(dst, disp);
}
fn rbpStoreXmmF64Auto(disp: i32, src: inst.Xmm) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreXmmF64MemRBP(@intCast(disp), src);
    return inst.encStoreXmmF64MemRBPDisp32(disp, src);
}
/// ADR-0053 Part 2 — 128-bit unaligned packed-
/// single load `MOVUPS xmm, [RBP + disp]`. Picks the disp8 form
/// when the offset fits in -128..127, else the disp32 form, mirror
/// of the F64 variant. Used by `xmmLoadSpilledV128`. The MOVUPS
/// instruction itself is unaligned-tolerant; alignment matters
/// only for the allocator's spill-region layout (16-byte stride
/// for v128 slots per `Allocation.spill_offsets`).
fn rbpLoadXmmV128Auto(dst: inst.Xmm, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadXmmV128MemRBP(dst, @intCast(disp));
    return inst.encLoadXmmV128MemRBPDisp32(dst, disp);
}
fn rbpStoreXmmV128Auto(disp: i32, src: inst.Xmm) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreXmmV128MemRBP(@intCast(disp), src);
    return inst.encStoreXmmV128MemRBPDisp32(disp, src);
}

/// Resolve a vreg's home register (GPR class). Returns the
/// allocated reg or `Error.UnsupportedOp` for spilled vregs
/// (handlers that haven't been migrated to spill-aware emission).
pub fn resolveGpr(alloc: regalloc.Allocation, vreg: usize) Error!Gpr {
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => blk: {
            dbg.print(
                "codegen",
                "x86_64/gpr: resolveGpr rejected spilled vreg={d} (handler not spill-aware)\n",
                .{vreg},
            );
            break :blk Error.UnsupportedOp;
        },
    };
}

/// Resolve a vreg's home for **op operand load**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// emits `MOV r64, [RBP - (spill_base_off + spill_off)]` staging
/// through `abi.spill_stage_gprs[stage_idx]` (R10/R11) and
/// returns the stage reg.
///
/// `stage_idx` selects which stage reg (0=R10, 1=R11). Use 0 for
/// the first/only operand, 1 for the second operand of a binary
/// op (so two spilled operands don't collide).
pub fn gprLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!Gpr {
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => |off| blk: {
            const stage = abi.spill_stage_gprs[stage_idx];
            const disp = try rbpDispNegI32(spill_base_off, off);
            try writeBytes(allocator, buf, rbpLoadR64Auto(stage, disp));
            break :blk stage;
        },
    };
}

/// Resolve a vreg's home for **op result def**. If the vreg is
/// in a register, returns that reg directly. If spilled, returns
/// the stage reg (caller encodes the op writing into it; then
/// calls `gprStoreSpilled` to flush to the spill slot).
pub fn gprDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!Gpr {
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => abi.spill_stage_gprs[stage_idx],
    };
}

/// Pair of `gprDefSpilled`. After encoding the op (which wrote
/// the result into the stage reg), emits `MOV [RBP - (spill_base_
/// off + spill_off)], r64`. No-op for vregs in registers.
pub fn gprStoreSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg, .gpr)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.spill_stage_gprs[stage_idx];
            const disp = try rbpDispNegI32(spill_base_off, off);
            try writeBytes(allocator, buf, rbpStoreR64Auto(disp, stage));
        },
    }
}

/// XMM-class counterpart of `resolveGpr`. Consults the class-
/// aware `Allocation.slot(vreg, .fpr)` API (D-036): the FP
/// boundary `max_reg_slots_fp` (default 8, matching
/// `abi.allocatable_xmms.len`) decides reg-vs-spill, distinct
/// from the GPR boundary.
pub fn resolveXmm(alloc: regalloc.Allocation, vreg: usize) Error!Xmm {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => |off| blk: {
            dbg.print(
                "codegen",
                "x86_64/gpr: resolveXmm rejected spilled vreg={d} spill_off={d} (handler not XMM-spill-aware)\n",
                .{ vreg, off },
            );
            break :blk Error.UnsupportedOp;
        },
    };
}

/// XMM-class counterpart of `gprLoadSpilled`. If the FP vreg is
/// in an XMM register, returns that reg directly. If spilled,
/// emits `MOVSD xmm, [RBP - (spill_base_off + spill_off)]`
/// staging through `abi.fp_spill_stage_xmms[stage_idx]`
/// (XMM14/XMM15) and returns the stage reg.
///
/// MOVSD (F64 form) is used uniformly so the spill stride matches
/// the GPR (8-byte) stride — a spilled f32 vreg writes 64 bits
/// with the upper 32 bits unspecified, but the load reads the
/// same 64 bits and SS-form ops on the resulting XMM ignore the
/// upper 32 bits.
pub fn xmmLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!Xmm {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => |off| blk: {
            const stage = abi.fp_spill_stage_xmms[stage_idx];
            const disp = try rbpDispNegI32(spill_base_off, off);
            try writeBytes(allocator, buf, rbpLoadXmmF64Auto(stage, disp));
            break :blk stage;
        },
    };
}

/// XMM-class counterpart of `gprDefSpilled`.
pub fn xmmDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!Xmm {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => abi.fp_spill_stage_xmms[stage_idx],
    };
}

/// ADR-0053 Part 2 — v128 counterpart of
/// `xmmLoadSpilled`. If the FP vreg is in an XMM register,
/// returns that reg directly. If spilled, emits
/// `MOVUPS xmm, [RBP - (spill_base_off + spill_off)]` staging
/// through `abi.fp_spill_stage_xmms[stage_idx]` (XMM14/XMM15)
/// and returns the stage reg.
///
/// MOVUPS reads/writes a full 128-bit chunk; the allocator's
/// `Allocation.spill_offsets` table (ADR-0053 Part 1) gives the
/// v128 vreg's spill slot 16-byte stride so the resulting access
/// never overlaps a neighbouring slot.
///
/// Distinct from `xmmLoadSpilled` (which uses MOVSD's 8-byte
/// stride and is correct for f32/f64 only) — Part 3 handler
/// migration switches v128-class call sites from `resolveXmm`
/// to this helper.
pub fn xmmLoadSpilledV128(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!Xmm {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => |off| blk: {
            const stage = abi.fp_spill_stage_xmms[stage_idx];
            const disp = try rbpDispNegI32(spill_base_off, off);
            try writeBytes(allocator, buf, rbpLoadXmmV128Auto(stage, disp));
            break :blk stage;
        },
    };
}

/// ADR-0053 Part 2 — v128 counterpart of `xmmDefSpilled`. Returns
/// the home XMM when not spilled, else the stage reg (caller
/// encodes the op writing into it, then calls
/// `xmmStoreSpilledV128` to flush).
pub fn xmmDefSpilledV128(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!Xmm {
    // Identical to `xmmDefSpilled`: a "def" emits no load/store (just picks the
    // home XMM or the stage reg), so v128 and scalar share one body — width only
    // matters at the load/store pair (`xmmLoadSpilledV128`/`xmmStoreSpilledV128`).
    // Kept as a distinct name so v128 call sites read intent-clearly.
    return xmmDefSpilled(alloc, vreg, stage_idx);
}

/// ADR-0053 Part 2 — pair of `xmmDefSpilledV128`. Emits
/// `MOVUPS [RBP - (spill_base_off + spill_off)], xmm` from the
/// stage reg. No-op for in-XMM-reg vregs.
pub fn xmmStoreSpilledV128(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg, .fpr)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.fp_spill_stage_xmms[stage_idx];
            const disp = try rbpDispNegI32(spill_base_off, off);
            try writeBytes(allocator, buf, rbpStoreXmmV128Auto(disp, stage));
        },
    }
}

/// Pair of `xmmDefSpilled`. Emits `MOVSD [RBP - (spill_base_off
/// + spill_off)], xmm` from the stage reg. No-op for in-XMM-reg
/// vregs.
pub fn xmmStoreSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg, .fpr)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.fp_spill_stage_xmms[stage_idx];
            const disp = try rbpDispNegI32(spill_base_off, off);
            try writeBytes(allocator, buf, rbpStoreXmmF64Auto(disp, stage));
        },
    }
}

/// A set of writes into fixed registers that must all read their sources
/// before any of them lands: a call's argument marshal, where an operand may
/// sit in the register another argument goes to (#503). `emit` orders the
/// moves so no register is overwritten while a pending move still reads it;
/// a cycle is broken through RAX, which is in no pool and no argument set.
/// With no conflict the moves come out in queue order.
pub const ParallelMove = struct {
    pub const Src = union(enum) {
        reg: Gpr,
        /// Loaded through stage 0 (R10), which no queued move reads.
        spilled: u32,
        /// `LEA dst, [RSP + disp]` — the Win64 v128 hidden pointer.
        lea_rsp: i32,
    };
    const Move = struct { dst: Gpr, src: Src, width: inst.Width };
    const cap = 8;
    const park: Gpr = .rax;

    moves: [cap]Move = undefined,
    len: u8 = 0,

    /// Queue `dst ← vreg`, from its register or its spill slot.
    pub fn addVreg(self: *ParallelMove, alloc: regalloc.Allocation, dst: Gpr, vreg: u32, width: inst.Width) Error!void {
        const src: Src = switch (alloc.slot(vreg, .gpr)) {
            .reg => |id| .{ .reg = abi.slotToReg(id) orelse return Error.SlotOverflow },
            .spill => .{ .spilled = vreg },
        };
        self.add(dst, src, width);
    }

    /// Each destination is written once per set.
    pub fn add(self: *ParallelMove, dst: Gpr, src: Src, width: inst.Width) void {
        std.debug.assert(dst != park);
        if (src == .reg and src.reg == dst) return;
        std.debug.assert(self.len < cap);
        self.moves[self.len] = .{ .dst = dst, .src = src, .width = width };
        self.len += 1;
    }

    fn readByOther(self: *const ParallelMove, r: Gpr, skip: usize) bool {
        for (self.moves[0..self.len], 0..) |m, i| {
            if (i != skip and m.src == .reg and m.src.reg == r) return true;
        }
        return false;
    }

    pub fn emit(
        self: *ParallelMove,
        allocator: Allocator,
        buf: *std.ArrayList(u8),
        alloc: regalloc.Allocation,
        spill_base_off: u32,
    ) Error!void {
        while (self.len > 0) {
            const ready: usize = for (self.moves[0..self.len], 0..) |m, i| {
                if (!self.readByOther(m.dst, i)) break i;
            } else blk: {
                // Every pending destination is still read, so the register
                // sources form a cycle. Park the first destination's value
                // and point its readers at the copy; that move is then free.
                const d = self.moves[0].dst;
                try writeBytes(allocator, buf, inst.encMovRR(.q, park, d));
                for (self.moves[0..self.len]) |*m| {
                    if (m.src == .reg and m.src.reg == d) m.src = .{ .reg = park };
                }
                break :blk 0;
            };
            const m = self.moves[ready];
            switch (m.src) {
                .reg => |r| try writeBytes(allocator, buf, inst.encMovRR(m.width, m.dst, r)),
                .spilled => |v| {
                    const r = try gprLoadSpilled(allocator, buf, alloc, spill_base_off, v, 0);
                    try writeBytes(allocator, buf, inst.encMovRR(m.width, m.dst, r));
                },
                .lea_rsp => |disp| try writeBytes(allocator, buf, inst.encLeaR64BaseRspDisp32(m.dst, disp)),
            }
            std.mem.copyForwards(Move, self.moves[ready .. self.len - 1], self.moves[ready + 1 .. self.len]);
            self.len -= 1;
        }
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "rbpDispNegI32: spill_base_off=8 + off=0 → disp=-8" {
    try testing.expectEqual(@as(i32, -8), try rbpDispNegI32(8, 0));
}

test "rbpDispNegI32: spill_base_off=64 + off=8 → disp=-72" {
    try testing.expectEqual(@as(i32, -72), try rbpDispNegI32(64, 8));
}

test "rbpDispNegI32: spill_base_off=120 + off=8 = 128 → disp=-128 (boundary)" {
    try testing.expectEqual(@as(i32, -128), try rbpDispNegI32(120, 8));
}

test "rbpDispNegI32: spill_base_off=200 + off=8 = 208 → disp=-208 (past i8 range)" {
    // Regression — before the i32 disp form, any spill region
    // whose deepest slot exceeded -128 surfaced SlotOverflow.
    try testing.expectEqual(@as(i32, -208), try rbpDispNegI32(200, 8));
}

test "rbpDispNegI32: misaligned (not 8-multiple) → SlotOverflow" {
    try testing.expectError(Error.SlotOverflow, rbpDispNegI32(8, 4));
}

test "rbpDispNegI32: zero distance (no spill area) → SlotOverflow" {
    try testing.expectError(Error.SlotOverflow, rbpDispNegI32(0, 0));
}

test "gprLoadSpilled: vreg in reg returns slotToReg without emitting bytes" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const r = try gprLoadSpilled(testing.allocator, &buf, alloc, 8, 0, 0);
    try testing.expectEqual(abi.allocatable_gprs[0], r);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "gprLoadSpilled: spilled vreg emits MOV r10, [rbp+disp] (stage_idx=0)" {
    const pool_len: u8 = abi.allocatable_gprs.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const r = try gprLoadSpilled(testing.allocator, &buf, alloc, 8, 0, 0);
    try testing.expectEqual(Gpr.r10, r);
    const expected = inst.encLoadR64MemRBP(.r10, -8);
    try testing.expectEqual(@as(usize, expected.len), buf.items.len);
    try testing.expectEqualSlices(u8, expected.bytes[0..expected.len], buf.items);
}

test "gprLoadSpilled: stage_idx=1 yields R11" {
    const pool_len: u8 = abi.allocatable_gprs.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const r = try gprLoadSpilled(testing.allocator, &buf, alloc, 8, 0, 1);
    try testing.expectEqual(Gpr.r11, r);
}

test "gprStoreSpilled: spilled vreg emits MOV [rbp+disp], r10" {
    const pool_len: u8 = abi.allocatable_gprs.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try gprStoreSpilled(testing.allocator, &buf, alloc, 8, 0, 0);
    const expected = inst.encStoreR64MemRBP(-8, .r10);
    try testing.expectEqual(@as(usize, expected.len), buf.items.len);
    try testing.expectEqualSlices(u8, expected.bytes[0..expected.len], buf.items);
}

test "gprStoreSpilled: in-reg vreg emits no bytes" {
    const slots = [_]u16{2};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try gprStoreSpilled(testing.allocator, &buf, alloc, 8, 0, 0);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "gprDefSpilled: in-reg vreg returns home; spilled returns stage" {
    const pool_len: u8 = abi.allocatable_gprs.len;
    const slots = [_]u16{ 3, pool_len };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
    };
    try testing.expectEqual(abi.allocatable_gprs[3], try gprDefSpilled(alloc, 0, 0));
    try testing.expectEqual(Gpr.r10, try gprDefSpilled(alloc, 1, 0));
    try testing.expectEqual(Gpr.r11, try gprDefSpilled(alloc, 1, 1));
}

test "xmmLoadSpilled: spilled vreg emits MOVSD xmm14, [rbp+disp]" {
    const pool_len: u8 = abi.allocatable_xmms.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        // x86_64 FP pool (6) is smaller than the
        // arm64-tuned default GPR boundary (8). Set both explicitly
        // so the shared `Allocation.slot()` spill formula
        // `(id - max_reg_slots_gpr)` doesn't underflow.
        .max_reg_slots_gpr = pool_len,
        .max_reg_slots_fp = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const r = try xmmLoadSpilled(testing.allocator, &buf, alloc, 8, 0, 0);
    try testing.expectEqual(Xmm.xmm14, r);
    const expected = inst.encLoadXmmF64MemRBP(.xmm14, -8);
    try testing.expectEqual(@as(usize, expected.len), buf.items.len);
    try testing.expectEqualSlices(u8, expected.bytes[0..expected.len], buf.items);
}

test "xmmStoreSpilled: spilled vreg emits MOVSD [rbp+disp], xmm14" {
    const pool_len: u8 = abi.allocatable_xmms.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
        .max_reg_slots_fp = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try xmmStoreSpilled(testing.allocator, &buf, alloc, 8, 0, 0);
    const expected = inst.encStoreXmmF64MemRBP(-8, .xmm14);
    try testing.expectEqual(@as(usize, expected.len), buf.items.len);
    try testing.expectEqualSlices(u8, expected.bytes[0..expected.len], buf.items);
}

test "xmmLoadSpilledV128: spilled vreg emits MOVUPS xmm14, [rbp+disp]" {
    // ADR-0053 Part 2: v128 spill-aware load emits MOVUPS (16
    // bytes, 0F 10) — contrast with `xmmLoadSpilled` (MOVSD, F2 0F
    // 10, 8 bytes). The disp here is small (-16) so we get the
    // disp8 form.
    const pool_len: u8 = abi.allocatable_xmms.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
        .max_reg_slots_fp = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const r = try xmmLoadSpilledV128(testing.allocator, &buf, alloc, 16, 0, 0);
    try testing.expectEqual(Xmm.xmm14, r);
    const expected = inst.encLoadXmmV128MemRBP(.xmm14, -16);
    try testing.expectEqual(@as(usize, expected.len), buf.items.len);
    try testing.expectEqualSlices(u8, expected.bytes[0..expected.len], buf.items);
}

test "xmmStoreSpilledV128: spilled vreg emits MOVUPS [rbp+disp], xmm14" {
    const pool_len: u8 = abi.allocatable_xmms.len;
    const slots = [_]u16{pool_len};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = pool_len + 1,
        .max_reg_slots_gpr = pool_len,
        .max_reg_slots_fp = pool_len,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try xmmStoreSpilledV128(testing.allocator, &buf, alloc, 16, 0, 0);
    const expected = inst.encStoreXmmV128MemRBP(-16, .xmm14);
    try testing.expectEqual(@as(usize, expected.len), buf.items.len);
    try testing.expectEqualSlices(u8, expected.bytes[0..expected.len], buf.items);
}

test "xmmDefSpilledV128: spilled vreg returns xmm14 stage; in-reg returns home" {
    // Spilled case
    {
        const pool_len: u8 = abi.allocatable_xmms.len;
        const slots = [_]u16{pool_len};
        const alloc: regalloc.Allocation = .{
            .slots = &slots,
            .n_slots = pool_len + 1,
            .max_reg_slots_gpr = pool_len,
            .max_reg_slots_fp = pool_len,
        };
        try testing.expectEqual(Xmm.xmm14, try xmmDefSpilledV128(alloc, 0, 0));
        try testing.expectEqual(Xmm.xmm15, try xmmDefSpilledV128(alloc, 0, 1));
    }
    // In-reg case: vreg 0 → slot 0 → first allocatable XMM.
    {
        const slots = [_]u16{0};
        const alloc: regalloc.Allocation = .{
            .slots = &slots,
            .n_slots = 1,
        };
        try testing.expectEqual(abi.allocatable_xmms[0], try xmmDefSpilledV128(alloc, 0, 0));
    }
}

test "xmmLoadSpilledV128: in-reg vreg returns home XMM without emitting bytes" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const r = try xmmLoadSpilledV128(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(abi.allocatable_xmms[0], r);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

/// Seed RSI=1, RDI=2, R8=3, R9=4, run `pm`, then return the destinations
/// packed one byte each, `dsts[0]` highest. Executes the bytes, so x86_64 only.
fn runParallelMove(pm: *ParallelMove, dsts: []const Gpr) !u64 {
    const jit_mem = @import("../../../platform/jit_mem.zig");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const a = testing.allocator;
    // RSI/RDI are callee-saved on Win64.
    try writeBytes(a, &buf, inst.encPushR(.rsi));
    try writeBytes(a, &buf, inst.encPushR(.rdi));
    for ([_]Gpr{ .rsi, .rdi, .r8, .r9 }, 1..) |r, v| try writeBytes(a, &buf, inst.encMovImm64Q(r, v));
    try pm.emit(a, &buf, .{ .slots = &.{}, .n_slots = 0 }, 0);
    try writeBytes(a, &buf, inst.encMovRR(.q, .rax, dsts[0]));
    for (dsts[1..]) |d| {
        try writeBytes(a, &buf, inst.encShlRImm8(.q, .rax, 8));
        try writeBytes(a, &buf, inst.encAddRR(.q, .rax, d));
    }
    try writeBytes(a, &buf, inst.encPopR(.rdi));
    try writeBytes(a, &buf, inst.encPopR(.rsi));
    try writeBytes(a, &buf, inst.encRet());

    const block = try jit_mem.alloc(buf.items.len);
    defer jit_mem.free(block);
    @memcpy(block.bytes[0..buf.items.len], buf.items);
    try jit_mem.setExecutable(block);
    return block.asFnPtr(*const fn () callconv(.c) u64)();
}

test "ParallelMove: a source in a later destination is read before it is overwritten" {
    // SIBLING-AT: src/engine/codegen/arm64/op_call.zig (X0-X7 are outside the arm64 pool; no conflict to order)
    if (comptime @import("builtin").cpu.arch != .x86_64) return;
    // Queue order puts each write ahead of the move that still reads it.
    var pm: ParallelMove = .{};
    pm.add(.rsi, .{ .reg = .r9 }, .q);
    pm.add(.r8, .{ .reg = .rsi }, .q);
    pm.add(.r9, .{ .reg = .rdi }, .q);
    try testing.expectEqual(@as(u64, 0x04_01_02), try runParallelMove(&pm, &.{ .rsi, .r8, .r9 }));
}

test "ParallelMove: a two-register swap goes through RAX" {
    // SIBLING-AT: src/engine/codegen/arm64/op_call.zig (X0-X7 are outside the arm64 pool; no conflict to order)
    if (comptime @import("builtin").cpu.arch != .x86_64) return;
    var pm: ParallelMove = .{};
    pm.add(.rsi, .{ .reg = .rdi }, .q);
    pm.add(.rdi, .{ .reg = .rsi }, .q);
    try testing.expectEqual(@as(u64, 0x02_01), try runParallelMove(&pm, &.{ .rsi, .rdi }));
}

test "ParallelMove: a three-register rotate" {
    // SIBLING-AT: src/engine/codegen/arm64/op_call.zig (X0-X7 are outside the arm64 pool; no conflict to order)
    if (comptime @import("builtin").cpu.arch != .x86_64) return;
    var pm: ParallelMove = .{};
    pm.add(.rsi, .{ .reg = .rdi }, .d);
    pm.add(.rdi, .{ .reg = .r8 }, .d);
    pm.add(.r8, .{ .reg = .rsi }, .d);
    try testing.expectEqual(@as(u64, 0x02_03_01), try runParallelMove(&pm, &.{ .rsi, .rdi, .r8 }));
}

test "ParallelMove: with no conflict the moves keep queue order" {
    var pm: ParallelMove = .{};
    pm.add(.rsi, .{ .reg = .rbx }, .d);
    pm.add(.rdx, .{ .reg = .r12 }, .q);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pm.emit(testing.allocator, &buf, .{ .slots = &.{}, .n_slots = 0 }, 0);
    const a = inst.encMovRR(.d, .rsi, .rbx);
    const b = inst.encMovRR(.q, .rdx, .r12);
    try testing.expectEqualSlices(u8, a.slice(), buf.items[0..a.len]);
    try testing.expectEqualSlices(u8, b.slice(), buf.items[a.len..]);
}
