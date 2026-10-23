//! ARM64 emit pass — GPR / FPR resolution + spill staging
//! helpers shared across every op-handler module.
//!
//! Per ADR-0023 §3 + ADR-0021 sub-deliverable b (emit.zig
//! 9-module split): extracted from emit.zig so
//! op_const / op_alu / op_memory / etc. can reach for these
//! helpers without circular imports back to emit.zig. The
//! helpers themselves are unchanged from their pre-split shape.
//!
//! - `writeU32` — append a little-endian u32 word to the buffer.
//! - `resolveGpr` — vreg → physical Xn (declines spilled vregs).
//! - `gprLoadSpilled` — spill-aware operand load via stage reg.
//! - `gprDefSpilled` — spill-aware result def via stage reg.
//! - `gprStoreSpilled` — pair of `gprDefSpilled`; flushes stage
//!   reg to spill slot.
//! - `resolveFp` — V-class counterpart of `resolveGpr`.
//! - `fpLoadSpilled` / `fpDefSpilled` / `fpStoreSpilled` — V-class
//!   spill-staging trio (D-037 — mirrors the GPR three; uses
//!   `abi.fp_spill_stage_vregs` (V29/V30) and the D-form (8-byte)
//!   spill encoders for class-uniform 8-byte spill stride).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");

const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const abi = @import("abi.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");

const Allocator = std.mem.Allocator;
const Error = ctx_mod.Error;

