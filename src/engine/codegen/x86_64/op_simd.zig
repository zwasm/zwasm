// FILE-SIZE-EXEMPT: per-op handler catalog (Wasm SIMD-128 sub-language); P1 spec-defined (per ADR-0099)
//! x86_64 emit pass — SIMD-128 op handlers.
//!
//! Mirrors the role of `arm64/op_simd.zig` for the SSE2 / SSE4.1
//! lowering of v128 ops. The shape-tag pipeline itself
//! (`engine/codegen/shared/regalloc.populateShapeTags`) is shared
//! across arches per ADR-0041 §"Decision" / 2 and needs no
//! x86_64-side wiring.
//!
//! Packed integer add/sub family (8 ops):
//!
//! - `emitV128IntBinop(encoder)` — shared helper. Pop 2 v128;
//!   `MOVAPS dst, lhs` (elided when dst aliases lhs) then
//!   `<encoder>(dst, rhs)`; push result. v128 reg-reg copy uses
//!   `encMovapsXmmXmm` (0F 28 /r): MOVAPS and MOVDQA are
//!   interchangeable for register-to-register moves on every
//!   shipped Intel/AMD micro-architecture.
//! - 8 per-op wrappers (`emitI8x16Add` / `emitI8x16Sub` /
//!   `emitI16x8Add` / `emitI16x8Sub` / `emitI32x4Add` /
//!   `emitI32x4Sub` / `emitI64x2Add` / `emitI64x2Sub`) — each
//!   one-line dispatch into `emitV128IntBinop` with the
//!   appropriate `inst.encPadd*` / `inst.encPsub*` encoder.
//!
//! Out of scope:
//!
//! - v128 spill helpers (16-byte stride MOVDQU). The existing
//!   `gpr.xmmLoadSpilled` / `xmmDefSpilled` use 8-byte MOVSD
//!   which truncates the upper 64 bits of an XMM. Spilled v128
//!   vregs therefore return `Error.UnsupportedOp` via
//!   `gpr.resolveXmm` until the 16-byte spill helpers land.
//! - v128.const / v128.load / v128.store / splat / extract_lane
//!   / replace_lane / mul / compare / shuffle / FP arith / FP
//!   compare / convert. Each of these introduces new encoder
//!   families or non-trivial synthesis (e.g. PMULLD requires
//!   SSE4.1 minimum baseline; i64x2.mul has no native form),
//!   so they ship as separate chunks per the chunk-bundle rule.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const types = @import("types.zig");
const ctx_mod = @import("ctx.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const trace = @import("../../../diagnostic/trace.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Shared v128 packed-integer binop helper. Wasm spec §4.4.4
/// (packed integer add/sub) — pop two v128, push their
/// element-wise wraparound result. x86_64 lowering: `MOVAPS dst,
/// lhs` (elided when dst already aliases lhs) followed by
/// `<encoder>(dst, rhs)` (PADDB/W/D/Q or PSUBB/W/D/Q per the
/// caller's encoder choice). Mirror of ARM64's
/// `arm64/op_simd.emitV128Binop` shape; ARM64's three-address
/// `ADD Vd.<T>, Vn.<T>, Vm.<T>` collapses both the MOV and the
/// op into one instruction, which has no x86_64 equivalent until
/// AVX VPADD* (out of scope per ADR-0041 §"5. SSE4.1 minimum
/// baseline").
///
/// ADR-0053 Part 3 — spill-aware via the v128
/// helpers from gpr.zig. rhs loads to stage 0 (XMM14) when
/// spilled, lhs to stage 1 (XMM15), result also uses stage 1 so
/// the MOVAPS-from-lhs writes to the same physical XMM the
/// subsequent store flushes from. The 2-stage pool stays
/// conflict-free because the MOVAPS-from-lhs is the only write
/// to the lhs/result stage before the encoder reads rhs from
/// stage 0.
pub fn emitV128IntBinop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, rhs_v, 0);
    const lhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, lhs_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    // Aliasing safety (D-066 mirror for x86_64; D-070 partial
    // discharge): regalloc's LIFO slot-reuse can assign
    // `result_v` the same physical XMM as `rhs_v` (when rhs's
    // last use is here). The naive `MOVAPS dst, lhs; encoder(dst,
    // rhs)` would overwrite rhs before encoder reads it, yielding
    // `result = lhs` (silently wrong PAND/POR/PXOR/etc. results
    // — surfaces as ~4400 simd_assert FAILs on x86_64
    // simd_bitwise / simd_i*x*_arith). Stash rhs through XMM7
    // (the project-canonical SIMD scratch — `abi.zig` reserves it
    // mirroring arm64's V31) when the alias condition holds.
    //
    // ADR-0053 Part 3 note: spilled rhs / spilled result use
    // different stages (XMM14 vs XMM15) by construction, so the
    // alias check only fires for in-reg-pool collisions.
    var rhs_for_op = rhs_x;
    if (dst_x != lhs_x and dst_x == rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, rhs_x).slice());
        rhs_for_op = .xmm7;
    }
    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder(dst_x, rhs_for_op).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

