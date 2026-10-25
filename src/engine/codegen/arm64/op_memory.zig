// FILE-SIZE-EXEMPT: per-instruction-class catalog of the ADR-0021 9-module emit split, same class as its marked siblings (investigated 2026-08-12, per ADR-0099)
//! ARM64 emit pass — memory load / store handlers.
//!
//! Per ADR-0021 sub-deliverable b (emit.zig
//! 9-module split): all i32 / i64 / f32 / f64 load / store
//! ZirOp arms (25 op codes total) flow through a single
//! `emitMemOp` handler — they share the effective-address
//! computation + bounds-check prologue and
//! differ only in the final LDR/STR encoding.
//!
//! Caller-supplied invariants for memory ops in this skeleton:
//!   X28 = vm_base   (memory_base pointer)
//!   X27 = mem_limit (size in bytes)
//! ADR-0017 prologue arranges these from `*X0 = JitRuntime`.
//!
//! Per-op shape (spec-strict bounds: ea + size > mem_limit traps):
//!
//!   ORR W16, WZR, W_addr   ; zero-extend addr into IP0 (eff_addr scratch)
//!   ADD X16, X16, #offset  ; (skipped if offset == 0)
//!   ADD X17, X16, #size    ; eff_addr + access_size into IP1 (size scratch)
//!   CMP X17, X27           ; vs mem_limit
//!   B.HI trap_stub         ; placeholder + bounds_fixups append
//!   LDR/STR <op-specific>, [X28, X16]
//!
//! IP1 (X17) is used as scratch only within this emitMemOp.
//! call_indirect in op_call.zig also uses X17, but the two never
//! overlap within a single op handler (emitMemOp finishes → after
//! push_vreg, call_indirect starts as a separate op), so they do
//! not conflict. abi.zig's spill_stage_gprs documents that
//! call_indirect occupies X16/X17 mid-op, but at op-handler
//! boundaries either handler is free to use them as scratch.
//!
//! The B.HS fixup is appended to `ctx.bounds_fixups`; emit.zig's
//! function-final `end` patches all of them to the trap stub
//! address.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");
const build_options = @import("build_options");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const trace = @import("../../../diagnostic/trace.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

// ADR-0077 — op-internal scratch slot bindings used by emitMemoryInit
// (the D-133 bulk handler in this file). Regalloc guarantees these
// slots are free for vregs whose live range crosses the op's PC; the
// handler body references `sx10..sx12` instead of magic numerals so
// `check_invariant_comments.sh` no longer counts them as latent
// D-133-class overlap sites. emitMemoryInit only uses the
// {X10, X11, X12} subset of {X9..X13}; the op_scratch_reservation_table
// entry still names the full {0..4} set for forward-compatibility
// with future bulk-memory ops needing more scratch.
const sx10: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[1];
const sx11: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[2];
const sx12: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[3];

/// Unified handler for all 25 i32/i64/f32/f64 load/store arms.
/// Caller dispatches based on `ins.op`; this fn handles the
/// shared bounds-check prologue and per-op LDR/STR emission.
///
/// Wasm spec §4.4.7 (memory.load/store) — i32-idx memories
/// only at this layer; i64-idx memory64 wrap-check + 64-bit
/// offset materialise lands in the i64 path (ADR-0111 D4).
/// `MemArgExtra.memidx == 0` invariant: multi-memory routing
/// requires the instantiate-side reject lift;
/// until then codegen sees only memory 0. The runtime assert
/// codifies the prose-only invariant per `.claude/rules/comment_as_invariant.md`.
pub fn emitMemOp(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const memarg = zir.MemArgExtra.unpack(ins.extra);
    std.debug.assert(memarg.memidx == 0);
    // ADR-0111 D4 — 2-stage gate (comptime + runtime). When the
    // build is v2.0 the i64 arm is comptime-pruned (DCE-confirmed
    // by the v0.2 `-Dwasm=v2_0` symbol-absence gate). When v3.0,
    // the runtime check selects the i32 fast-path (byte-identical
    // to the legacy i32 emit, per emit_test_memory.zig assertions) or
    // the i64 wrap-check path.
    if (comptime @backingInt(build_options.wasm_level) >= @backingInt(@TypeOf(build_options.wasm_level).v3_0)) {
        if (ctx.memory0_idx_type == .i64) {
            return emitMemOpI64(ctx, ins);
        }
    }
    const is_store = switch (ins.op) {
        .@"i32.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        .@"f32.store",
        .@"f64.store",
        .@"i32.atomic.store",
        .@"i64.atomic.store",
        .@"i32.atomic.store8",
        .@"i32.atomic.store16",
        .@"i64.atomic.store8",
        .@"i64.atomic.store16",
        .@"i64.atomic.store32",
        => true,
        else => false,
    };
    const is_fp_value = switch (ins.op) {
        .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
        else => false,
    };
    // D-303 — atomic load/store trap on an unaligned effective address (spec
    // exec step 8, BEFORE bounds). The inline path previously omitted this
    // check that the interp has (memory.zig:202); RMW/cmpxchg/wait/notify
    // already check it in the jit_abi helper.
    const is_atomic = switch (ins.op) {
        .@"i32.atomic.load",
        .@"i64.atomic.load",
        .@"i32.atomic.load8_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load8_u",
        .@"i64.atomic.load16_u",
        .@"i64.atomic.load32_u",
        .@"i32.atomic.store",
        .@"i64.atomic.store",
        .@"i32.atomic.store8",
        .@"i32.atomic.store16",
        .@"i64.atomic.store8",
        .@"i64.atomic.store16",
        .@"i64.atomic.store32",
        => true,
        else => false,
    };
    const ip0: inst.Xn = 16;
    const ip1: inst.Xn = 17;
    const offset_imm = ins.payload;
    // Full 32-bit offset support. Wasm offsets are
    // u32 (max 0xFFFFFFFF). We dispatch by magnitude:
    //   - offset == 0:                no immediate add.
    //   - 0 < offset ≤ 0xFFFFFF:      ADD imm12 (lsl 12)? + ADD imm12
    //                                  (the 24-bit fast path).
    //   - offset > 0xFFFFFF:           MOVZ X17 lane0 + MOVK X17 lane1
    //                                  + ADD X16, X16, X17.
    // The MOVZ/MOVK pair stages the offset into ip1=X17 since ip1 is
    // not yet live (the bounds-check `ADD X17, X16, #access_size`
    // emits AFTER the offset add, reusing X17 cleanly).
    // Per-op access size in bytes (Wasm spec memory.{load,store} family).
    // Exhaustive switch (for the `require_exhaustive_enum_switch` lint gate),
    // so `else => unreachable` trips as a type-system violation if anything
    // other than a memory op reaches here.
    const access_size: u12 = switch (ins.op) {
        .@"i32.load8_s",
        .@"i32.load8_u",
        .@"i32.store8",
        .@"i64.load8_s",
        .@"i64.load8_u",
        .@"i32.atomic.load8_u",
        .@"i64.atomic.load8_u",
        .@"i64.store8",
        .@"i32.atomic.store8",
        .@"i64.atomic.store8",
        => 1,
        .@"i32.load16_s",
        .@"i32.load16_u",
        .@"i32.store16",
        .@"i64.load16_s",
        .@"i64.load16_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load16_u",
        .@"i64.store16",
        .@"i32.atomic.store16",
        .@"i64.atomic.store16",
        => 2,
        .@"i32.load",
        .@"i32.atomic.load",
        .@"i32.store",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"i64.atomic.load32_u",
        .@"i64.store32",
        .@"f32.load",
        .@"i32.atomic.store",
        .@"i64.atomic.store32",
        .@"f32.store",
        => 4,
        .@"i64.load",
        .@"i64.atomic.load",
        .@"i64.store",
        .@"f64.load",
        .@"i64.atomic.store",
        .@"f64.store",
        => 8,
        else => unreachable,
    };

    // Pop the address + (for stores) value vreg(s).
    var addr_vreg: u32 = 0;
    var val_vreg: u32 = 0;
    if (is_store) {
        if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        val_vreg = ctx.pushed_vregs.pop().?;
        addr_vreg = ctx.pushed_vregs.pop().?;
    } else {
        if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        addr_vreg = ctx.pushed_vregs.pop().?;
    }
    // D-034: addr_vreg via spill-staging (stage 0). After the
    // OR-into-ip0 below the address is captured in ip0, so stage 0
    // is free to reuse for store value or load result.
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_vreg, 0);

    // Effective-address + spec-strict bounds prologue.
    // ea = idx (zero-extended u32) + offset; trap iff ea + size > mem_limit.
    // No overflow possible in u64 arithmetic: max(ea + size) = 2^33 + 7 << 2^64.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, w_addr));
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            }
            if (off_low != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
            }
        } else {
            // offset > 0xFFFFFF: stage into X17 via MOVZ + MOVK then
            // ADD X16, X16, X17. Wasm offset is u32 so lanes 2/3 are
            // always zero; emit only lanes 0 and 1.
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            }
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    // D-303 — atomic alignment trap BEFORE bounds (spec exec step 8 < 14a).
    // ea is in ip0; TST its low log2(size) bits, B.NE → unaligned_atomic stub.
    if (is_atomic and access_size > 1) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encTstImmLowBitsW(ip0, @intCast(@ctz(access_size))));
        const al_fixup: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0)); // nonzero low bits = unaligned
        try ctx.unaligned_atomic_fixups.append(ctx.allocator, al_fixup);
    }
    // ADR-0202 D4 — elided: the guard-page reservation covers every
    // reachable ea (idx ≤ 2³²−1 + offset ≤ 2³²−1 + access ≤ 16 < the
    // 8 GiB reservation), so an oob access hardware-faults and the
    // fault→trap handler redirects to this function's force-emitted
    // kind=6 stub. The atomic ALIGNMENT check above is NOT elided.
    if (!ctx.bounds_elided) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip1, ip0, access_size));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip1, 27));
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0)); // unsigned >
        try ctx.oob_fixups.append(ctx.allocator, fixup_at);
        // ADR-0028 M3-a-1: record bounds-check emit site (no-op when
        // -Dtrace-ringbuffer=false; comptime-folded out of release).
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Final LDR/STR. Allocate result vreg first for loads.
    if (is_store) {
        // D-034 spill-aware: FP value uses fpLoadSpilled (V29/V30
        // independent of the GPR stage regs holding the address);
        // GPR value uses stage 1 (stage 0 is the address holder
        // already captured into ip0).
        const wv: inst.Xn = if (is_fp_value)
            try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1)
        else
            try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1);
        const word: u32 = switch (ins.op) {
            .@"i32.store", .@"i32.atomic.store" => inst.encStrWReg(wv, 28, ip0),
            .@"i32.store8", .@"i32.atomic.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i32.store16", .@"i32.atomic.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store", .@"i64.atomic.store" => inst.encStrXReg(wv, 28, ip0),
            .@"i64.store8", .@"i64.atomic.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i64.store16", .@"i64.atomic.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store32", .@"i64.atomic.store32" => inst.encStrWReg(wv, 28, ip0),
            .@"f32.store" => inst.encStrSReg(wv, 28, ip0),
            .@"f64.store" => inst.encStrDReg(wv, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
    } else {
        const result = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result >= ctx.alloc.slots.len) {
            dbg.print("codegen", "arm64/op_memory: load SlotOverflow func[{d}] op={s} vreg={d} >= slots.len={d}\n", .{ ctx.func.func_idx, @tagName(ins.op), result, ctx.alloc.slots.len });
            return Error.SlotOverflow;
        }
        // D-034 spill-aware: FP result def uses fpDefSpilled (V29
        // stage if spilled); GPR result def stages through X16.
        const wd: inst.Xn = if (is_fp_value)
            try gpr.fpDefSpilled(ctx.alloc, result, 0)
        else
            try gpr.gprDefSpilled(ctx.alloc, result, 0);
        const word: u32 = switch (ins.op) {
            .@"i32.load", .@"i32.atomic.load" => inst.encLdrWReg(wd, 28, ip0),
            .@"i32.load8_s" => inst.encLdrsbWReg(wd, 28, ip0),
            .@"i32.load8_u", .@"i32.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i32.load16_s" => inst.encLdrshWReg(wd, 28, ip0),
            .@"i32.load16_u", .@"i32.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load", .@"i64.atomic.load" => inst.encLdrXReg(wd, 28, ip0),
            .@"i64.load8_s" => inst.encLdrsbXReg(wd, 28, ip0),
            .@"i64.load8_u", .@"i64.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i64.load16_s" => inst.encLdrshXReg(wd, 28, ip0),
            .@"i64.load16_u", .@"i64.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load32_s" => inst.encLdrswXReg(wd, 28, ip0),
            .@"i64.load32_u", .@"i64.atomic.load32_u" => inst.encLdrWReg(wd, 28, ip0),
            .@"f32.load" => inst.encLdrSReg(wd, 28, ip0),
            .@"f64.load" => inst.encLdrDReg(wd, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
        if (is_fp_value) {
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        } else {
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        }
        try ctx.pushed_vregs.append(ctx.allocator, result);
    }
}

/// Wasm 3.0 §5.4.7 memory64 (memory.load/store with i64 idx_type).
/// Differs from `emitMemOp`'s i32 fast path in:
///   1. Address load uses X-form `encOrrReg` (full 64-bit) instead
///      of W-form `encOrrRegW` (zero-extended u32).
///   2. Offset materialise extends to 4 lanes (MOVZ + 3 MOVK)
///      when the offset spans bits 32..63 — needed because Wasm 3.0
///      memarg offset is u64.
/// All other shapes (per-op access_size, store value pop, bounds
/// check via X27 mem_limit, final LDR/STR via [X28, X16]) are
/// identical to the i32 path — the existing encoders are already
/// X-form. mem_limit (X27) is u64; the validator caps i64 memory
/// pages at 2^32 per ADR-0111 / engine/compile.zig so `ea + access_size`
/// cannot overflow u64. Per ADR-0111 D4.
///
/// This function is NOT exposed via `pub` — only `emitMemOp`'s
/// gate calls into it.
///
/// ADR-0193 P4: kept inline (not extracted to an `op_memory_i64.zig`
/// file-cluster) — it is ~130 LOC sharing this file's private arm64 emit
/// helpers, so extraction fails `file_size_smell` (N2 forced pub-leak, no P1
/// at sub-300 LOC, host file 1219/2000 LOC = no size pressure).
fn emitMemOpI64(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const is_store = switch (ins.op) {
        .@"i32.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        .@"f32.store",
        .@"f64.store",
        .@"i32.atomic.store",
        .@"i64.atomic.store",
        .@"i32.atomic.store8",
        .@"i32.atomic.store16",
        .@"i64.atomic.store8",
        .@"i64.atomic.store16",
        .@"i64.atomic.store32",
        => true,
        else => false,
    };
    const is_fp_value = switch (ins.op) {
        .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
        else => false,
    };
    // D-303 — atomic load/store trap on an unaligned effective address (spec
    // exec step 8, BEFORE bounds). The inline path previously omitted this
    // check that the interp has (memory.zig:202); RMW/cmpxchg/wait/notify
    // already check it in the jit_abi helper.
    const is_atomic = switch (ins.op) {
        .@"i32.atomic.load",
        .@"i64.atomic.load",
        .@"i32.atomic.load8_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load8_u",
        .@"i64.atomic.load16_u",
        .@"i64.atomic.load32_u",
        .@"i32.atomic.store",
        .@"i64.atomic.store",
        .@"i32.atomic.store8",
        .@"i32.atomic.store16",
        .@"i64.atomic.store8",
        .@"i64.atomic.store16",
        .@"i64.atomic.store32",
        => true,
        else => false,
    };
    const ip0: inst.Xn = 16;
    const ip1: inst.Xn = 17;
    const offset_imm = ins.payload;
    const access_size: u12 = switch (ins.op) {
        .@"i32.load8_s",
        .@"i32.load8_u",
        .@"i32.store8",
        .@"i64.load8_s",
        .@"i64.load8_u",
        .@"i32.atomic.load8_u",
        .@"i64.atomic.load8_u",
        .@"i64.store8",
        .@"i32.atomic.store8",
        .@"i64.atomic.store8",
        => 1,
        .@"i32.load16_s",
        .@"i32.load16_u",
        .@"i32.store16",
        .@"i64.load16_s",
        .@"i64.load16_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load16_u",
        .@"i64.store16",
        .@"i32.atomic.store16",
        .@"i64.atomic.store16",
        => 2,
        .@"i32.load",
        .@"i32.atomic.load",
        .@"i32.store",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"i64.atomic.load32_u",
        .@"i64.store32",
        .@"f32.load",
        .@"i32.atomic.store",
        .@"i64.atomic.store32",
        .@"f32.store",
        => 4,
        .@"i64.load",
        .@"i64.atomic.load",
        .@"i64.store",
        .@"f64.load",
        .@"i64.atomic.store",
        .@"f64.store",
        => 8,
        else => unreachable,
    };

    var addr_vreg: u32 = 0;
    var val_vreg: u32 = 0;
    if (is_store) {
        if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        val_vreg = ctx.pushed_vregs.pop().?;
        addr_vreg = ctx.pushed_vregs.pop().?;
    } else {
        if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        addr_vreg = ctx.pushed_vregs.pop().?;
    }
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_vreg, 0);

    // i64 ea = idx (X-form, full 64-bit) + offset. `encOrrReg`
    // copies all 64 bits (vs `encOrrRegW` which would truncate to
    // u32).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(ip0, 31, w_addr));
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            }
            if (off_low != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
            }
        } else {
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            const lane2: u16 = @truncate((offset_imm >> 32) & 0xFFFF);
            const lane3: u16 = @truncate((offset_imm >> 48) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            if (lane2 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane2, 2));
            if (lane3 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane3, 3));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    // D-303 — atomic alignment trap BEFORE bounds (memory64 path). ea in ip0.
    if (is_atomic and access_size > 1) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encTstImmLowBitsW(ip0, @intCast(@ctz(access_size))));
        const al_fixup: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0)); // nonzero low bits = unaligned
        try ctx.unaligned_atomic_fixups.append(ctx.allocator, al_fixup);
    }
    // memory64 bounds: trap when `ea + size > mem_limit`. ADDS (not ADD) so
    // an `ea + size` that overflows 64-bit (ea near 2^64, e.g. the spec
    // memory_trap64 -1/-2 cases) sets C and traps via B.HS — a plain ADD +
    // CMP would let the wrapped (small) sum pass as in-bounds.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddsImm12(ip1, ip0, access_size));
    const wrap_fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0)); // carry = ea+size wrapped past 2^64
    try ctx.oob_fixups.append(ctx.allocator, wrap_fixup);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip1, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup_at);
    trace.writeBounds(ctx.func.func_idx, fixup_at);

    if (is_store) {
        const wv: inst.Xn = if (is_fp_value)
            try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1)
        else
            try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1);
        const word: u32 = switch (ins.op) {
            .@"i32.store", .@"i32.atomic.store" => inst.encStrWReg(wv, 28, ip0),
            .@"i32.store8", .@"i32.atomic.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i32.store16", .@"i32.atomic.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store", .@"i64.atomic.store" => inst.encStrXReg(wv, 28, ip0),
            .@"i64.store8", .@"i64.atomic.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i64.store16", .@"i64.atomic.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store32", .@"i64.atomic.store32" => inst.encStrWReg(wv, 28, ip0),
            .@"f32.store" => inst.encStrSReg(wv, 28, ip0),
            .@"f64.store" => inst.encStrDReg(wv, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
    } else {
        const result = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result >= ctx.alloc.slots.len) {
            dbg.print("codegen", "arm64/op_memory: i64 load SlotOverflow func[{d}] op={s} vreg={d} >= slots.len={d}\n", .{ ctx.func.func_idx, @tagName(ins.op), result, ctx.alloc.slots.len });
            return Error.SlotOverflow;
        }
        const wd: inst.Xn = if (is_fp_value)
            try gpr.fpDefSpilled(ctx.alloc, result, 0)
        else
            try gpr.gprDefSpilled(ctx.alloc, result, 0);
        const word: u32 = switch (ins.op) {
            .@"i32.load", .@"i32.atomic.load" => inst.encLdrWReg(wd, 28, ip0),
            .@"i32.load8_s" => inst.encLdrsbWReg(wd, 28, ip0),
            .@"i32.load8_u", .@"i32.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i32.load16_s" => inst.encLdrshWReg(wd, 28, ip0),
            .@"i32.load16_u", .@"i32.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load", .@"i64.atomic.load" => inst.encLdrXReg(wd, 28, ip0),
            .@"i64.load8_s" => inst.encLdrsbXReg(wd, 28, ip0),
            .@"i64.load8_u", .@"i64.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i64.load16_s" => inst.encLdrshXReg(wd, 28, ip0),
            .@"i64.load16_u", .@"i64.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load32_s" => inst.encLdrswXReg(wd, 28, ip0),
            .@"i64.load32_u", .@"i64.atomic.load32_u" => inst.encLdrWReg(wd, 28, ip0),
            .@"f32.load" => inst.encLdrSReg(wd, 28, ip0),
            .@"f64.load" => inst.encLdrDReg(wd, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
        if (is_fp_value) {
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        } else {
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        }
        try ctx.pushed_vregs.append(ctx.allocator, result);
    }
}

// ============================================================
// Bulk-memory ops (Wasm 2.0 §4.4.7 — memory.fill / memory.copy)
//
// Stack effect: pops three i32 (n: top, val|src: middle, dst: bottom).
// No result pushed. Trap on out-of-bounds (dst+n > mem_size, or for
// copy also src+n > mem_size).
//
// Inline byte loop; correctness first, not performance-tuned.
//
// Register convention:
//   X28 = vm_base, X27 = mem_limit (size in bytes), unchanged.
//   X14, X15 = spill_stage_gprs — clobberable. `gprLoadSpilled` may
//     pipe values through these but each call only stages one value;
//     the handler captures into private holders before the next load.
//   X16, X17 = IP scratches (regalloc never lands a vreg here). We
//     use them as private working registers AFTER the bounds-check
//     fixup is appended (the fixup is a B.HI placeholder; once
//     written, X16/X17 are free for the loop body).
// ============================================================

/// Wasm spec §4.4.7 (memory.fill) — pop n / val / dst (top→bottom);
/// set `n` bytes at `[dst, dst+n)` to `val & 0xFF`. Trap if
/// `dst+n > mem_size`.
///
/// ARM64 lowering (Arm IHI 0055):
///   ; capture operands into private holders (W12/W13 — caller-saved
///   ; scratch but not in the regalloc pool's spill-stage carve-out;
///   ; freely usable here because op-handlers don't observe pool
///   ; lifetimes mid-handler — handlers run as one IR instruction's
///   ; emission window, with no concurrent vreg reads of W12/W13
///   ; in flight). NOTE: W12/W13 ARE in the regalloc pool
///   ; (slots 3, 4), so whether a vreg currently holds them is
///   ; visible via alloc.slot. This is safe because
///   ; bulk-mem never co-occurs with pre-existing conflict patterns
///   ; such as call_indirect, but a dedicated reservation should be
///   ; introduced long-term.
///
/// Implementation note: the operation needs three operands, whereas
/// `spill_stage_gprs` has only two slots (X14/X15). To hold the third
/// and later operands safely, each is MOVed into a private holder
/// (X16/X17) immediately after being loaded, before proceeding to the
/// next load. Because the bounds-check may clobber X16/X17, the steps
/// that evacuate the needed values out of the private holders before
/// the bounds-check are carefully ordered.
pub fn emitMemoryFill(ctx: *EmitCtx) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const val_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;
    // D-324 — i64-indexed (memory64) memory: dst + n are full u64
    // operands; capture X-form and use the no-overflow bounds scheme
    // (W-form capture truncated addresses ≥ 2^32 to their low bits).
    const is64 = bulkIs64(ctx);
    const cbz: *const fn (inst.Xn, i32) u32 = if (is64) inst.encCbz else inst.encCbzW;
    const cbnz: *const fn (inst.Xn, i32) u32 = if (is64) inst.encCbnz else inst.encCbnzW;

    // Step A: Load each operand into a stable private holder.
    //
    // Plan:
    //   1. Load dst (stage 0). Move into X17 (IP1).
    //   2. Load val (stage 0; previous staged value already moved
    //      out, so reuse is safe).  Move into X16 (IP0).
    //   3. Load n   (stage 0). Move into X14 (stage 0 reg, but at
    //      this point we've finished all spill loads; X14 is now a
    //      private counter holder).
    //
    // After this:  X17 = dst (zero-extended u32),
    //              X16 = val (low byte used),
    //              X14 = n   (counter, zero-extended u32).
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, (@as(*const fn (inst.Xn, inst.Xn, inst.Xn) u32, if (is64) inst.encOrrReg else inst.encOrrRegW))(17, 31, w_dst_src));
    const w_val_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_val_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, (@as(*const fn (inst.Xn, inst.Xn, inst.Xn) u32, if (is64) inst.encOrrReg else inst.encOrrRegW))(14, 31, w_n_src));

    // Step B: Bounds check — trap if dst + n > mem_size.
    // i32 path: ADD X15, X17, X14 (both zero-extended u32 → sum
    // < 2^33, no overflow); CMP X15, X27; B.HI trap.
    // i64 path (D-324): dst + n can wrap u64 — use the no-overflow
    // scheme instead: n > limit → trap; dst > limit - n → trap.
    try emitBulkBounds(ctx, is64, 17, 14);

    // Step C: Convert dst index to absolute pointer.
    // X17 = X28 + X17 (vm_base + dst_idx).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 28, 17));

    // Step D: If n == 0, skip the loop.
    // CBZ {W,X}14, .end  (forward branch — patched after loop end;
    // X-form on memory64 — n can legitimately exceed 2^32).
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, cbz(14, 0));

    // Step E: Loop body.
    //   .loop:
    //     STRB W16, [X17]      ; *X17 = val (low byte)
    //     ADD  X17, X17, #1    ; X17++
    //     SUB  X14, X14, #1    ; X14--  (CBNZ checks {W,X}14)
    //     CBNZ {W,X}14, .loop
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(16, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const back_disp_words: i32 = @divExact(
        @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, cbnz(14, back_disp_words));

    // Step F: Patch the CBZ skip target to land here (post-loop).
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp_words: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], cbz(14, skip_disp_words), .little);
}

