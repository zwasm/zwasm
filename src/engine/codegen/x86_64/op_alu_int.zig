// FILE-SIZE-EXEMPT: per-op handler catalog (Wasm i32 ALU sub-language); P1 spec-defined (per ADR-0099)
//! x86_64 emit pass — i32 ALU / compare / shift / bitcount /
//! width-cross handlers (D-030 chunk-b).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape. Behaviour change zero — handler
//! bodies are unchanged from their pre-split shape; only their
//! home file moves. Signatures stay positional (allocator + buf
//! + alloc + pushed_vregs + next_vreg + op) to defer the
//! `EmitCtx` consolidation to a later chunk that materialises a
//! consumer for it.
//!
//! Handlers use spill-aware `gpr.gprLoadSpilled` /
//! `gprDefSpilled` / `gprStoreSpilled` so vregs spilled past the
//! pool boundary stage through R10/R11 transparently. Each
//! handler threads a `spill_base_off: u32` parameter.
//!
//! Handlers in this module:
//!   - `emitI32Binary`  — i32 add / sub / mul / and / or / xor.
//!   - `emitI32Compare` — i32 eq / ne / lt_s / lt_u / gt_s / gt_u
//!     / le_s / le_u / ge_s / ge_u (10 ops; SETcc + MOVZX).
//!   - `emitI32Eqz`     — TEST + SETE + MOVZX shape.
//!   - `emitI32Shift`   — shl / shr_s / shr_u / rotl / rotr;
//!     count routed through CL.
//!   - `emitI32Bitcount`— clz / ctz / popcnt via LZCNT / TZCNT
//!     / POPCNT.
//!   - `emitConvertWidth` — i32.wrap_i64 / i64.extend_i32_u /
//!     i64.extend_i32_s (MOV / MOVSXD).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");
const ctx_mod = @import("ctx.zig");
const op_simd = @import("op_simd.zig");
const op_alu_float = @import("op_alu_float.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Wasm spec §4.4.1.1 (i32 add/sub/mul/and/or/xor) — pop two
/// i32, push their result. x86_64 lowering: `MOV dst, lhs ; OP
/// dst, rhs` (always-MOV form — the peephole that elides the MOV
/// when dst == lhs lands when regalloc starts reusing slots for
/// in-place updates).
///
/// **Constraint**: dst must not equal rhs (MOV dst, lhs would
/// clobber rhs before OP reads it). With fresh-vreg-per-op
/// allocation this never fires; surfaces as `UnsupportedOp`
/// when the regalloc port needs to handle slot reuse. Note:
/// post-D-045 13b spill-aware emit, dst-stage and rhs-stage can
/// in principle collide (both R10) — D-029 follow-up.
/// `(ctx, ins)` adapter for the i32
/// binary ALU cohort (i32.add/sub/mul/and/or/xor). Threads
/// `ins.op` into the existing emitI32Binary's internal op
/// dispatch. No semantics change.
pub fn emitI32BinaryCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI32Binary(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI32Binary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    // Parallel-move for the dst==rhs case (D-029).
    // The naive `MOV dst, lhs ; OP dst, rhs` would clobber rhs
    // before the OP reads it. Strategies per op:
    // - Commutative (add/mul/and/or/xor): emit `OP dst, lhs`
    //   directly (= `dst = rhs OP lhs` = `dst = lhs OP rhs` since
    //   the op commutes).
    // - Non-commutative (sub): stage through R10 (spill_stage_gprs[0],
    //   already free at this point — its prior contents (lhs if
    //   spilled) are no longer needed after the load above).
    //   `MOV R10, lhs ; SUB R10, rhs ; MOV dst, R10`. R10 ≠ dst_r
    //   because dst_r is either a pool reg or R10; if dst_r == R10
    //   then dst is spilled, and the staging through R10 is still
    //   correct since we flush via gprStoreSpilled afterward.
    const commutative = switch (op) {
        .@"i32.add", .@"i32.mul", .@"i32.and", .@"i32.or", .@"i32.xor" => true,
        .@"i32.sub" => false,
        else => unreachable,
    };
    if (dst_r == rhs_r and dst_r != lhs_r) {
        if (commutative) {
            // OP dst, lhs  (commute: dst already holds rhs).
            const enc = switch (op) {
                .@"i32.add" => inst.encAddRR(.d, dst_r, lhs_r),
                .@"i32.mul" => inst.encImulRR(.d, dst_r, lhs_r),
                .@"i32.and" => inst.encAndRR(.d, dst_r, lhs_r),
                .@"i32.or" => inst.encOrRR(.d, dst_r, lhs_r),
                .@"i32.xor" => inst.encXorRR(.d, dst_r, lhs_r),
                else => unreachable,
            };
            try buf.appendSlice(allocator, enc.slice());
        } else {
            // i32.sub: scratch via R10. dst_r could be R10 itself
            // (when result vreg is spilled); the sequence still
            // computes lhs - rhs into dst_r correctly because the
            // final MOV dst, R10 is a no-op when dst_r == R10.
            const scratch = abi.spill_stage_gprs[0];
            try buf.appendSlice(allocator, inst.encMovRR(.d, scratch, lhs_r).slice());
            try buf.appendSlice(allocator, inst.encSubRR(.d, scratch, rhs_r).slice());
            if (dst_r != scratch) {
                try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, scratch).slice());
            }
        }
    } else {
        if (dst_r != lhs_r) {
            try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, lhs_r).slice());
        }
        const enc = switch (op) {
            .@"i32.add" => inst.encAddRR(.d, dst_r, rhs_r),
            .@"i32.sub" => inst.encSubRR(.d, dst_r, rhs_r),
            .@"i32.mul" => inst.encImulRR(.d, dst_r, rhs_r),
            .@"i32.and" => inst.encAndRR(.d, dst_r, rhs_r),
            .@"i32.or" => inst.encOrRR(.d, dst_r, rhs_r),
            .@"i32.xor" => inst.encXorRR(.d, dst_r, rhs_r),
            else => unreachable,
        };
        try buf.appendSlice(allocator, enc.slice());
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i32 eq/ne/lt/gt/le/ge — signed/unsigned
/// variants) — pop two i32, push 0 or 1. x86_64 pattern:
///
///   CMP lhs, rhs           ; sets EFLAGS based on lhs - rhs
///   SETcc dst_low8         ; writes 0 / 1 to low byte of dst
///   MOVZX dst, dst_low8    ; zero-extend to 32 bits
///
/// Total ~10 bytes per compare (3 instr × 3-4 bytes each with
/// REX). Signed vs unsigned distinction is the cc code only —
/// operand encoding is identical.
/// `(ctx, ins)` adapter for the i32
/// compare cohort (eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u).
pub fn emitI32CompareCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI32Compare(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI32Compare(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const cc: inst.Cond = switch (op) {
        .@"i32.eq" => .e,
        .@"i32.ne" => .ne,
        .@"i32.lt_s" => .l,
        .@"i32.lt_u" => .b,
        .@"i32.gt_s" => .g,
        .@"i32.gt_u" => .a,
        .@"i32.le_s" => .le,
        .@"i32.le_u" => .be,
        .@"i32.ge_s" => .ge,
        .@"i32.ge_u" => .ae,
        else => unreachable,
    };

    try buf.appendSlice(allocator, inst.encCmpRR(.d, lhs_r, rhs_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(cc, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i32.eqz) — unary "is the operand zero?".
/// Emits TEST src, src ; SETE dst_low8 ; MOVZX dst, dst_low8.
/// Same 3-instr shape as compare; operand reuse means no
/// separate rhs vreg.
/// `(ctx, ins)` adapter for `i32.eqz`.
pub fn emitI32EqzCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32Eqz(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
    );
}

pub fn emitI32Eqz(
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
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encTestRR(.d, src_r, src_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.3 (i32 shl/shr_s/shr_u/rotl/rotr — 5 ops).
/// x86_64 SHL/SHR/SAR/ROL/ROR with variable count require the
/// count in CL (RCX low byte). Emit:
///
///   MOV ECX, rhs       ; (skip if rhs already in RCX — never
///                        the case since RCX is excluded from
///                        the regalloc pool per abi.zig)
///   MOV dst, lhs       ; (skip if dst == lhs)
///   <op> dst, CL       ; D3 / kind
///
/// Wasm shift count is implicit-modulo-(width); x86_64 SHL/SHR
/// also mask the count by (width - 1), so the semantics line up
/// without an extra AND.
///
/// Constraints (caller cannot violate without UnsupportedOp):
/// - dst != RCX: RCX is the count register; would self-clobber.
///   In practice this never fires because abi.allocatable_gprs
///   excludes RCX.
/// - dst != rhs (when dst != lhs): the MOV dst, lhs would clobber
///   rhs before the shift reads CL. Guard mirrors emitI32Binary.
/// `(ctx, ins)` adapter for the i32
/// shift cohort (shl/shr_s/shr_u/rotl/rotr).
pub fn emitI32ShiftCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI32Shift(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI32Shift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    if (dst_r == .rcx) return types.rejectUnsupported("src/engine/codegen/x86_64/op_alu_int.zig:210", 0);
    // dst==rhs case is naturally safe here because
    // step 1 below copies rhs to RCX BEFORE step 2 overwrites dst
    // with lhs. So dst's old value (= rhs's value) is preserved
    // in RCX/CL by the time the shift fires. Earlier rejects
    // were defensive duplicates of the binary-ALU pattern that
    // doesn't apply to shifts.

    // 1. Move shift count into ECX (CL is the low byte). This
    //    happens BEFORE step 2 so the dst==rhs sequence works.
    if (rhs_r != .rcx) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, rhs_r).slice());
    }
    // 2. Materialise lhs into dst (skip if already same reg).
    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, lhs_r).slice());
    }
    // 3. Shift / rotate.
    const kind: inst.ShiftKind = switch (op) {
        .@"i32.shl" => .shl,
        .@"i32.shr_s" => .sar,
        .@"i32.shr_u" => .shr,
        .@"i32.rotl" => .rol,
        .@"i32.rotr" => .ror,
        else => unreachable,
    };
    try buf.appendSlice(allocator, inst.encShiftRCl(.d, kind, dst_r).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.4 (i32 clz/ctz/popcnt — 3 ops). Direct 1:1
/// mapping to LZCNT / TZCNT / POPCNT (BMI1 + POPCNT extensions).
/// All three:
/// - Take src in r/m and write dst in reg (operand-role
///   inversion vs the ADD/SUB/CMP family).
/// - Return 32 for input 0 (LZCNT/TZCNT) which matches Wasm
///   spec — the older BSR/BSF would leave dst undefined at 0
///   and would need a fixup; LZCNT/TZCNT exist exactly to
///   provide defined-at-zero semantics.
/// `(ctx, ins)` adapter for the i32
/// bitcount cohort (clz/ctz/popcnt).
pub fn emitI32BitcountCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI32Bitcount(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI32Bitcount(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const enc = switch (op) {
        .@"i32.clz" => inst.encLzcntR32(dst_r, src_r),
        .@"i32.ctz" => inst.encTzcntR32(dst_r, src_r),
        .@"i32.popcnt" => inst.encPopcntR32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.1 (i64 add / sub / mul / and / or / xor) —
/// 64-bit counterpart of `emitI32Binary`. Identical handler shape;
/// only the encoder Width changes from `.d` to `.q` (REX.W set
/// → 64-bit operands).
/// `(ctx, ins)` adapter for the i64
/// binary ALU cohort (i64.add/sub/mul/and/or/xor). Threads
/// `ins.op` into emitI64Binary's internal op dispatch. No
/// semantics change.
pub fn emitI64BinaryCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI64Binary(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI64Binary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    // Mirrors emitI32Binary — commute commutative
    // ops, scratch through R10 for sub. See emitI32Binary for the
    // detailed rationale.
    const commutative = switch (op) {
        .@"i64.add", .@"i64.mul", .@"i64.and", .@"i64.or", .@"i64.xor" => true,
        .@"i64.sub" => false,
        else => unreachable,
    };
    if (dst_r == rhs_r and dst_r != lhs_r) {
        if (commutative) {
            const enc = switch (op) {
                .@"i64.add" => inst.encAddRR(.q, dst_r, lhs_r),
                .@"i64.mul" => inst.encImulRR(.q, dst_r, lhs_r),
                .@"i64.and" => inst.encAndRR(.q, dst_r, lhs_r),
                .@"i64.or" => inst.encOrRR(.q, dst_r, lhs_r),
                .@"i64.xor" => inst.encXorRR(.q, dst_r, lhs_r),
                else => unreachable,
            };
            try buf.appendSlice(allocator, enc.slice());
        } else {
            const scratch = abi.spill_stage_gprs[0];
            try buf.appendSlice(allocator, inst.encMovRR(.q, scratch, lhs_r).slice());
            try buf.appendSlice(allocator, inst.encSubRR(.q, scratch, rhs_r).slice());
            if (dst_r != scratch) {
                try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, scratch).slice());
            }
        }
    } else {
        if (dst_r != lhs_r) {
            try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, lhs_r).slice());
        }
        const enc = switch (op) {
            .@"i64.add" => inst.encAddRR(.q, dst_r, rhs_r),
            .@"i64.sub" => inst.encSubRR(.q, dst_r, rhs_r),
            .@"i64.mul" => inst.encImulRR(.q, dst_r, rhs_r),
            .@"i64.and" => inst.encAndRR(.q, dst_r, rhs_r),
            .@"i64.or" => inst.encOrRR(.q, dst_r, rhs_r),
            .@"i64.xor" => inst.encXorRR(.q, dst_r, rhs_r),
            else => unreachable,
        };
        try buf.appendSlice(allocator, enc.slice());
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i64 eq / ne / lt_{s,u} / gt_{s,u} /
/// le_{s,u} / ge_{s,u}) — 64-bit comparison; result is i32 0/1.
/// CMP becomes 64-bit (.q) but SETcc + MOVZX stay 8/32-bit since
/// the result is i32.
/// `(ctx, ins)` adapter for the i64
/// compare cohort (10 ops; same shape as i32 compare).
pub fn emitI64CompareCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI64Compare(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI64Compare(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const cc: inst.Cond = switch (op) {
        .@"i64.eq" => .e,
        .@"i64.ne" => .ne,
        .@"i64.lt_s" => .l,
        .@"i64.lt_u" => .b,
        .@"i64.gt_s" => .g,
        .@"i64.gt_u" => .a,
        .@"i64.le_s" => .le,
        .@"i64.le_u" => .be,
        .@"i64.ge_s" => .ge,
        .@"i64.ge_u" => .ae,
        else => unreachable,
    };

    try buf.appendSlice(allocator, inst.encCmpRR(.q, lhs_r, rhs_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(cc, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i64.eqz) — TEST is 64-bit (.q); SETcc +
/// MOVZX stay 8/32-bit (i32 result).
/// `(ctx, ins)` adapter for `i64.eqz`.
pub fn emitI64EqzCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64Eqz(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
    );
}

pub fn emitI64Eqz(
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
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encTestRR(.q, src_r, src_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.3 (i64 shl / shr_s / shr_u / rotl / rotr) —
/// 64-bit shift family. CL is the count register (shared with
/// i32 shifts; abi.zig already excludes RCX from the regalloc
/// pool). The MOV ECX, rhs is 32-bit since only CL is read.
/// `(ctx, ins)` adapter for the i64
/// shift cohort.
pub fn emitI64ShiftCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI64Shift(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI64Shift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    if (dst_r == .rcx) return types.rejectUnsupported("src/engine/codegen/x86_64/op_alu_int.zig:408", 0);
    // dst==rhs case naturally safe — see emitI32Shift
    // for the rationale. RCX move precedes dst overwrite.

    if (rhs_r != .rcx) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, rhs_r).slice());
    }
    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, lhs_r).slice());
    }
    const kind: inst.ShiftKind = switch (op) {
        .@"i64.shl" => .shl,
        .@"i64.shr_s" => .sar,
        .@"i64.shr_u" => .shr,
        .@"i64.rotl" => .rol,
        .@"i64.rotr" => .ror,
        else => unreachable,
    };
    try buf.appendSlice(allocator, inst.encShiftRCl(.q, kind, dst_r).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.4 (i64 clz / ctz / popcnt) — direct mapping
/// to LZCNT64 / TZCNT64 / POPCNT64 (REX.W variants). Defined-at-
/// zero semantics match Wasm (returns 64 for input 0).
/// `(ctx, ins)` adapter for the i64
/// bitcount cohort.
pub fn emitI64BitcountCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI64Bitcount(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitI64Bitcount(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const enc = switch (op) {
        .@"i64.clz" => inst.encLzcntR64(dst_r, src_r),
        .@"i64.ctz" => inst.encTzcntR64(dst_r, src_r),
        .@"i64.popcnt" => inst.encPopcntR64(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.4 (i32.extend8_s / i32.extend16_s /
/// i64.extend8_s / i64.extend16_s / i64.extend32_s) — Wasm 2.0
/// sign-extension ops. Pop one int, push the same-width int with
/// the low N bits sign-extended through the rest. x86_64 lowering:
/// MOVSX r32/r64, r/m8/16 (Intel SDM Vol 2 §3.2 MOVSX); the
/// `i64.extend32_s` arm uses MOVSXD (REX.W + 0x63 /r). Mirrors
/// arm64's SXTB/SXTH/SXTW (Arm IHI 0055 §C6.2.220).
/// `(ctx, ins)` adapter for the
/// sign-extension cohort (5 ops).
pub fn emitSignExtendCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitSignExtend(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitSignExtend(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const enc = switch (op) {
        .@"i32.extend8_s" => inst.encMovsxR32R8(dst_r, src_r),
        .@"i32.extend16_s" => inst.encMovsxR32R16(dst_r, src_r),
        .@"i64.extend8_s" => inst.encMovsxR64R8(dst_r, src_r),
        .@"i64.extend16_s" => inst.encMovsxR64R16(dst_r, src_r),
        .@"i64.extend32_s" => inst.encMovsxdR64R32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.1 (i32 / i64 div_s / div_u / rem_s / rem_u
/// — 8 ops total). Pop two ints, push quotient or remainder. All
/// 8 ops trap on divide-by-zero; div_s additionally traps on
/// signed overflow (INT_MIN / -1) per Wasm spec.
///
/// x86_64 lowering (per Intel SDM Vol 2 §3.2 IDIV / DIV):
///
///   TEST  divisor, divisor       ; ZF=1 iff divisor==0
///   Jcc.E trap_stub              ; div-by-zero trap (6-byte JZ rel32)
///   MOV   EAX/RAX, lhs           ; load dividend low half
///   CDQ / CQO  (signed) | XOR EDX,EDX (unsigned) ; high half
///   IDIV / DIV divisor           ; quotient → RAX, remainder → RDX
///   MOV   dst, EAX/RAX           ; or RDX/EDX for rem
///
/// **Signed overflow** (`div_s` / `rem_s` only):
/// Wasm spec §4.4.1.1 says `INT_MIN / -1` traps on `div_s` (the
/// quotient `2^(N-1)` is unrepresentable) but `rem_s` returns
/// `0` (`INT_MIN - INT_MIN*(-1)` wraps to 0). On x86_64, IDIV
/// raises `#DE` for both shapes — without a pre-check the JIT
/// process crashes. The handler emits a 4-step guard before
/// IDIV when `is_signed`:
///
///   CMP rhs, -1        ; (imm8 sign-extended to width)
///   JNE skip           ; rel32, patch-back at end
///   CMP lhs, INT_MIN   ; .d uses CMP r32 imm32; .q uses
///                      ; MOVABS RAX, INT_MIN_64 + CMP r64, RAX
///   JNE skip           ; rel32, patch-back at end
///   ; both conditions met:
///   <div_s>:  JE trap_stub   ; rel32, registered on bounds_fixups
///   <rem_s>:  XOR dst, dst   ; rem result is 0; then JMP done
///   skip:                    ; patch target for the two JNEs
///   <existing IDIV path>     ; MOV RAX, lhs; CDQ/CQO/XOR; IDIV
///   done:                    ; rem_s patches its skip-IDIV JMP here
///
/// `RAX` and `RDX` are clobbered. They are not in the regalloc
/// pool (allocatable_gprs = RBX,R12,R13,R14 per ADR-0026), so
/// live-vreg homes are unaffected. Spill stages R10/R11 are
/// also disjoint from RAX/RDX.
fn emitDivRemImpl(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    divzero_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    width: inst.Width,
    is_signed: bool,
    is_rem: bool,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    // Div-by-zero check: TEST divisor, divisor ; JZ trap_stub (code 7).
    try buf.appendSlice(allocator, inst.encTestRR(width, rhs_r, rhs_r).slice());
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
    try divzero_fixups.append(allocator, fixup_at);

    // Signed overflow check (div_s / rem_s only). See the
    // function-level docstring for the 4-step guard sequence.
    var skip_idiv_jmp_at: ?u32 = null;
    if (is_signed) {
        // CMP rhs_r, -1 (imm8 sign-extends to width).
        try buf.appendSlice(allocator, inst.encCmpRImm8(width, rhs_r, -1).slice());
        // JNE skip (rel32 placeholder; patched after we know skip's offset).
        const jne_rhs_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());

        // CMP lhs_r, INT_MIN. .d uses CMP r32, imm32; .q has no
        // imm32 form for INT_MIN_64 (sign-extended imm32 cannot
        // express 0x8000_0000_0000_0000), so materialise via
        // MOVABS RAX, INT_MIN_64 + CMP r64, RAX. RAX is unused at
        // this point and is about to be clobbered by IDIV anyway.
        if (width == .d) {
            try buf.appendSlice(allocator, inst.encCmpRImm32(lhs_r, 0x80000000).slice());
        } else {
            try buf.appendSlice(allocator, inst.encMovImm64Q(.rax, 0x8000_0000_0000_0000).slice());
            try buf.appendSlice(allocator, inst.encCmpRR(.q, lhs_r, .rax).slice());
        }
        const jne_lhs_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());

        if (is_rem) {
            // INT_MIN/-1 rem_s spec result is 0; emit XOR dst,dst
            // then skip past the standard IDIV path.
            try buf.appendSlice(allocator, inst.encXorRR(width, dst_r, dst_r).slice());
            skip_idiv_jmp_at = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
        } else {
            // div_s: trap. Z is set from the second CMP (lhs == INT_MIN
            // on this path), so JE is guaranteed taken. Routed to the
            // dedicated signed-overflow stub (code 8) so it surfaces
            // int_overflow, NOT div_by_zero (ADR-0164 A2 / D-292).
            const trap_jmp_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            try overflow_fixups.append(allocator, trap_jmp_at);
        }

        // Patch the two JNE rel32 placeholders to point at the
        // current position (= the start of the standard IDIV path).
        const skip_target: u32 = @intCast(buf.items.len);
        inst.patchRel32(buf.items, jne_rhs_at, 6, @as(i32, @intCast(skip_target)) - (@as(i32, @intCast(jne_rhs_at)) + 6));
        inst.patchRel32(buf.items, jne_lhs_at, 6, @as(i32, @intCast(skip_target)) - (@as(i32, @intCast(jne_lhs_at)) + 6));
    }

    // Move dividend into RAX (low half).
    try buf.appendSlice(allocator, inst.encMovRR(width, .rax, lhs_r).slice());
    // Sign-extend / zero-extend dividend into RDX:RAX.
    if (is_signed) {
        const cdq_enc = if (width == .q) inst.encCqo() else inst.encCdq();
        try buf.appendSlice(allocator, cdq_enc.slice());
    } else {
        try buf.appendSlice(allocator, inst.encXorRR(.d, .rdx, .rdx).slice());
    }
    // IDIV / DIV. Operand-size is width.
    const div_enc = blk: {
        if (width == .q) {
            break :blk if (is_signed) inst.encIdivR64(rhs_r) else inst.encDivR64(rhs_r);
        } else {
            break :blk if (is_signed) inst.encIdivR32(rhs_r) else inst.encDivR32(rhs_r);
        }
    };
    try buf.appendSlice(allocator, div_enc.slice());
    // Move result (RAX for quotient, RDX for remainder) into dst.
    const result_src: inst.Gpr = if (is_rem) .rdx else .rax;
    if (dst_r != result_src) {
        try buf.appendSlice(allocator, inst.encMovRR(width, dst_r, result_src).slice());
    }
    // rem_s INT_MIN/-1 path patched its skip-IDIV JMP to land here
    // (after MOV dst_r, RDX, before the spill store).
    if (skip_idiv_jmp_at) |at| {
        const target: u32 = @intCast(buf.items.len);
        inst.patchRel32(buf.items, at, 5, @as(i32, @intCast(target)) - (@as(i32, @intCast(at)) + 5));
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Public entry — i32 div / rem dispatch.
pub fn emitI32DivRem(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    divzero_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    const is_signed = switch (op) {
        .@"i32.div_s", .@"i32.rem_s" => true,
        .@"i32.div_u", .@"i32.rem_u" => false,
        else => unreachable,
    };
    const is_rem = switch (op) {
        .@"i32.rem_s", .@"i32.rem_u" => true,
        .@"i32.div_s", .@"i32.div_u" => false,
        else => unreachable,
    };
    return emitDivRemImpl(allocator, buf, alloc, pushed_vregs, next_vreg, divzero_fixups, overflow_fixups, spill_base_off, .d, is_signed, is_rem);
}

/// Public entry — i64 div / rem dispatch.
pub fn emitI64DivRem(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    divzero_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    const is_signed = switch (op) {
        .@"i64.div_s", .@"i64.rem_s" => true,
        .@"i64.div_u", .@"i64.rem_u" => false,
        else => unreachable,
    };
    const is_rem = switch (op) {
        .@"i64.rem_s", .@"i64.rem_u" => true,
        .@"i64.div_s", .@"i64.div_u" => false,
        else => unreachable,
    };
    return emitDivRemImpl(allocator, buf, alloc, pushed_vregs, next_vreg, divzero_fixups, overflow_fixups, spill_base_off, .q, is_signed, is_rem);
}

/// Wasm spec §4.4.1.4 (i32.wrap_i64 / i64.extend_i32_u /
/// i64.extend_i32_s) — i32 ↔ i64 width-cross. `i32.wrap_i64`
/// and `i64.extend_i32_u` both lower to `MOV r32_dst, r32_src`
/// (the 32-bit write zero-extends the upper half of the
/// destination's 64-bit slot, matching Wasm's value-class
/// representation). `i64.extend_i32_s` lowers to MOVSXD.
/// Mirrors arm64/op_convert.zig's emitWrap32 / emitExtendI32S.
/// `(ctx, ins)` adapter for the
/// width-conversion cohort (i32.wrap_i64, i64.extend_i32_{s,u}).
pub fn emitConvertWidthCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitConvertWidth(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitConvertWidth(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const enc = switch (op) {
        .@"i32.wrap_i64", .@"i64.extend_i32_u" => inst.encMovRR(.d, dst_r, src_r),
        .@"i64.extend_i32_s" => inst.encMovsxdR64R32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// `(ctx, ins)` adapters for the
/// i32 div/rem cohort. Unpack `ctx.*` fields into the existing
/// 8-arg `emitI32DivRem` positional impl, which dispatches on
/// `ins.op` internally. All four variants share the same body —
/// per-op aliases preserve the per-op-file shape expected by
/// the dispatch-collector contract (each per-op file's `emit`
/// fn names a distinct symbol).
pub fn emitI32DivS(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI32DivRem(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.divzero_fixups,
        ctx.overflow_fixups,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI32DivU = emitI32DivS;
pub const emitI32RemS = emitI32DivS;
pub const emitI32RemU = emitI32DivS;

/// `(ctx, ins)` adapter for the i64 div/rem cohort. Same shape
/// as the i32 cohort; dispatches into `emitI64DivRem` on
/// `ins.op`.
pub fn emitI64DivS(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitI64DivRem(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.divzero_fixups,
        ctx.overflow_fixups,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI64DivU = emitI64DivS;
pub const emitI64RemS = emitI64DivS;
pub const emitI64RemU = emitI64DivS;

/// `(ctx, ins)` adapter for `i32.const`.
/// Allocates a fresh vreg, emits `MOV r32, imm32`, stores to spill.
///
/// Wasm spec §4.4.1.1 (i32.const).
pub fn emitI32Const(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst = try gpr.gprDefSpilled(ctx.alloc, vreg, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(dst, @truncate(ins.payload)).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// `(ctx, ins)` adapter for `i64.const`.
/// Allocates a fresh vreg, emits `MOVABS r64, imm64` (10 bytes),
/// stores to spill.
///
/// Wasm spec §4.4.1.1 (i64.const). The 64-bit immediate is packed
/// into `(ins.extra << 32) | ins.payload` per the ZIR encoding.
pub fn emitI64Const(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst = try gpr.gprDefSpilled(ctx.alloc, vreg, 0);
    const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(dst, value).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// `(ctx, ins)` adapter for `select` +
/// `select_typed` (shared dispatch). Pops c / val2 / val1; pushes
/// val1 if c != 0 else val2. Three-path dispatch per
/// ADR-0056:
///   - v128 → `op_simd.emitV128Select` (mask-based)
///   - f32/f64 → `op_alu_float.emitFpSelect` (MOVD/Q shuttle +
///     CMOVNE; x86 has no FP CMOV). Detected via `ins.extra`
///     ∈ {0x7C, 0x7D} (Wasm valtype encoding).
///   - i32 / i64 / funcref / externref → inline GPR path with
///     D-097 d-18 alias-aware CMOV direction.
///
/// Wasm spec §4.4.4 / §3.3.2.2.
pub fn emitSelectCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const cond_v = ctx.pushed_vregs.pop().?;
    const val2_v = ctx.pushed_vregs.pop().?;
    const val1_v = ctx.pushed_vregs.pop().?;
    const result_v = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_v >= ctx.alloc.slots.len) return Error.SlotOverflow;
    if (ctx.alloc.shapeTag(val1_v) == .v128) {
        try op_simd.emitV128Select(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond_v, val1_v, val2_v, result_v);
        try ctx.pushed_vregs.append(ctx.allocator, result_v);
        return;
    }
    if (ins.extra == 0x7D or ins.extra == 0x7C) {
        try op_alu_float.emitFpSelect(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ctx.pushed_vregs, ins.extra == 0x7C, cond_v, val1_v, val2_v, result_v);
        return;
    }
    // GPR path. D-097 d-18: pick CMOV direction so MOV is self-MOV
    // (or skipped) when result_v aliases val1_v or val2_v.
    const cond_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond_v, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    const val2_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val2_v, 1);
    const val1_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val1_v, 0);
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, result_v, 0);
    if (dst_r == val2_r) {
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmovccRR(.q, .ne, dst_r, val1_r).slice());
    } else {
        if (dst_r != val1_r) {
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, dst_r, val1_r).slice());
        }
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmovccRR(.q, .e, dst_r, val2_r).slice());
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_v);
}

/// `(ctx, ins)` adapter for `ref.null`.
/// Pushes the null funcref/externref value (= 0). XOR-zero the
/// 32-bit form implicitly clears the upper 32 bits.
///
/// Wasm spec §4.4.5 (ref.null t).
pub fn emitRefNull(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, vreg, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encXorRR(.d, dst_r, dst_r).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// `(ctx, ins)` adapter for `ref.func`.
/// Loads func_entities_ptr from R15, then ADDs `funcidx *
/// sizeOf(FuncEntity)` to materialise the FuncEntity pointer.
///
/// Wasm spec §4.4.5 (ref.func x).
pub fn emitRefFunc(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, vreg, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(dst_r, abi.runtime_ptr_save_gpr, jit_abi.func_entities_ptr_off).slice());
    const byte_off: u64 = @as(u64, ins.payload) * jit_abi.func_entity_size;
    if (byte_off != 0) {
        // ADD r64, imm32 (7 bytes). byte_off > i32 max requires
        // ~134M entries (sizeOf(FuncEntity) ≈ 16) — caught by
        // validator's funcidx bounds long before reaching here.
        if (byte_off > 0x7FFFFFFF) return Error.UnsupportedOp;
        try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(dst_r, @intCast(byte_off)).slice());
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

// Wasm wide-arithmetic (ADR-0168 v0.2) — the first 2-result ops.
// RAX/RDX are reserved (non-allocatable; mul/div-implicit), so they
// serve as the carry-chain / product accumulators without colliding
// with the R10/R11 spill-stage regs that gprLoadSpilled uses. MOV and
// memory-load do NOT clobber CF, so the carry survives ADD→ADC. Results
// captured into 2 vregs (next_vreg++ ×2, mirror captureCallResult).

/// MOV/store accumulator `src` (RAX or RDX) into result vreg `vreg`.
fn captureWideX86(ctx: *ctx_mod.EmitCtx, vreg: u32, src: inst.Gpr) Error!void {
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst = try gpr.gprDefSpilled(ctx.alloc, vreg, 0);
    if (dst != src) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, dst, src).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// `i64.add128` / `i64.sub128` — pop [a_lo, a_hi, b_lo, b_hi], push
/// [r_lo, r_hi]. RAX = a_lo (±) b_lo (CF); RDX = a_hi (±) b_hi (±CF).
pub fn emitWideAddSub128(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 4) return Error.AllocationMissing;
    const b_hi_v = ctx.pushed_vregs.pop().?;
    const b_lo_v = ctx.pushed_vregs.pop().?;
    const a_hi_v = ctx.pushed_vregs.pop().?;
    const a_lo_v = ctx.pushed_vregs.pop().?;
    const is_sub = ins.op == .@"i64.sub128";
    const a_lo = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_lo_v, 0);
    if (a_lo != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rax, a_lo).slice());
    const b_lo = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_lo_v, 1);
    try ctx.buf.appendSlice(ctx.allocator, if (is_sub) inst.encSubRR(.q, .rax, b_lo).slice() else inst.encAddRR(.q, .rax, b_lo).slice());
    const a_hi = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_hi_v, 0);
    if (a_hi != .rdx) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rdx, a_hi).slice());
    const b_hi = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_hi_v, 1);
    try ctx.buf.appendSlice(ctx.allocator, if (is_sub) inst.encSbbRR(.q, .rdx, b_hi).slice() else inst.encAdcRR(.q, .rdx, b_hi).slice());
    const r_lo = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideX86(ctx, r_lo, .rax);
    const r_hi = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideX86(ctx, r_hi, .rdx);
}

/// `i64.mul_wide_s` / `i64.mul_wide_u` — pop [a, b], push [lo, hi].
/// RAX = a; (I)MUL b → RDX:RAX (RAX = lo, RDX = hi).
pub fn emitWideMul(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const b_v = ctx.pushed_vregs.pop().?;
    const a_v = ctx.pushed_vregs.pop().?;
    const a = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_v, 0);
    if (a != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rax, a).slice());
    const b = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_v, 1);
    const signed = ins.op == .@"i64.mul_wide_s";
    try ctx.buf.appendSlice(ctx.allocator, if (signed) inst.encImul1(.q, b).slice() else inst.encMul1(.q, b).slice());
    const r_lo = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideX86(ctx, r_lo, .rax);
    const r_hi = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideX86(ctx, r_hi, .rdx);
}