// Per-Wasm-op wrappers. Each is a 1-line dispatch into the
// shared helper with the appropriate encoder. The function names
// document the spec op (Wasm spec §4.4.4 packed integer add/sub).

/// Wasm spec §4.4.7 (v128.load) — pop i32 idx, push v128 loaded
/// from `[mem_base + idx + offset]` (16-byte unaligned). Spec
/// trap iff `idx + offset + 16 > mem_limit`. Mirror of scalar
/// `op_memory.emitMemOp` shape with access_size = 16 + MOVUPS
/// final encoding. RAX/RCX/RDX scratches are pool-excluded
/// (allocatable_caller_saved_scratch_gprs = R10/R11 only).
pub fn emitV128Load(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    // ADR-0053 Part 3c: dst v128 takes stage 0 (XMM14); the
    // subsequent MOVUPS-from-memory writes into dst directly, then
    // xmmStoreSpilledV128 flushes to the spill slot when needed.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 16, func_idx);

    try buf.appendSlice(allocator, inst.encMovupsMemBaseIdx(false, dst_x, .rax, .rdx).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.store) — pop v128 val, pop i32 idx;
/// store val at `[mem_base + idx + offset]` (16 bytes unaligned).
/// Spec trap iff `idx + offset + 16 > mem_limit`. Mirror of
/// emitV128Load with reversed direction (MOVUPS [mem], xmm).
pub fn emitV128Store(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const val_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    // ADR-0053 Part 3c: val v128 loads via MOVUPS when spilled.
    const val_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, val_v, 0);

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 16, func_idx);

    try buf.appendSlice(allocator, inst.encMovupsMemBaseIdx(true, val_x, .rax, .rdx).slice());
}

/// Shared eff-addr + bounds-check prologue for v128 memory ops.
/// Mirrors op_memory.emitMemOp's prologue exactly with the access
/// size as a parameter. RAX = vm_base reload, RDX = ea base
/// (zero-ext idx + offset), RCX = ea+size scratch for the JA
/// bounds-check fixup.
pub fn v128MemPrologue(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    oob_fixups: *std.ArrayList(u32),
    idx_r: inst.Gpr,
    offset: u32,
    access_size: i8,
    func_idx: u32,
) Error!void {
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, idx_r).slice());
    if (offset != 0) {
        if (offset <= 0x7FFFFFFF) {
            try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, @intCast(offset)).slice());
        } else {
            try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, @as(u64, offset)).slice());
            try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .rcx).slice());
        }
    }
    try buf.appendSlice(allocator, inst.encLeaR64BaseDisp8(.rcx, .rdx, access_size).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rcx, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
    try oob_fixups.append(allocator, fixup_at);
    trace.writeBounds(func_idx, fixup_at);
}