/// Append `word` as a little-endian 4-byte sequence to `buf`.
pub fn writeU32(allocator: Allocator, buf: *std.ArrayList(u8), word: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Largest frame byte-offset the imm12 LDR/STR forms encode (8-byte X scale ×
/// 4095). Past this a frame access must go through `frameAddrLarge` (D-289).
pub const max_frame_imm_off: u32 = 32760;

/// D-289: materialise `SP + off` into `scratch` (a GPR) so a frame load/store
/// whose byte offset exceeds the LDR/STR imm12 range can address `[scratch, #0]`.
/// Uses the prologue's two-ADD idiom (`ADD scratch, SP, #(off&0xFFF); ADD
/// scratch, scratch, #(off>>12), LSL #12`) — `ADD (immediate)` reads Rn==31 as
/// SP. `off` must be < 16 MiB (vreg/local counts bound it; beyond is genuinely
/// unencodable). The caller picks a `scratch` that is dead at the call site
/// (the load destination itself, the other spill-stage reg, or X16/IP0).
pub fn frameAddrLarge(allocator: Allocator, buf: *std.ArrayList(u8), scratch: inst.Xn, off: u32) Error!void {
    if (off >= (1 << 24)) return Error.SlotOverflow;
    try writeU32(allocator, buf, inst.encAddImm12(scratch, 31, @intCast(off & 0xFFF)));
    try writeU32(allocator, buf, inst.encAddImm12Lsl12(scratch, scratch, @intCast((off >> 12) & 0xFFF)));
}

/// D-289: emit `LDR{,W} dst, [SP, #off]` (frame load), large-off-safe. The load
/// destination doubles as the address scratch on the large path (materialise
/// SP+off into `dst`, then LDR `dst, [dst]`), so no extra register is needed.
/// `is_w` selects the 32-bit W-form (i32, imm12×4 cap 16380) vs 64-bit X-form
/// (i64/ref, imm12×8 cap 32760).
pub fn frameLdrGpr(allocator: Allocator, buf: *std.ArrayList(u8), dst: inst.Xn, off: u32, is_w: bool) Error!void {
    const cap: u32 = if (is_w) 16380 else max_frame_imm_off;
    if (off <= cap) {
        const w = if (is_w) inst.encLdrImmW(dst, 31, @intCast(off)) else inst.encLdrImm(dst, 31, @intCast(off));
        try writeU32(allocator, buf, w);
    } else {
        try frameAddrLarge(allocator, buf, dst, off);
        const w = if (is_w) inst.encLdrImmW(dst, dst, 0) else inst.encLdrImm(dst, dst, 0);
        try writeU32(allocator, buf, w);
    }
}

/// D-289: emit `STR{,W} src, [SP, #off]` (frame store), large-off-safe. The
/// store value occupies `src`, so the large path materialises SP+off into
/// `scratch` (caller passes a reg dead at this point — X16/IP0 at body sites,
/// the other spill-stage reg at spill sites). `is_w` as in `frameLdrGpr`.
pub fn frameStrGpr(allocator: Allocator, buf: *std.ArrayList(u8), src: inst.Xn, off: u32, is_w: bool, scratch: inst.Xn) Error!void {
    const cap: u32 = if (is_w) 16380 else max_frame_imm_off;
    if (off <= cap) {
        const w = if (is_w) inst.encStrImmW(src, 31, @intCast(off)) else inst.encStrImm(src, 31, @intCast(off));
        try writeU32(allocator, buf, w);
    } else {
        try frameAddrLarge(allocator, buf, scratch, off);
        const w = if (is_w) inst.encStrImmW(src, scratch, 0) else inst.encStrImm(src, scratch, 0);
        try writeU32(allocator, buf, w);
    }
}

/// D-289: FP/v128 frame-access width — S (f32, imm12×4 cap 16380), D (f64,
/// imm12×8 cap 32760), Q (v128, imm12×16 cap 65520).
pub const FpFrameW = enum { s, d, q };

fn fpFrameCap(w: FpFrameW) u32 {
    return switch (w) {
        .s => 16380,
        .d => 32760,
        .q => 65520,
    };
}

/// D-289: emit a frame load into V-register `vd` (LDR S/D/Q), large-off-safe.
/// Unlike `frameLdrGpr`, the V-reg destination cannot hold the computed address,
/// so the large path materialises SP+off into the GPR `scratch` (caller passes a
/// reg dead here — X16/IP0 at body sites), then `LDR vd, [scratch, #0]`.
pub fn frameLdrFp(allocator: Allocator, buf: *std.ArrayList(u8), vd: inst.Vn, off: u32, w: FpFrameW, scratch: inst.Xn) Error!void {
    if (off <= fpFrameCap(w)) {
        try writeU32(allocator, buf, switch (w) {
            .s => inst.encLdrSImm(vd, 31, @intCast(off)),
            .d => inst.encLdrDImm(vd, 31, @intCast(off)),
            .q => inst_neon.encLdrQImm(vd, 31, @intCast(off)),
        });
    } else {
        try frameAddrLarge(allocator, buf, scratch, off);
        try writeU32(allocator, buf, switch (w) {
            .s => inst.encLdrSImm(vd, scratch, 0),
            .d => inst.encLdrDImm(vd, scratch, 0),
            .q => inst_neon.encLdrQImm(vd, scratch, 0),
        });
    }
}

/// D-289: emit a frame store from V-register `vs` (STR S/D/Q), large-off-safe.
/// The store value occupies `vs`, so the large path materialises SP+off into the
/// GPR `scratch` (dead here — X16/IP0 at body sites), then `STR vs, [scratch, #0]`.
pub fn frameStrFp(allocator: Allocator, buf: *std.ArrayList(u8), vs: inst.Vn, off: u32, w: FpFrameW, scratch: inst.Xn) Error!void {
    if (off <= fpFrameCap(w)) {
        try writeU32(allocator, buf, switch (w) {
            .s => inst.encStrSImm(vs, 31, @intCast(off)),
            .d => inst.encStrDImm(vs, 31, @intCast(off)),
            .q => inst_neon.encStrQImm(vs, 31, @intCast(off)),
        });
    } else {
        try frameAddrLarge(allocator, buf, scratch, off);
        try writeU32(allocator, buf, switch (w) {
            .s => inst.encStrSImm(vs, scratch, 0),
            .d => inst.encStrDImm(vs, scratch, 0),
            .q => inst_neon.encStrQImm(vs, scratch, 0),
        });
    }
}

/// Resolve a vreg's home register (GPR class). Returns the
/// allocated reg or `Error.UnsupportedOp` for spilled vregs
/// (handlers that use non-spill-aware emission).
pub fn resolveGpr(alloc: regalloc.Allocation, vreg: usize) Error!inst.Xn {
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse blk: {
            // Diag: slot id beyond pool. Surfaces
            // when `max_reg_slots_gpr` exceeds `slotToReg.len`
            // (config drift) or when class disagreement assigns a
            // GPR-bound id that's too high for the GPR pool.
            dbg.print("codegen", "arm64/gpr: SlotOverflow resolveGpr vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => blk: {
            // Diag: surface which vreg / spill
            // slot triggered the reject so a follow-up can
            // narrow scope (spill-aware handler vs pool extension).
            dbg.print(
                "codegen",
                "arm64/gpr: resolveGpr rejected spilled vreg={d} (handler not spill-aware)\n",
                .{vreg},
            );
            break :blk Error.UnsupportedOp;
        },
    };
}

/// Resolve a vreg's home for **op operand load**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// emits `LDR X_stage, [SP, #(spill_base_off + spill_off)]`
/// staging through `abi.spill_stage_gprs[stage_idx]` and
/// returns the stage reg.
///
/// `stage_idx` selects which stage reg (0=X14, 1=X15). Use 0
/// for the first/only operand, 1 for the second operand of a
/// binary op (so two spilled operands don't collide).
pub fn gprLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Xn {
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow gprLoadSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            if ((abs_off & 7) != 0) {
                dbg.print("codegen", "arm64/gpr: SlotOverflow gprLoadSpilled.spill misaligned vreg={d} abs_off={d}\n", .{ vreg, abs_off });
                return Error.SlotOverflow;
            }
            // X-form LDR imm12 scales by 8; max byte offset is 8*4095 = 32760.
            // D-289: a large frame spills past that — materialise SP+abs_off into
            // the stage reg (also the load destination), then LDR from it.
            if (abs_off <= max_frame_imm_off) {
                try writeU32(allocator, buf, inst.encLdrImm(stage, 31, @intCast(abs_off)));
            } else {
                try frameAddrLarge(allocator, buf, stage, abs_off);
                try writeU32(allocator, buf, inst.encLdrImm(stage, stage, 0));
            }
            break :blk stage;
        },
    };
}