/// D-324 — is this module's (single, memidx-0) memory i64-indexed?
/// Comptime-pruned below v3.0, mirroring `emitMemOp`'s gate.
inline fn bulkIs64(ctx: *EmitCtx) bool {
    if (comptime @backingInt(build_options.wasm_level) >= @backingInt(@TypeOf(build_options.wasm_level).v3_0)) {
        return ctx.memory0_idx_type == .i64;
    }
    return false;
}

/// D-324 — bulk-op bounds check: trap when `base + n > mem_limit`
/// (X27). `base_x` / `n_x` name the holder registers. The i32 path
/// keeps the historical byte-identical ADD/CMP/B.HI (both operands
/// are zero-extended u32 → the sum cannot wrap). The i64 path's
/// operands are full u64 where `base + n` CAN wrap — use the
/// subtraction scheme: `n > limit` → trap; `base > limit - n` → trap.
/// Clobbers X15.
fn emitBulkBounds(ctx: *EmitCtx, is64: bool, base_x: inst.Xn, n_x: inst.Xn) Error!void {
    if (is64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(n_x, 27));
        const fixup_n_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.oob_fixups.append(ctx.allocator, fixup_n_at);
        trace.writeBounds(ctx.func.func_idx, fixup_n_at);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubReg(15, 27, n_x));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(base_x, 15));
        const fixup_base_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.oob_fixups.append(ctx.allocator, fixup_base_at);
        trace.writeBounds(ctx.func.func_idx, fixup_base_at);
        return;
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, base_x, n_x));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup_at);
    trace.writeBounds(ctx.func.func_idx, fixup_at);
}