/// Wasm spec §4.4.7 (v128.load8_splat) — pop i32 idx, load 1 byte
/// from `[mem + idx + offset]`, broadcast to all 16 lanes. Recipe:
/// MOVZX RCX, byte [RAX+RDX]; MOVD dst, ECX; PXOR XMM14, XMM14;
/// PSHUFB dst, XMM14 (zero-mask broadcast). Cranelift recipe at
/// `lower.isle:4840-4843` uses PINSRB-mem which we don't yet have
/// in encoder form; the GPR round-trip is one extra instr.
pub fn emitV128Load8Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    // D-461: spill-aware dst on STAGE1 (XMM15) — XMM14 (stage0) is the zero-ctrl scratch.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14: zero ctrl mask

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 1, func_idx);
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.rcx, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, .rcx).slice());
    try buf.appendSlice(allocator, inst.encPxor(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, scratch_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load16_splat) — load 2 bytes, broadcast
/// to all 8 lanes. PSHUFLW broadcasts the low 16 to lanes 0-3 (low
/// qword); PSHUFD then broadcasts the low 32 (= 2× the value) to
/// all 4 dwords (= 8 lanes total).
pub fn emitV128Load16Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1); // D-461: spill-aware dst stage1

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 2, func_idx);
    try buf.appendSlice(allocator, inst.encMovzxR32_16MemBaseIdx(.rcx, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, .rcx).slice());
    try buf.appendSlice(allocator, inst.encPshuflw(dst_x, dst_x, 0).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load32_splat) — load 4 bytes, broadcast
/// to all 4 lanes. MOVSS loads 4 bytes into lane 0 + zeros upper
/// 96; PSHUFD imm 0 broadcasts lane 0 to all 4.
pub fn emitV128Load32Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1); // D-461: spill-aware dst stage1

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 4, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f32, false, dst_x, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load64_splat) — load 8 bytes, broadcast
/// to both 64-bit lanes. MOVSD loads 8 bytes into low qword +
/// zeros upper qword; PSHUFD imm 0x44 (= 01_00_01_00) broadcasts
/// the low qword (dwords 0+1) to the upper qword (dwords 2+3).
pub fn emitV128Load64Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1); // D-461: spill-aware dst stage1

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 8, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f64, false, dst_x, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0x44).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load32_zero) — load 4 bytes into low
/// lane; upper 96 bits zeroed. MOVSS xmm, [mem] does this in one
/// instruction per Intel SDM Vol 2A "MOVSS" (memory-source form
/// zero-extends the upper 96 bits of dst).
pub fn emitV128Load32Zero(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1); // D-461: spill-aware dst stage1

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 4, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f32, false, dst_x, .rax, .rdx).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load64_zero) — load 8 bytes into low
/// 64; upper 64 bits zeroed. MOVSD xmm, [mem] does this in one
/// instruction per Intel SDM Vol 2A "MOVSD" (memory-source form
/// zero-extends the upper 64 bits of dst).
pub fn emitV128Load64Zero(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1); // D-461: spill-aware dst stage1

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 8, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f64, false, dst_x, .rax, .rdx).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

// =============================================================
// v128.load{8x8,16x4,32x2}_{s,u} (6 ops)
//
// Wasm spec §4.4.7. Load 8 bytes from mem into low qword of dst
// (upper 64 zeroed), then extend each lane to the next-larger
// size: 8→16, 16→32, 32→64. Cranelift recipe `lower.isle:
// 4977-5010` is identical: MOVQ + PMOVSX/ZX{BW,WD,DQ}. Reuses
// v128MemPrologue with access_size=8 and the existing
// PMOVSX/ZX encoders. No new encoders.
// =============================================================

pub fn v128LoadExtend(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
    extend_encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    // D-034 (g): spill-aware dst. The load source is memory and the address is in
    // GPRs, so dst can use spill stage0/XMM14 (no other XMM scratch); flush after.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, 8, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f64, false, dst_x, .rax, .rdx).slice());
    try buf.appendSlice(allocator, extend_encoder(dst_x, dst_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load8x8_s) — 8 i8 → 8 i16 sign-extend.
pub fn emitV128Load8x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, func_idx, inst.encPmovsxbw);
}

/// Wasm spec §4.4.7 (v128.load8x8_u) — 8 u8 → 8 i16 zero-extend.
pub fn emitV128Load8x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, func_idx, inst.encPmovzxbw);
}

/// Wasm spec §4.4.7 (v128.load16x4_s) — 4 i16 → 4 i32 sign-extend.
pub fn emitV128Load16x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, func_idx, inst.encPmovsxwd);
}

/// Wasm spec §4.4.7 (v128.load16x4_u) — 4 u16 → 4 i32 zero-extend.
pub fn emitV128Load16x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, func_idx, inst.encPmovzxwd);
}

/// Wasm spec §4.4.7 (v128.load32x2_s) — 2 i32 → 2 i64 sign-extend.
pub fn emitV128Load32x2S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, func_idx, inst.encPmovsxdq);
}