/// Resolve a vreg's home for **op result def**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// returns the stage reg (caller encodes the op writing into
/// it; then calls `gprStoreSpilled` to flush to the spill
/// slot).
pub fn gprDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Xn {
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow gprDefSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => abi.spill_stage_gprs[stage_idx],
    };
}

/// Pair of `gprDefSpilled`. After encoding the op (which wrote
/// the result into the stage reg), emits `STR X_stage, [SP,
/// #(spill_base_off + spill_off)]`. No-op for vregs in
/// registers (the result is already in its home).
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
            const abs_off = spill_base_off + off;
            if ((abs_off & 7) != 0) {
                dbg.print("codegen", "arm64/gpr: SlotOverflow gprStoreSpilled.spill misaligned vreg={d} abs_off={d}\n", .{ vreg, abs_off });
                return Error.SlotOverflow;
            }
            // D-289: store value occupies `stage`; materialise SP+abs_off into the
            // OTHER spill-stage reg (free at the op boundary by design), then STR.
            if (abs_off <= max_frame_imm_off) {
                try writeU32(allocator, buf, inst.encStrImm(stage, 31, @intCast(abs_off)));
            } else {
                const addr = abi.spill_stage_gprs[1 - stage_idx];
                try frameAddrLarge(allocator, buf, addr, abs_off);
                try writeU32(allocator, buf, inst.encStrImm(stage, addr, 0));
            }
        },
    }
}

/// FP-class counterpart of `resolveGpr`. Consults the class-aware
/// `Allocation.slot(vreg, .fpr)` API (D-036): the FP boundary
/// `max_reg_slots_fp` (default 13 post-D-037, matching
/// `abi.allocatable_v_regs.len`) decides reg-vs-spill, distinct
/// from the GPR boundary. Slot ids 0..12 resolve to V16..V28 via
/// `fpSlotToReg`; ids ≥ 13 surface as `.spill` and reject here
/// (handlers that use non-FP-spill-aware
/// emission via `fpLoadSpilled` / `fpDefSpilled` /
/// `fpStoreSpilled`).
pub fn resolveFp(alloc: regalloc.Allocation, vreg: usize) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow resolveFp vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            dbg.print(
                "codegen",
                "arm64/gpr: resolveFp rejected spilled vreg={d} spill_off={d} (handler not FP-spill-aware)\n",
                .{ vreg, off },
            );
            break :blk Error.UnsupportedOp;
        },
    };
}

/// V-class counterpart of `gprLoadSpilled`. If the FP vreg is in
/// a V-register, returns that reg directly. If spilled, emits
/// `LDR D_stage, [SP, #(spill_base_off + spill_off)]` staging
/// through `abi.fp_spill_stage_vregs[stage_idx]` (V29/V30) and
/// returns the stage reg.
///
/// `stage_idx` selects which stage reg (0=V29, 1=V30). Use 0 for
/// the first/only operand, 1 for the second operand of a binary
/// FP op. The D-form (8-byte) is used uniformly so the spill
/// frame stride matches GPR (8-byte) — a spilled f32 vreg writes
/// 64 bits with the upper 32 bits unspecified, but the load reads
/// the same 64 bits and FP ops on S-form ignore the upper 32, so
/// observable behaviour matches the spec.
pub fn fpLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow fpLoadSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            // D-form imm12 scales by 8; max byte offset is 8*4095 = 32760.
            if (abs_off > 32760 or (abs_off & 7) != 0) {
                dbg.print("codegen", "arm64/gpr: SlotOverflow fpLoadSpilled.spill vreg={d} abs_off={d} (base={d}+off={d})\n", .{ vreg, abs_off, spill_base_off, off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst.encLdrDImm(stage, 31, @intCast(abs_off)));
            break :blk stage;
        },
    };
}