/// Wasm spec §4.4.7 (memory.copy) — pop n / src / dst (top→bottom);
/// copy `n` bytes from `[src, src+n)` to `[dst, dst+n)`. Trap if
/// `dst+n > mem_size` OR `src+n > mem_size`. Spec semantics require
/// memmove-style overlap handling: if `dst > src`, copy backward;
/// otherwise forward.
///
/// ARM64 lowering — same operand-capture discipline as memory.fill,
/// plus a forward/backward branch on `dst < src`.
///
/// Holder regs after Step A:
///   X17 = dst (zero-ext u32),
///   X16 = src (zero-ext u32),
///   X14 = n  (zero-ext u32).
///
/// Bounds check needs X15 scratch: ADD X15, X17, X14; CMP X15, X27;
/// B.HI trap.  Then ADD X15, X16, X14; CMP X15, X27; B.HI trap.
///
/// Pointer setup: convert X17 / X16 to absolute pointers via
/// `ADD X17, X28, X17` and `ADD X16, X28, X16`.
///
/// Direction: CMP X17, X16; B.LS forward (dst <= src copies forward).
/// Backward: pre-add n to both pointers and step backward via post-
/// decrement-style emission (SUB ptr, #1 ; LDRB/STRB ; SUB n, #1 ;
/// CBNZ loop).  `B.LS` (unsigned ≤) handles the equal case as
/// forward, which is a no-op equivalent.
pub fn emitMemoryCopy(ctx: *EmitCtx) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;
    // D-324 — memory64: dst / src / n are full u64 (JIT compiles only
    // memidx 0, so the memories are uniform and it_min = i64 too).
    const is64 = bulkIs64(ctx);
    const cbz: *const fn (inst.Xn, i32) u32 = if (is64) inst.encCbz else inst.encCbzW;
    const cbnz: *const fn (inst.Xn, i32) u32 = if (is64) inst.encCbnz else inst.encCbnzW;
    const cmp_imm: *const fn (inst.Xn, u12) u32 = if (is64) inst.encCmpImmX else inst.encCmpImmW;
    const capture: *const fn (inst.Xn, inst.Xn, inst.Xn) u32 = if (is64) inst.encOrrReg else inst.encOrrRegW;

    // Step A: capture into private holders X17 / X16 / X14.
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, capture(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, capture(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, capture(14, 31, w_n_src));

    // Step B1: Bounds check dst + n. (D-324: overflow-safe on i64.)
    try emitBulkBounds(ctx, is64, 17, 14);

    // Step B2: Bounds check src + n.
    try emitBulkBounds(ctx, is64, 16, 14);

    // Step C: Convert indices to absolute pointers.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 28, 17)); // dst_p = vm_base + dst
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 28, 16)); // src_p = vm_base + src

    // Step D: If n == 0, skip both loops.
    const skip_zero_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, cbz(14, 0));

    // Step E: Direction switch.
    //   CMP X17, X16          ; dst <=> src
    //   B.LS forward          ; dst <= src → forward copy
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 16));
    const fwd_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ls, 0));

    // ---- Backward path (dst > src; potentially overlapping). Copy high→low,
    // 8 bytes/iteration while n >= 8 (LDR/STR X), then a ≤7-byte tail. D-285:
    // the prior byte-at-a-time loop made bulk copies slower than the
    // interpreter's vectorized copyForwards. ----
    // Pre-add n so X17 / X16 point one past the block end.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 16, 14));
    // .bwd_word: while (n >= 8) { dst-=8; src-=8; *dst = *src; n-=8; }
    const bwd_word_top: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, cmp_imm(14, 8));
    const bwd_word_exit_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.lo, 0)); // B.lo .bwd_tail (fixup)
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(
        @as(i32, @intCast(bwd_word_top)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));
    // .bwd_tail: patch the B.lo to here; copy ≤7 remaining bytes high→low.
    const bwd_tail_top: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[bwd_word_exit_at..][0..4], inst.encBCond(.lo, @divExact(
        @as(i32, @intCast(bwd_tail_top)) - @as(i32, @intCast(bwd_word_exit_at)),
        4,
    )), .little);
    const bwd_tail_skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, cbz(14, 0)); // CBZ W14, .bwd_done (fixup)
    const bwd_tail_loop: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, cbnz(14, @divExact(
        @as(i32, @intCast(bwd_tail_loop)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));
    // .bwd_done: unconditional branch to .end (patched after fwd path).
    const bwd_end_jmp_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    // Patch the no-tail CBZ to skip straight to .bwd_done (the B→.end).
    std.mem.writeInt(u32, ctx.buf.items[bwd_tail_skip_at..][0..4], cbz(14, @divExact(
        @as(i32, @intCast(bwd_end_jmp_at)) - @as(i32, @intCast(bwd_tail_skip_at)),
        4,
    )), .little);

    // ---- Forward path (dst <= src; safe forward copy). Patch the B.LS. ----
    const fwd_byte: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[fwd_at..][0..4], inst.encBCond(.ls, @divExact(
        @as(i32, @intCast(fwd_byte)) - @as(i32, @intCast(fwd_at)),
        4,
    )), .little);
    // .fwd_word: while (n >= 8) { *dst = *src; dst+=8; src+=8; n-=8; }
    const fwd_word_top: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, cmp_imm(14, 8));
    const fwd_word_exit_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.lo, 0)); // B.lo .fwd_tail (fixup)
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(
        @as(i32, @intCast(fwd_word_top)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));
    // .fwd_tail: patch B.lo to here; copy ≤7 remaining bytes low→high.
    const fwd_tail_top: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[fwd_word_exit_at..][0..4], inst.encBCond(.lo, @divExact(
        @as(i32, @intCast(fwd_tail_top)) - @as(i32, @intCast(fwd_word_exit_at)),
        4,
    )), .little);
    const fwd_tail_skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, cbz(14, 0)); // CBZ W14, .end (fixup)
    const fwd_tail_loop: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, cbnz(14, @divExact(
        @as(i32, @intCast(fwd_tail_loop)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));

    // .end: patch the n==0 skip, the bwd path's exit jump, and the fwd no-tail skip.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[skip_zero_at..][0..4], cbz(14, @divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_zero_at)),
        4,
    )), .little);
    std.mem.writeInt(u32, ctx.buf.items[bwd_end_jmp_at..][0..4], inst.encB(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(bwd_end_jmp_at)),
        4,
    )), .little);
    std.mem.writeInt(u32, ctx.buf.items[fwd_tail_skip_at..][0..4], cbz(14, @divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(fwd_tail_skip_at)),
        4,
    )), .little);
}