/// Wasm spec §4.4.7 (v128.load32x2_u) — 2 u32 → 2 i64 zero-extend.
pub fn emitV128Load32x2U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, func_idx, inst.encPmovzxdq);
}

// =============================================================
// load_lane / store_lane × {8, 16, 32, 64} (8 ops)
//
// Wasm spec §4.4.7. load_lane: load N bytes from mem into a GPR
// then PINSR{B/W/D/Q} reg-form to merge into the input v128 at
// the lane immediate. store_lane: PEXTR{B/W/D/Q} reg-form to
// extract lane to a GPR then store N bytes to mem. payload =
// offset (memarg); extra = lane byte. RAX/RCX/RDX scratches are
// pool-excluded (same convention as v128MemPrologue).
//
// Cranelift recipes (`lower.isle`) use mem-form PINSR/PEXTR for
// one fewer instruction; zwasm's GPR-roundtrip path matches the
// existing lane-access shape and avoids new mem-form
// encoders for this chunk. Performance refinement is future work.
// =============================================================

pub fn v128LoadLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    lane: u32,
    func_idx: u32,
    comptime access_size: i8,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const vec_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    // D-461: spill-aware vec-read (STAGE0/XMM14) + dst-write (STAGE1/XMM15).
    // No internal XMM scratch here (RCX GPR roundtrip), so the two stages
    // never collide. arm64 already spill-aware via emitV128LoadLane.
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, access_size, func_idx);

    // Load value into RCX (zero-extended), then merge dst with vec
    // and PINSR the new lane.
    const enc_load = switch (access_size) {
        1 => inst.encMovzxR32_8MemBaseIdx(.rcx, .rax, .rdx),
        2 => inst.encMovzxR32_16MemBaseIdx(.rcx, .rax, .rdx),
        4 => inst.encMovR32FromBaseIdx(.rcx, .rax, .rdx),
        8 => inst.encMovR64FromBaseIdx(.rcx, .rax, .rdx),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_load.slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    const enc_pinsr = switch (access_size) {
        1 => inst.encPinsrB(dst_x, .rcx, @intCast(lane & 0xF)),
        2 => inst.encPinsrW(dst_x, .rcx, @intCast(lane & 0x7)),
        4 => inst.encPinsrD(dst_x, .rcx, @intCast(lane & 0x3)),
        8 => inst.encPinsrQ(dst_x, .rcx, @intCast(lane & 0x1)),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_pinsr.slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn v128StoreLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    lane: u32,
    func_idx: u32,
    comptime access_size: i8,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const vec_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    // D-034 (g): spill-aware vec. vec is read once by PEXTR (into RCX), so a spilled
    // vec loads into stage0/XMM14; no v128 result to store.
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);

    // PEXTR the lane to RCX BEFORE the prologue clobbers RCX.
    const enc_pextr = switch (access_size) {
        1 => inst.encPextrB(.rcx, vec_x, @intCast(lane & 0xF)),
        2 => inst.encPextrW(.rcx, vec_x, @intCast(lane & 0x7)),
        4 => inst.encPextrD(.rcx, vec_x, @intCast(lane & 0x3)),
        8 => inst.encPextrQ(.rcx, vec_x, @intCast(lane & 0x1)),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_pextr.slice());

    // The prologue uses RCX as a scratch (LEA RCX, [RDX+size]) —
    // we need to preserve our extracted value across that. Push/pop
    // RCX around the prologue to keep it. RBX is callee-saved,
    // could be used as a holder, but the simplest path is the
    // PUSH/POP pair (2 bytes each).
    try buf.appendSlice(allocator, inst.encPushR(.rcx).slice());
    try v128MemPrologue(allocator, buf, oob_fixups, idx_r, offset, access_size, func_idx);
    try buf.appendSlice(allocator, inst.encPopR(.rcx).slice());

    const enc_store = switch (access_size) {
        1 => inst.encStoreR8MemBaseIdx(.rcx, .rax, .rdx),
        2 => inst.encStoreR16MemBaseIdx(.rcx, .rax, .rdx),
        4 => inst.encStoreR32MemBaseIdx(.rcx, .rax, .rdx),
        8 => inst.encStoreR64MemBaseIdx(.rcx, .rax, .rdx),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_store.slice());
}