/// V-class counterpart of `gprDefSpilled`. If the FP vreg is in a
/// V-register, returns that reg directly. If spilled, returns the
/// stage reg (caller encodes the op writing into it; then calls
/// `fpStoreSpilled` to flush to the spill slot).
pub fn fpDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow fpDefSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => abi.fp_spill_stage_vregs[stage_idx],
    };
}

/// Pair of `fpDefSpilled`. After encoding the op (which wrote the
/// result into the stage V-reg), emits `STR D_stage, [SP,
/// #(spill_base_off + spill_off)]`. No-op for vregs in V-registers
/// (the result is already in its home).
pub fn fpStoreSpilled(
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
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 32760 or (abs_off & 7) != 0) {
                dbg.print("codegen", "arm64/gpr: SlotOverflow fpStoreSpilled.spill vreg={d} abs_off={d} (base={d}+off={d})\n", .{ vreg, abs_off, spill_base_off, off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst.encStrDImm(stage, 31, @intCast(abs_off)));
        },
    }
}

/// V-class counterpart of `fpLoadSpilled` for v128 (Q-form, 16-byte
/// stride per ADR-0041 §"Decision" / 2). Used by SIMD op-handlers
/// (`op_simd.zig`) when the popped vreg is a spilled v128. If the
/// vreg is in a V-register, returns that reg directly; if spilled,
/// emits `LDR Q<stage>, [SP, #(spill_base_off + spill_off)]` staging
/// through `abi.fp_spill_stage_vregs[stage_idx]` (V29/V30) — the
/// 128-bit Q-form view of the same V regs the D-form fp helpers
/// use.
///
/// The 16-byte alignment requirement is enforced: `byte_offset` must
/// be a multiple of 16 and ≤ 65520 (= 4095 × 16, max imm12-encoded
/// offset for the Q-form). The spill_base_off + spill_off
/// combination must therefore be 16-byte aligned at the call site —
/// the caller (op_simd) is responsible for laying out v128 spill
/// slots at 16-byte strides per ADR-0041 §"Negative" /
/// "Conservative spill-frame size".
pub fn qLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return qLoadSpilledInto(allocator, buf, alloc, spill_base_off, vreg, abi.fp_spill_stage_vregs[stage_idx]);
}

/// `qLoadSpilled` with the register a spilled vreg loads into named by
/// the caller, for an op with more v128 operands than there are stages.
pub fn qLoadSpilledInto(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage: inst.Vn,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow qLoadSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            const abs_off = spill_base_off + off;
            // Q-form imm12 scales by 16; max byte offset is 16*4095 = 65520.
            if (abs_off > 65520 or (abs_off & 0xF) != 0) {
                dbg.print("codegen", "arm64/gpr: SlotOverflow qLoadSpilled.spill vreg={d} abs_off={d} (must be 16-byte aligned & ≤ 65520)\n", .{ vreg, abs_off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst_neon.encLdrQImm(stage, 31, @intCast(abs_off)));
            break :blk stage;
        },
    };
}

/// V-class counterpart of `fpDefSpilled` for v128 (Q-form). If the
/// vreg is in a V-register, returns that reg directly; if spilled,
/// returns the stage reg (caller encodes the op writing into it,
/// then calls `qStoreSpilled` to flush).
pub fn qDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            dbg.print("codegen", "arm64/gpr: SlotOverflow qDefSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => abi.fp_spill_stage_vregs[stage_idx],
    };
}

/// Pair of `qDefSpilled`. After encoding the op (which wrote into
/// the stage V-reg), emits `STR Q<stage>, [SP, #(spill_base_off +
/// spill_off)]`. No-op for vregs already in V-registers.
pub fn qStoreSpilled(
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
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 65520 or (abs_off & 0xF) != 0) {
                dbg.print("codegen", "arm64/gpr: SlotOverflow qStoreSpilled vreg={d} abs_off={d}\n", .{ vreg, abs_off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst_neon.encStrQImm(stage, 31, @intCast(abs_off)));
        },
    }
}

// ============================================================
// Tests — D-037 FP-spill helpers (chunk-d037-a)
// ============================================================

const testing = std.testing;