/// Wasm spec §4.5.3.10 (memory.init dataidx) — copy `n` bytes from
/// data segment `dataidx` at offset `src` into linear memory at
/// offset `dst`. Traps OutOfBoundsMemoryAccess on `src+n > seg.len`
/// or `dst+n > mem_limit`. When the segment was dropped, the spec
/// treats its length as 0 (any `n > 0` traps).
///
/// Register layout (caller-saved scratch only — no calls):
///   X17 = dst (then dst_p = vm_base + dst)
///   X16 = src (then src_p = seg.ptr + src)
///   X14 = n   (counter)
///   X11 = seg.ptr (preserved across bounds check)
///   X15 = seg.len (overridden to 0 if dropped)
///   X9, X10, X12 = ad-hoc temps
pub fn emitMemoryInit(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const dataidx: u32 = @intCast(ins.payload);
    // imm12 budget: LDR X-form scaled byte_off ≤ 32760 → idx ≤ 2047
    // (stride 16). LDRB imm12 ≤ 4095 → idx ≤ 4095. The 2047 bound
    // is the tighter one. Validator already bounds idx vs the
    // module's segment count; this guard only rejects encoding-
    // budget overflow.
    if (dataidx >= 2048) return Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: capture operands into X17 / X16 / X14 (W-form copies
    // zero-extend to 64-bit; safe since Wasm i32 ops never set bit
    // 32+). D-324: dst is the TARGET memory's address — full u64
    // X-form on memory64; src + n stay i32 (data-segment offsets).
    const is64 = bulkIs64(ctx);
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, (@as(*const fn (inst.Xn, inst.Xn, inst.Xn) u32, if (is64) inst.encOrrReg else inst.encOrrRegW))(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B: read seg.ptr (X11) + seg.len (X15) from data_segments_ptr.
    //   LDR  X10, [X19, #data_segments_ptr_off]    ; seg table base
    //   LDR  X11, [X10, #(idx*16)]                  ; seg.ptr
    //   LDR  X15, [X10, #(idx*16)+8]                ; seg.len
    const seg_byte_off: u15 = @intCast(@as(u32, dataidx) * 16);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.data_segments_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx11, 10, seg_byte_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 10, seg_byte_off + 8));

    // Step C: dropped flag override. If dropped == 1, seg.len → 0.
    //   LDR  X10, [X19, #data_dropped_ptr_off]
    //   LDRB W12, [X10, #idx]
    //   CMP  W12, #0
    //   CSEL X15, X15, XZR, EQ      ; keep len when not dropped (W12==0)
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.data_dropped_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(sx12, 10, @intCast(dataidx)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(sx12, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCselX(15, 15, 31, .eq));

    // Step D1: bounds — src + n > seg.len → trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(sx12, 16, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(sx12, 15));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.oob_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D2: bounds — dst + n > mem_limit (X27) → trap. D-324: on
    // memory64 dst is full u64 and `dst + n` can wrap — the helper's
    // i64 arm uses the subtraction scheme. X15 (seg.len) is dead
    // after D1, so the helper's X15 clobber is safe.
    try emitBulkBounds(ctx, is64, 17, 14);

    // Step E: if n == 0, skip the copy (CBZ on W14 — Wasm n is i32).
    const skip_zero_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    // Step F: compute absolute pointers.
    //   X17 = X28 + X17  ; dst_p = vm_base + dst
    //   X16 = X11 + X16  ; src_p = seg.ptr + src
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 28, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 11, 16));

    // Step G: forward byte loop. memory.init's spec allows the source
    // (data segment) and destination (linear memory) to be disjoint
    // by construction — data segments live in module-owned host
    // storage, never overlapping linear memory — so a forward-only
    // copy is sufficient (unlike memory.copy which must handle
    // overlap).
    // .loop:
    //   LDRB W12, [X16]
    //   STRB W12, [X17]
    //   ADD  X16, X16, #1
    //   ADD  X17, X17, #1
    //   SUB  X14, X14, #1
    //   CBNZ W14, .loop
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(sx12, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(sx12, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const back_disp_words: i32 = @divExact(
        @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back_disp_words));

    // .end: patch the n==0 skip.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    {
        const disp_words: i19 = @intCast(@divExact(
            @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_zero_at)),
            4,
        ));
        std.mem.writeInt(u32, ctx.buf.items[skip_zero_at..][0..4], inst.encCbzW(14, disp_words), .little);
    }
}