/// Wasm spec §4.4.7 (v128.load8_lane) — load 1 byte; merge into lane.
pub fn emitV128Load8Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, lane, func_idx, 1);
}

/// Wasm spec §4.4.7 (v128.load16_lane) — load 2 bytes; merge into lane.
pub fn emitV128Load16Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, lane, func_idx, 2);
}

/// Wasm spec §4.4.7 (v128.load32_lane) — load 4 bytes; merge into lane.
pub fn emitV128Load32Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, lane, func_idx, 4);
}

/// Wasm spec §4.4.7 (v128.load64_lane) — load 8 bytes; merge into lane.
pub fn emitV128Load64Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, oob_fixups, spill_base_off, offset, lane, func_idx, 8);
}

/// Wasm spec §4.4.7 (v128.store8_lane) — extract lane; store 1 byte.
pub fn emitV128Store8Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, oob_fixups, spill_base_off, offset, lane, func_idx, 1);
}

/// Wasm spec §4.4.7 (v128.store16_lane) — extract lane; store 2 bytes.
pub fn emitV128Store16Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, oob_fixups, spill_base_off, offset, lane, func_idx, 2);
}

/// Wasm spec §4.4.7 (v128.store32_lane) — extract lane; store 4 bytes.
pub fn emitV128Store32Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, oob_fixups, spill_base_off, offset, lane, func_idx, 4);
}

/// Wasm spec §4.4.7 (v128.store64_lane) — extract lane; store 8 bytes.
pub fn emitV128Store64Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), oob_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, oob_fixups, spill_base_off, offset, lane, func_idx, 8);
}