test "fpLoadSpilled: vreg in V-reg returns it directly without emitting bytes" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try fpLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 16), v); // V16 = first allocatable
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "fpLoadSpilled: spilled vreg emits LDR D and returns stage reg V29 (stage_idx=0)" {
    const slots = [_]u16{13}; // just past the new max_reg_slots_fp boundary
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Post-ADR-0110 widen: stride is *16.
    // spill_off = (13-8)*16 = 80; abs_off = spill_base_off (16) + 80 = 96
    const v = try fpLoadSpilled(testing.allocator, &buf, alloc, 16, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 29), v);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encLdrDImm(29, 31, 96), word);
}

test "fpLoadSpilled: stage_idx=1 yields V30" {
    const slots = [_]u16{13};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try fpLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 1);
    try testing.expectEqual(@as(inst.Vn, 30), v);
}

test "fpStoreSpilled: spilled vreg emits STR D from stage reg" {
    const slots = [_]u16{14};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Post-ADR-0110 widen: stride is *16.
    // spill_off = (14-8)*16 = 96; abs_off = 0 + 96 = 96
    try fpStoreSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encStrDImm(29, 31, 96), word);
}

test "fpStoreSpilled: in-V-reg vreg emits no bytes (no-op)" {
    const slots = [_]u16{5};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 6 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try fpStoreSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "fpDefSpilled: in-V-reg vreg returns the V-reg; spilled returns stage" {
    const slots = [_]u16{ 3, 13 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    try testing.expectEqual(@as(inst.Vn, 19), try fpDefSpilled(alloc, 0, 0)); // V16+3
    try testing.expectEqual(@as(inst.Vn, 29), try fpDefSpilled(alloc, 1, 0));
    try testing.expectEqual(@as(inst.Vn, 30), try fpDefSpilled(alloc, 1, 1));
}

// ============================================================
// Q-form (v128, 16-byte) spill helpers tests
// ============================================================

test "qLoadSpilled: vreg in V-reg returns it directly without emitting bytes" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try qLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 16), v); // V16 (FP slot 0)
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "qLoadSpilled: spilled vreg emits LDR Q stage from SP-relative offset" {
    // Post-ADR-0110 widen: Allocation.slot's spill formula is
    // (slot_id - max_reg_slots_gpr) * 16. Every spill offset is
    // intrinsically 16-byte aligned (vs pre-widen *8 which required
    // even-pair-index layout for v128 alignment).
    // Slot 14: spill_off = (14 - 8) * 16 = 96. spill_base_off=0
    // → abs_off = 96 ✓.
    const slots = [_]u16{14};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try qLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 29), v); // stage V29
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    // LDR Q29, [SP=31, #96] = encLdrQImm(29, 31, 96)
    try testing.expectEqual(inst_neon.encLdrQImm(29, 31, 96), word);
}

test "qLoadSpilled: rejects unaligned spill_base_off (post-widen alignment check still gates non-16-aligned base)" {
    // Post-ADR-0110 widen: every slot_id-derived spill_off is
    // 16-byte aligned by construction. The alignment check stays
    // load-bearing for non-16-aligned `spill_base_off` (e.g.
    // prologue laid the v128 region atop an 8-aligned scalar tail).
    // Slot 13: spill_off = (13 - 8) * 16 = 80. spill_base_off=8 →
    // abs_off = 88 (NOT 16-byte aligned).
    const slots = [_]u16{13};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectError(Error.SlotOverflow, qLoadSpilled(testing.allocator, &buf, alloc, 8, 0, 0));
}

test "qDefSpilled: in-V-reg vreg returns the V-reg; spilled returns stage" {
    const slots = [_]u16{ 5, 13 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    try testing.expectEqual(@as(inst.Vn, 21), try qDefSpilled(alloc, 0, 0)); // V16+5
    try testing.expectEqual(@as(inst.Vn, 29), try qDefSpilled(alloc, 1, 0));
    try testing.expectEqual(@as(inst.Vn, 30), try qDefSpilled(alloc, 1, 1));
}

test "qStoreSpilled: in-V-reg vreg is no-op (no bytes emitted)" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try qStoreSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "qStoreSpilled: spilled vreg emits STR Q stage to SP-relative offset" {
    // Post-ADR-0110 widen: Slot 14 → spill_off = (14-8)*16 = 96
    // (16-byte aligned). spill_base_off=16 → abs_off = 112 ✓.
    const slots = [_]u16{14};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try qStoreSpilled(testing.allocator, &buf, alloc, 16, 0, 0);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst_neon.encStrQImm(29, 31, 112), word);
}