/// Wasm threads (ADR-0168) `tNN.atomic.rmw*` — callout through
/// `JitRuntime.atomic_rmw_fn`. AAPCS64 args: X0 = rt (= X19), X1 = ea
/// (addr + offset), X2 = operand (full 64-bit; helper truncates), W3 =
/// opcode. The helper performs the seq-cst load-modify-store and
/// returns the OLD value zero-extended in X0; on unaligned/oob it sets
/// trap_flag (epilogue raises the trap). Marshal is conflict-free: arg
/// regs X0..X7 are not in the allocatable pool, so the operand/addr
/// vregs never collide with X1/X2. BLR clobbers X9..X15 — vregs live
/// across this op force-spill via `regalloc_compute` (mirror
/// memory.grow). vm_base/mem_limit (X28/X27) are untouched by the
/// helper, so no reload.
pub fn emitAtomicRmw(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const m = jit_abi.rmwMapOf(ins.op) orelse return Error.UnsupportedOp;
    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const operand_v = ctx.pushed_vregs.pop().?;
    const addr_v = ctx.pushed_vregs.pop().?;
    const ip0 = abi.ip_gprs[0];
    const ip1 = abi.ip_gprs[1];
    // X2 = operand (full 64-bit move; helper truncates to width).
    const x_op = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, operand_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(2, 31, x_op));
    // ea into ip0 = addr (zero-ext u32) + offset (mirror emitMemOp).
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, w_addr));
    const offset_imm = ins.payload;
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            if (off_low != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
        } else {
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, ip0)); // X1 = ea
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(3, @intCast(m.code))); // W3 = opcode
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)); // X0 = rt
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.atomic_rmw_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));
    // Capture old value (X0 for i64, W0 zero-ext for i32) → result vreg.
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    switch (ctx.alloc.slot(result, .gpr)) {
        .reg => |id| {
            const wd = abi.slotToReg(id) orelse return Error.SlotOverflow;
            if (m.res64) {
                if (wd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(wd, 31, 0));
            } else {
                // i32: ORRW zero-extends bits 63:32 (canonical i32 form).
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, 0));
            }
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            try gpr.frameStrGpr(ctx.allocator, ctx.buf, 0, abs_off, !m.res64, abi.spill_stage_gprs[0]);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Wasm threads (ADR-0168) `tNN.atomic.rmw*.cmpxchg*` — callout through
/// `JitRuntime.atomic_cmpxchg_fns[width_log2]`. AAPCS64 args: X0 = rt,
/// X1 = ea, X2 = expected (full 64-bit; helper truncates), X3 =
/// replacement. Returns OLD in X0; on unaligned/oob the helper sets
/// trap_flag (epilogue raises). Marshal conflict-free (arg regs not
/// allocatable). Mirror of emitAtomicRmw, but 3 operands + a per-width
/// fn-ptr slot (no opcode arg).
pub fn emitAtomicCmpxchg(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const m = jit_abi.cmpxchgMapOf(ins.op) orelse return Error.UnsupportedOp;
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const repl_v = ctx.pushed_vregs.pop().?;
    const exp_v = ctx.pushed_vregs.pop().?;
    const addr_v = ctx.pushed_vregs.pop().?;
    const ip0 = abi.ip_gprs[0];
    const ip1 = abi.ip_gprs[1];
    // X3 = replacement (full 64-bit). Stage 0.
    const r_repl = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, repl_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(3, 31, r_repl));
    // X2 = expected (full 64-bit). Stage 1.
    const r_exp = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, exp_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(2, 31, r_exp));
    // ea into ip0 = addr (zero-ext u32) + offset. Stage 0 reused (repl
    // already in X3).
    const r_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, r_addr));
    const offset_imm = ins.payload;
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            if (off_low != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
        } else {
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, ip0)); // X1 = ea
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)); // X0 = rt
    // LDR X16, [X19, #(cmpxchg_fns_off + wlog2*8)]; BLR X16.
    const fn_off: u15 = @intCast(jit_abi.atomic_cmpxchg_fns_off + @as(u32, m.wlog2) * 8);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));
    // Capture old value (X0 for i64, W0 zero-ext for i32) → result vreg.
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    switch (ctx.alloc.slot(result, .gpr)) {
        .reg => |id| {
            const wd = abi.slotToReg(id) orelse return Error.SlotOverflow;
            if (m.res64) {
                if (wd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(wd, 31, 0));
            } else {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, 0));
            }
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            try gpr.frameStrGpr(ctx.allocator, ctx.buf, 0, abs_off, !m.res64, abi.spill_stage_gprs[0]);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Capture W0 (i32 callout result) into `result` vreg (zero-extended).
/// Shared by emitAtomicNotify / emitAtomicWait.
fn captureW0I32(ctx: *EmitCtx) Error!void {
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    switch (ctx.alloc.slot(result, .gpr)) {
        .reg => |id| {
            const wd = abi.slotToReg(id) orelse return Error.SlotOverflow;
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, 0));
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            try gpr.frameStrGpr(ctx.allocator, ctx.buf, 0, abs_off, true, abi.spill_stage_gprs[0]);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Compute `ea = addr (zero-ext u32) + ins.payload` into ip0 from the
/// addr vreg (loaded at `stage`). Shared ea-materialise for the
/// notify/wait callouts (mirror emitAtomicRmw's inline block).
fn eaIntoIp0(ctx: *EmitCtx, addr_v: u32, stage: u2, offset_imm: u64) Error!void {
    const ip0 = abi.ip_gprs[0];
    const ip1 = abi.ip_gprs[1];
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_v, stage);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, w_addr));
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            if (off_low != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
        } else {
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
}