/// Wasm spec §4.4.4 (v128.not) — pop one v128, push v128 with
/// every bit inverted. SSE has no native NOT instruction;
/// synthesise via `PCMPEQB scratch, scratch` (= all-ones) +
/// `PXOR dst, scratch` (= ~src). 3-instruction emit including the
/// MOVAPS preamble to copy src into dst.
/// `(ctx, ins)` adapters for the v128
/// logical cohort (v128.not/and/andnot/or/xor/bitselect). Each
/// wraps its existing 6-arg helper.
pub fn emitV128NotCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128Not(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitV128AndCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128And(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitV128OrCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128Or(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitV128XorCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128Xor(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitV128AndnotCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128Andnot(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitV128BitselectCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128Bitselect(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapter for v128.any_true.

pub fn emitV128AnyTrueCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitV128AnyTrue(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitV128Not(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3: src loads to stage 1 (XMM15) so the
    // "ones" scratch at stage 0 (XMM14) stays available for
    // PCMPEQ. dst defs at stage 1 (XMM15); the MOVAPS dst,src
    // copies before PCMPEQ overwrites XMM14.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const ones = abi.fp_spill_stage_xmms[0]; // XMM14

    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.and / v128.or / v128.xor) — pop two
/// v128, push v128 with the corresponding bitwise op applied per
/// 128-bit value. Reuses the `emitV128IntBinop` shape with the
/// SSE2 packed-int encoders (PAND / POR / PXOR — int-domain XOR
/// preferred over XORPS for bit-identical-but-domain-faster
/// semantics on older microarchitectures).
pub fn emitV128And(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPand);
}

pub fn emitV128Or(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPor);
}

pub fn emitV128Xor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPxor);
}

/// Wasm spec §4.4.4 (v128.andnot) — `andnot(a, b) = a & ~b`. SSE
/// `PANDN dst, src` computes `dst = ~dst & src`, so we MOVAPS
/// rhs (=b) into dst then PANDN dst, lhs (=a) → dst = ~b & a =
/// a & ~b. 2-instruction emit (or 1 if dst==rhs).
pub fn emitV128Andnot(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3: rhs stage 0 (XMM14), lhs stage 1 (XMM15),
    // result stage 0 (XMM14 — same as rhs's load location: the
    // MOVAPS dst,rhs preserves rhs's value while writing to dst).
    const rhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, rhs_v, 0);
    const lhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, lhs_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    if (dst_x != rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, rhs_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(dst_x, lhs_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.bitselect) — pop c, b, a (top-of-stack
/// is c); push `(a & c) | (b & ~c)`. 5-instruction PAND/PANDN/POR
/// recipe (cranelift uses PBLENDVB on AVX but the PAND chain is
/// SSE2-baseline-clean and one fewer encoder dependency):
///
///   dst = MOVAPS(a)        (skip if dst==a)
///   dst = PAND(dst, c)     ; dst = a & c
///   scratch = MOVAPS(c)
///   scratch = PANDN(scratch, b) ; scratch = ~c & b = b & ~c
///   dst = POR(dst, scratch) ; dst = (a & c) | (b & ~c)
///
/// Wasm spec stack order: bottom→top: a, b, c. Pops in order: c
/// first (top), then b, then a.
pub fn emitV128Bitselect(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const c_v = pushed_vregs.pop().?;
    const b_v = pushed_vregs.pop().?;
    const a_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3b: Bitselect has 3 v128
    // operand inputs + 1 v128 result = 4 operands but only 2
    // standard stage XMMs (XMM14 / XMM15) exist. Reclaim XMM7
    // (the D-066 alias-stash scratch — free in this handler since
    // we don't run an alias check) as a 3rd staging slot for `a`
    // and the spilled-result dst. Stage layout:
    //   c → stage 0 → XMM14 (also serves as the final scratch
    //                          since PANDN destroys it after c is dead).
    //   b → stage 1 → XMM15.
    //   a → XMM7 (custom; a is dead after MOVAPS dst, a).
    //   dst → result's home if in-reg; XMM7 if spilled (= same
    //          physical XMM as a; the MOVAPS-from-a is then a
    //          no-op).
    const c_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, c_v, 0);
    const b_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, b_v, 1);

    // Custom load for `a` → XMM7 (a 3rd staging slot, free for the
    // bitselect handler).
    var a_x: inst.Xmm = undefined;
    switch (alloc.slot(a_v, .fpr)) {
        .reg => |id| a_x = abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(.xmm7, disp).slice());
            a_x = .xmm7;
        },
    }

    // dst: in-reg → home; spilled → XMM7 (re-using a's physical
    // slot after a is consumed by the MOVAPS).
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    // D-070 mirror for x86_64: regalloc LIFO
    // slot-reuse can assign `result_v` (= dst_x) the same in-reg
    // physical XMM as `c_v` or `b_v`. The MOVAPS dst,a then
    // clobbers c or b before subsequent reads. Stash whichever
    // alias hits, before step 1. c_x is stashed into XMM14
    // (= the scratch_x slot below; the MOVAPS already in place
    // for "copy c to XMM14" folds out). b_x is stashed into
    // XMM15 (= b's stage 1 if it was spilled — but if b was in-
    // reg this stage is currently unused).
    const c_safe: inst.Xmm = if (dst_x != a_x and dst_x == c_x and c_x != .xmm14) blk: {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm14, c_x).slice());
        break :blk .xmm14;
    } else c_x;
    const b_safe: inst.Xmm = if (dst_x != a_x and dst_x == b_x and b_x != .xmm15) blk: {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm15, b_x).slice());
        break :blk .xmm15;
    } else b_x;

    // Step 1: dst = MOVAPS(a). Skipped when dst already equals a
    // (in-reg alias OR both-spilled-and-routed-through-XMM7).
    if (dst_x != a_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, a_x).slice());
    }
    // Step 2: dst = PAND(dst, c). c persists in c_safe past this.
    try buf.appendSlice(allocator, inst.encPand(dst_x, c_safe).slice());

    // Steps 3-4: scratch = c; scratch = PANDN(scratch, b). Reuse
    // XMM14 as scratch — when c_safe is already XMM14 (spilled
    // load OR alias-stashed above), the MOVAPS folds out.
    const scratch_x: inst.Xmm = .xmm14;
    if (c_safe != scratch_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, c_safe).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(scratch_x, b_safe).slice());
    // Step 5: dst = POR(dst, scratch).
    try buf.appendSlice(allocator, inst.encPor(dst_x, scratch_x).slice());

    // Store if result is spilled.
    if (result_slot == .spill) {
        const off = result_slot.spill;
        const disp = try gpr.v128SpillDisp(spill_base_off, off);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.any_true) — pop v128, push i32 (1 if any
/// bit of the v128 is non-zero else 0). Recipe (cranelift
/// `lower.isle` `vany_true`):
///
///   PTEST xmm, xmm        ; sets EFLAGS.ZF=1 iff all bits zero
///   SETNE dst.lo8         ; dst[0..8] = (ZF==0) ? 1 : 0
///   MOVZX dst, dst.lo8    ; zero-extend to i32
///
/// PTEST is SSE4.1 (66 0F 38 17 /r). Per ADR-0041 §5 (SSE4.2
/// baseline), SSE4.1 + SSE4.2 are both available.
/// `select` / `select_typed` with v128 operand type (Wasm spec
/// §4.4.5). Mirror of `arm64/op_simd.emitV128Select`. Caller has
/// already popped cond_v / val2_v / val1_v from the operand stack
/// and verified `val1_v.shapeTag == .v128` (dispatch lives at
/// `x86_64/emit.zig`'s scalar `.select` arm).
/// D-083 part 2 (mirror of arm64's part 1 fix).
///
/// **Mask-based recipe** (x86_64 has no direct `CSETM` / `DUP`
/// equivalent, so synthesise the same all-bits mask via
/// `SETcc`-then-broadcast):
///
///   TEST cond_r, cond_r       ; ZF = (cond == 0)
///   XOR R10d, R10d             ; R10 = 0
///   MOV R11d, 0xFFFFFFFF       ; R11 = -1 (32-bit, zero-extended)
///   CMOVNE R10, R11            ; R10 = (cond != 0) ? -1 : 0
///   MOVQ XMM7, R10              ; XMM7.lo64 = R10 (sign-extended via 32-bit lane)
///   PSHUFD XMM7, XMM7, 0x00    ; broadcast lane 0 → all 4 lanes = mask
///
///   ; Bit-select via XOR-trick (`dst = b ^ (mask & (a ^ b))`):
///   MOVAPS XMM14, val1_xmm      ; tmp = val1
///   PXOR   XMM14, val2_xmm      ; tmp = val1 ^ val2
///   PAND   XMM14, XMM7           ; tmp = mask & (val1 ^ val2)
///   MOVAPS dst_xmm, val2_xmm    ; dst = val2 (self-MOV when dst==val2)
///   PXOR   dst_xmm, XMM14        ; dst = val2 ^ tmp = cond ? val1 : val2
///
/// val1 loads through stage 1 (XMM15) and val2 via `resolveXmm`
/// (rejects spilled with `Error.UnsupportedOp`). XMM14 (= fp spill
/// stage 0) is the scratch tmp, so a spilled result stages through
/// XMM15 too: val1 is dead after the first MOVAPS. XMM7 is the
/// project-canonical SIMD scratch, out of the regalloc pool.
///
/// **Aliasing safety**: regalloc's LIFO slot-reuse can give
/// `result_v` the same physical XMM as `val1_v` or `val2_v`. The
/// XOR-trick handles both alias cases naturally — XMM14 holds the
/// tmp value across the final `MOVAPS dst, val2`, so `dst==val1`
/// (val1 read at the first MOVAPS while still intact) and
/// `dst==val2` (self-MOV) both work. val1==val2 is impossible
/// (distinct Wasm operands).
pub fn emitV128Select(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    cond_v: u32,
    val1_v: u32,
    val2_v: u32,
    result_vreg: u32,
) Error!void {
    // D-490: when `cond_v` is register-spilled, `gprLoadSpilled(cond_v, 0)` returns
    // `spill_stage_gprs[0]` — the SAME physical reg as `r_mask`. The old order
    // (`XOR r_mask,r_mask` then `TEST cond_r`) zeroed cond BEFORE testing it, so ZF was
    // always set, the CMOV never fired, the lane mask stayed 0, and v128 `select` silently
    // returned val2 for every lane (x86_64-only, heavy-spill-only — arm64 reads cond via
    // CMP-immediately + a transient mask reg, so it was correct). Fix mirrors the D-330
    // TEST-first discipline of emitInt/FpSelect: TEST cond FIRST, capture (cond!=0) into
    // `r_neg1` (≠ cond_r) via SETNE, THEN build the 0/-1 lane mask in r_mask — cond is fully
    // consumed before r_mask is clobbered. (No second stage-reg / -1 source needed.)
    const r_mask = abi.spill_stage_gprs[0];
    const r_neg1 = abi.spill_stage_gprs[1];
    const cond_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, cond_v, 0);
    try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.ne, r_neg1).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(r_neg1, r_neg1).slice());
    try buf.appendSlice(allocator, inst.encXorRR(.q, r_mask, r_mask).slice());
    try buf.appendSlice(allocator, inst.encSubRR(.q, r_mask, r_neg1).slice());

    const xmm_mask: inst.Xmm = .xmm7;
    try buf.appendSlice(allocator, inst.encMovqXmmFromR64(xmm_mask, r_mask).slice());
    try buf.appendSlice(allocator, inst.encPshufd(xmm_mask, xmm_mask, 0x00).slice());

    const val1_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, val1_v, 1);
    const val2_x = try gpr.resolveXmm(alloc, val2_v);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_vreg, 1);

    const xmm_tmp: inst.Xmm = abi.fp_spill_stage_xmms[0];
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(xmm_tmp, val1_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(xmm_tmp, val2_x).slice());
    try buf.appendSlice(allocator, inst.encPand(xmm_tmp, xmm_mask).slice());
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, val2_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, xmm_tmp).slice());

    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_vreg, 1);
}