/// Wasm threads (ADR-0168) `memory.atomic.notify` — callout through
/// `JitRuntime.atomic_notify_fn`. Pops count (unused single-thread) +
/// addr. AAPCS64: X0 = rt, X1 = ea. Returns 0 in W0; helper sets
/// trap_flag on unaligned/oob.
pub fn emitAtomicNotify(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    _ = ctx.pushed_vregs.pop().?; // count (unused)
    const addr_v = ctx.pushed_vregs.pop().?;
    const ip0 = abi.ip_gprs[0];
    try eaIntoIp0(ctx, addr_v, 0, ins.payload);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, ip0)); // X1 = ea
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)); // X0 = rt
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.atomic_notify_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));
    try captureW0I32(ctx);
}

/// Wasm threads (ADR-0168) `memory.atomic.wait{32,64}` — callout through
/// `JitRuntime.atomic_wait_fns[idx]`. Pops timeout (unused) + expected +
/// addr. AAPCS64: X0 = rt, X1 = ea, X2 = expected. Returns status in W0;
/// helper sets trap_flag on unaligned/oob/non-shared.
pub fn emitAtomicWait(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    _ = ctx.pushed_vregs.pop().?; // timeout (unused)
    const exp_v = ctx.pushed_vregs.pop().?;
    const addr_v = ctx.pushed_vregs.pop().?;
    const ip0 = abi.ip_gprs[0];
    // X2 = expected (full 64-bit; helper truncates to width). Stage 0.
    const r_exp = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, exp_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(2, 31, r_exp));
    try eaIntoIp0(ctx, addr_v, 1, ins.payload);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, ip0)); // X1 = ea
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)); // X0 = rt
    const fn_off: u15 = @intCast(jit_abi.atomic_wait_fns_off + jit_abi.waitIdxOf(ins.op) * 8);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));
    try captureW0I32(ctx);
}