pub fn emitV128AnyTrue(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3: src loaded via MOVUPS into stage 0 (XMM14)
    // when spilled. The result is a GPR (i32 boolean), so no
    // XMM/spill interaction on the dst side.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encPtest(src_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.ne, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i*x*.all_true) — pop v128, push i32 (1 if
/// every lane is non-zero else 0). 5-instruction recipe per
/// cranelift `lower.isle:4936-4941` SSE4.1 path:
///
///   scratch = PXOR(scratch, scratch)        ; scratch = zero
///   scratch = PCMPEQ_lane(scratch, src)     ; lanes==0 → 0xFF; non-zero → 0x00
///   PTEST(scratch, scratch)                  ; ZF=1 iff scratch==0 iff no lane was zero
///   dst.lo8 = SETZ                            ; (ZF==1) ? 1 : 0 = all_true result
///   dst = MOVZX(dst, dst.lo8)
///
/// `encoder_pcmpeq` selects the lane width: PCMPEQB / W / D / Q.
pub fn emitV128AllTrue(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_pcmpeq: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (e): spill-aware v128 source. scratch_x is XMM14 (stage 0), so a
    // spilled src must load into stage 1 (XMM15) to avoid the scratch collision
    // (the D-461 stage-XMM-vs-op-scratch LANDMINE). GPR result already spill-aware.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPxor(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, encoder_pcmpeq(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encPtest(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Append `value` to `extra_consts` if not already present (linear
/// scan dedup), returning the resulting global const_idx (i.e.
/// simd_consts_base + position-in-extra_consts).
pub fn lookupOrAppendExtraConst(
    allocator: Allocator,
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
    value: [16]u8,
) Error!u32 {
    for (extra_consts.items, 0..) |c, i| {
        if (std.mem.eql(u8, &c, &value)) {
            return simd_consts_base + @as(u32, @intCast(i));
        }
    }
    const idx: u32 = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
    try extra_consts.append(allocator, value);
    return idx;
}

/// Emit a MOVUPS-RIP-rel placeholder targeting the given const-pool
/// idx and record the SimdConstFixup. Returns the destination XMM
/// (handler must already have decided which scratch to load into).
pub fn emitConstLoad(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    dst: inst.Xmm,
    const_idx: u32,
) Error!void {
    const enc = inst.encMovupsXmmRipRelPlaceholder(dst);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });
}

/// Wasm spec §4.4.5 (v128.const) — push a 16-byte literal as a
/// v128 value. Per ADR-0042: the lower pass populates
/// `func.simd_consts` and stores the array index in
/// `ZirInstr.payload`. This handler emits a `MOVUPS xmm,
/// [RIP+0]` placeholder and records a SimdConstFixup; the
/// per-function emit close (emit.zig) appends the const-pool
/// 16-byte aligned past the trap stub and patches each fixup's
/// disp32.
pub fn emitV128Const(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    const_idx: u32,
    spill_base_off: u32,
) Error!void {
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3c: dst v128 takes stage 0 (XMM14); MOVUPS-
    // RIP-rel writes into it, then store to spill if needed.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);
    const enc = inst.encMovupsXmmRipRelPlaceholder(dst_x);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}
