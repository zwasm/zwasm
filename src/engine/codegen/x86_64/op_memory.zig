// FILE-SIZE-EXEMPT: per-instruction-class catalog (D-030), same class as its 12 marked x86_64 op_* siblings (investigated 2026-08-12, per ADR-0099)
//! x86_64 emit pass — memory load/store handlers (D-030 chunk-e).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_memory.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Single handler covers the i32 + f32 + f64 memory family
//! (8-byte aligned access size derived from op tag):
//!
//!   - i32.load{,8_s,8_u,16_s,16_u}, i32.store{,8,16}
//!   - f32.load, f32.store, f64.load, f64.store
//!
//! Shared eff-addr + spec-strict bounds-check prologue per Wasm
//! 1.0 spec §4.4.7 (memory.{load,store}): trap iff
//! `eff_addr + access_size > mem_limit`.
//!
//! RAX/RCX/RDX are outside the regalloc pool (`abi.zig`). The
//! op never coexists with i32 shift handlers within a single ZIR
//! instruction window, so RCX usage as bounds-check scratch is
//! safe (shifts also touch RCX as CL but only within their own
//! handler, never overlapping with this op).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");
const build_options = @import("build_options");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const op_call = @import("op_call.zig");
const trace = @import("../../../diagnostic/trace.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Wasm spec §4.4.7 (memory.load / memory.store family) — unified
/// handler for x86_64 memory ops (loads + stores + narrowed forms).
/// Mirrors `arm64/op_memory.zig:emitMemOp`'s shape: shared eff-addr
/// / bounds-check prologue, per-op final MOV/MOVZX/MOVSX encoding.
///
/// Per-op shape (load, spec-strict bounds: ea + size > mem_limit traps):
///   MOV RAX, [R15 + vm_base_off]
///   MOV EDX, idx_r              ; zero-extend idx → 64-bit RDX (= ea base)
///   ADD RDX, offset             ; (skipped if offset == 0)
///   LEA RCX, [RDX + access_size]; RCX = ea + size, RDX unchanged (for load addressing)
///   CMP RCX, [R15 + mem_limit_off]
///   JA  trap_stub               ; unsigned > ; oob_fixups append
///   MOV[ZX|SX] dst, ... [RAX + RDX]
///
/// Per-op shape (store): same prologue, final form is
///   MOV [RAX + RDX], src        ; (32-bit, 16-bit, or 8-bit)
///
/// Per Wasm 1.0 spec §4.4.7: trap iff
/// `eff_addr + access_size > mem_limit` where access_size ∈
/// {1, 2, 4, 8}. No overflow possible in u64 arithmetic (max ≈ 2^33+7).
///
/// RAX/RCX/RDX are outside the regalloc pool (allocatable_caller_saved_
/// scratch_gprs = R10+R11 only; RAX/RCX/RDX are reserved for scratch).
/// Shifts use RCX as CL, but the shift handler and the memory handler
/// never overlap within a single op, so using RCX as bounds-check
/// scratch is safe.
pub fn emitMemOp(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oob_fixups: *std.ArrayList(u32),
    unaligned_atomic_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    op: zir.ZirOp,
    offset: u32,
    func_idx: u32,
    bounds_elided: bool,
) Error!void {
    const is_store = switch (op) {
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
    const is_fp = switch (op) {
        .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
        else => false,
    };
    // D-303 — atomic load/store trap on unaligned ea (spec exec step 8, BEFORE
    // bounds). The inline path omitted the check the interp has (memory.zig:202).
    const is_atomic = switch (op) {
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

    var idx_v: u32 = 0;
    var val_v: u32 = 0;
    if (is_store) {
        if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
        val_v = pushed_vregs.pop().?;
        idx_v = pushed_vregs.pop().?;
    } else {
        if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
        idx_v = pushed_vregs.pop().?;
    }
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);

    // Per-op access size in bytes (Wasm spec memory.{load,store} family).
    // Exhaustive switch (`require_exhaustive_enum_switch` lint gate);
    // the dispatcher never passes anything other than a memory op, so
    // `else` is unreachable.
    const access_size: i8 = switch (op) {
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
        .@"f32.load",
        .@"f32.store",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"i64.atomic.load32_u",
        .@"i32.atomic.store",
        .@"i64.atomic.store32",
        .@"i64.store32",
        => 4,
        .@"i64.load", .@"i64.atomic.load", .@"i64.atomic.store", .@"i64.store", .@"f64.load", .@"f64.store" => 8,
        else => unreachable,
    };

    // Shared eff-addr + spec-strict bounds-check prologue.
    // ea = idx_r (zero-extended u32) + offset; trap iff ea + size > mem_limit.
    // No overflow possible in u64 arithmetic: max(ea + size) = 2^33 + 7 << 2^64.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, idx_r).slice());
    if (offset != 0) {
        // arm64 mirror. memarg.offset is u32
        // per Wasm spec §5.4.6; emcc/clang -O2 can emit values past
        // the imm32 sign-extended range (0x7FFFFFFF) when data
        // segment + array index crosses 2 GiB. Lower as MOVABS RCX
        // (10 bytes) + ADD RDX, RCX (3 bytes) — RCX is overwritten
        // by the next LEA RCX, [RDX + access_size] so the scratch
        // use is invariant-clean.
        if (offset <= 0x7FFFFFFF) {
            try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, @intCast(offset)).slice());
        } else {
            try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, @as(u64, offset)).slice());
            try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .rcx).slice());
        }
    }
    // D-303 — atomic alignment trap BEFORE bounds (spec exec step 8 < 14a). ea
    // is in RDX; TEST its low (size-1) bits, JNE → unaligned_atomic stub.
    if (is_atomic and access_size > 1) {
        try buf.appendSlice(allocator, inst.encTestRImm32(.d, .rdx, @as(u32, @intCast(access_size - 1))).slice());
        const al_fixup: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice()); // nonzero low bits = unaligned
        try unaligned_atomic_fixups.append(allocator, al_fixup);
    }
    // ADR-0202 D4 — elided: the guard-page reservation covers every
    // reachable ea; an oob access hardware-faults and the fault→trap
    // handler redirects to the force-emitted kind=6 stub. The vm_base
    // load + ea materialise stay (they feed the access); only the
    // mem_limit reload + CMP + JA go. The atomic ALIGNMENT check above
    // is NOT elided.
    if (!bounds_elided) {
        try buf.appendSlice(allocator, inst.encLeaR64BaseDisp8(.rcx, .rdx, access_size).slice());
        try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rcx, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice()); // unsigned >
        try oob_fixups.append(allocator, fixup_at);
        // ADR-0028 M3-a-1: record bounds-check emit site (no-op when
        // -Dtrace-ringbuffer=false; comptime-folded out of release).
        trace.writeBounds(func_idx, fixup_at);
    }

    // Per-op final encoding.
    if (is_store) {
        if (is_fp) {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 0);
            const kind: inst.SseScalarKind = if (op == .@"f64.store") .f64 else .f32;
            try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(kind, true, src_x, .rax, .rdx).slice());
        } else {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 1);
            const enc = switch (op) {
                .@"i32.store", .@"i32.atomic.store" => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
                .@"i32.store8", .@"i32.atomic.store8" => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
                .@"i32.store16", .@"i32.atomic.store16" => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store", .@"i64.atomic.store" => inst.encStoreR64MemBaseIdx(src_r, .rax, .rdx),
                // i64.store{8,16,32}: low N bits of the GPR; same
                // encoders as i32.store{8,16} + a 32-bit-store form
                // for the .32 variant.
                .@"i64.store8", .@"i64.atomic.store8" => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store16", .@"i64.atomic.store16" => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store32", .@"i64.atomic.store32" => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
                else => unreachable,
            };
            try buf.appendSlice(allocator, enc.slice());
        }
    } else {
        const result_v = next_vreg.*;
        next_vreg.* += 1;
        if (result_v >= alloc.slots.len) return Error.SlotOverflow;
        if (is_fp) {
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);
            const kind: inst.SseScalarKind = if (op == .@"f64.load") .f64 else .f32;
            try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(kind, false, dst_x, .rax, .rdx).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
        } else {
            const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
            const enc = switch (op) {
                .@"i32.load", .@"i32.atomic.load" => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load8_s" => inst.encMovsxR32_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load8_u", .@"i32.atomic.load8_u" => inst.encMovzxR32_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load16_s" => inst.encMovsxR32_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load16_u", .@"i32.atomic.load16_u" => inst.encMovzxR32_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load", .@"i64.atomic.load" => inst.encMovR64FromBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load8_s" => inst.encMovsxR64_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load8_u", .@"i64.atomic.load8_u" => inst.encMovzxR64_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load16_s" => inst.encMovsxR64_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load16_u", .@"i64.atomic.load16_u" => inst.encMovzxR64_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load32_s" => inst.encMovsxdR64_32MemBaseIdx(dst_r, .rax, .rdx),
                // i64.load32_u: MOV r32 zero-extends to r64 by AMD64
                // architectural rule (Intel SDM Vol 1 §3.4.1.1), so
                // the i32 encoder gives the right semantics for free.
                .@"i64.load32_u", .@"i64.atomic.load32_u" => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
                else => unreachable,
            };
            try buf.appendSlice(allocator, enc.slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
        }
        try pushed_vregs.append(allocator, result_v);
    }
}

/// `(ctx, ins)` adapter for the
/// scalar load/store cohort (23 ops via the shared `emitMemOp`
/// helper). Single primary + 22 aliases (all variants share the
/// same body — the legacy impl dispatches on `ins.op` internally
/// to pick MOV / MOVZX / MOVSX shapes).
pub fn emitI32Load(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    // ADR-0111 D3: `MemArgExtra.memidx == 0` invariant — codegen
    // only sees memory 0 until multi-memory routing lands
    // (instantiate-side reject lift + per-memidx vm_base/mem_limit
    // plumbing). The runtime assert codifies the prose invariant
    // per `.claude/rules/comment_as_invariant.md`.
    const memarg = zir.MemArgExtra.unpack(ins.extra);
    std.debug.assert(memarg.memidx == 0);
    // ADR-0111 D4 — 2-stage gate (comptime + runtime). Mirrors
    // arm64/op_memory.zig::emitMemOp; see that file for the full
    // design rationale. v2.0 builds prune the i64 arm via comptime
    // DCE; v3.0 + idx_type=.i32 takes the byte-identical fast path
    // (existing emit_test_int memory asserts verify); v3.0 +
    // idx_type=.i64 dispatches to emitMemOpI64.
    if (comptime @intFromEnum(build_options.wasm_level) >= @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) {
        if (ctx.memory0_idx_type == .i64) {
            return emitMemOpI64(ctx, ins);
        }
    }
    return emitMemOp(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.oob_fixups,
        ctx.unaligned_atomic_fixups,
        ctx.spill_base_off,
        ins.op,
        @as(u32, @intCast(ins.payload)),
        ctx.func_idx,
        ctx.bounds_elided,
    );
}
pub const emitI32Load8S = emitI32Load;
pub const emitI32AtomicLoad = emitI32Load; // threads (ADR-0168) — forwards ins.op to emitMemOp
pub const emitI64AtomicLoad = emitI32Load; // forwards ins.op to emitMemOp (i64.atomic.load)
pub const emitI32AtomicLoad8U = emitI32Load;
pub const emitI32AtomicLoad16U = emitI32Load;
pub const emitI64AtomicLoad8U = emitI32Load;
pub const emitI64AtomicLoad16U = emitI32Load;
pub const emitI64AtomicLoad32U = emitI32Load;
pub const emitI32AtomicStore = emitI32Load;
pub const emitI64AtomicStore = emitI32Load;
pub const emitI32AtomicStore8 = emitI32Load;
pub const emitI32AtomicStore16 = emitI32Load;
pub const emitI64AtomicStore8 = emitI32Load;
pub const emitI64AtomicStore16 = emitI32Load;
pub const emitI64AtomicStore32 = emitI32Load;
pub const emitI32Load8U = emitI32Load;
pub const emitI32Load16S = emitI32Load;
pub const emitI32Load16U = emitI32Load;
pub const emitI32Store = emitI32Load;
pub const emitI32Store8 = emitI32Load;
pub const emitI32Store16 = emitI32Load;
pub const emitI64Load = emitI32Load;
pub const emitI64Load8S = emitI32Load;
pub const emitI64Load8U = emitI32Load;
pub const emitI64Load16S = emitI32Load;
pub const emitI64Load16U = emitI32Load;
pub const emitI64Load32S = emitI32Load;
pub const emitI64Load32U = emitI32Load;
pub const emitI64Store = emitI32Load;
pub const emitI64Store8 = emitI32Load;
pub const emitI64Store16 = emitI32Load;
pub const emitI64Store32 = emitI32Load;
pub const emitF32Load = emitI32Load;
pub const emitF64Load = emitI32Load;
pub const emitF32Store = emitI32Load;
pub const emitF64Store = emitI32Load;

/// Wasm 3.0 §5.4.7 memory64 (memory.load/store with i64 idx_type).
/// x86_64 mirror of arm64/op_memory.zig::emitMemOpI64. Differs from
/// emitMemOp's i32 fast path in TWO points:
///   1. Idx MOV uses 64-bit width (`encMovRR(.q, ...)`) instead of
///      32-bit (`encMovRR(.d, ...)` which zero-extends). The Wasm
///      3.0 spec defines memory64 addresses as full 64-bit; AMD64
///      MOV r64 copies all 64 bits.
///   2. Offset materialise: u64 offsets always go through MOVABS
///      RCX (10 bytes) + ADD RDX, RCX (3 bytes). The 32-bit
///      `ADD RDX, imm32` fast path is still used when offset fits
///      in i32::MAX (offsets 0..2^31-1) — that's a byte-identical
///      sub-case of i32 path encoding.
/// All other shapes (LEA RCX, [RDX+access_size]; CMP RCX, mem_limit;
/// JA trap; final MOV/MOVZX/MOVSX with [RAX+RDX] addressing) are
/// X-form already (LEA r64, CMP r64, base-idx 64-bit base) so they
/// stay identical to the i32 path. Per ADR-0111 D4.
fn emitMemOpI64(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const op = ins.op;
    const offset: u64 = ins.payload;
    const is_store = switch (op) {
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
    const is_fp = switch (op) {
        .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
        else => false,
    };
    // D-303 — atomic load/store trap on unaligned ea (spec exec step 8, BEFORE
    // bounds). The inline path omitted the check the interp has (memory.zig:202).
    const is_atomic = switch (op) {
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

    var idx_v: u32 = 0;
    var val_v: u32 = 0;
    if (is_store) {
        if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        val_v = ctx.pushed_vregs.pop().?;
        idx_v = ctx.pushed_vregs.pop().?;
    } else {
        if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        idx_v = ctx.pushed_vregs.pop().?;
    }
    const idx_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_v, 0);

    const access_size: i8 = switch (op) {
        .@"i32.load8_s", .@"i32.load8_u", .@"i32.store8", .@"i64.load8_s", .@"i64.load8_u", .@"i32.atomic.load8_u", .@"i64.atomic.load8_u", .@"i32.atomic.store8", .@"i64.atomic.store8", .@"i64.store8" => 1,
        .@"i32.load16_s", .@"i32.load16_u", .@"i32.store16", .@"i64.load16_s", .@"i64.load16_u", .@"i32.atomic.load16_u", .@"i64.atomic.load16_u", .@"i32.atomic.store16", .@"i64.atomic.store16", .@"i64.store16" => 2,
        .@"i32.load", .@"i32.atomic.load", .@"i32.store", .@"i32.atomic.store", .@"f32.load", .@"f32.store", .@"i64.load32_s", .@"i64.load32_u", .@"i64.atomic.load32_u", .@"i64.atomic.store32", .@"i64.store32" => 4,
        .@"i64.load", .@"i64.atomic.load", .@"i64.atomic.store", .@"i64.store", .@"f64.load", .@"f64.store" => 8,
        else => unreachable,
    };

    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    // i64 idx: full 64-bit MOV RDX, idx_r — divergence from i32 path's `.d` (zero-extend).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rdx, idx_r).slice());
    if (offset != 0) {
        if (offset <= 0x7FFFFFFF) {
            try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(.rdx, @intCast(offset)).slice());
        } else {
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(.rcx, offset).slice());
            try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, .rdx, .rcx).slice());
        }
    }
    // D-303 — atomic alignment trap BEFORE bounds (memory64 path). ea in RDX.
    if (is_atomic and access_size > 1) {
        try ctx.buf.appendSlice(ctx.allocator, inst.encTestRImm32(.d, .rdx, @as(u32, @intCast(access_size - 1))).slice());
        const al_fixup: u32 = @intCast(ctx.buf.items.len);
        try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ne, 0).slice()); // nonzero low bits = unaligned
        try ctx.unaligned_atomic_fixups.append(ctx.allocator, al_fixup);
    }
    // memory64 bounds: trap when `ea + size > mem_limit`. ADD (sets CF), not
    // LEA (no flags), so an `ea + size` overflowing 64-bit (ea near 2^64, the
    // spec memory_trap64 -1/-2 cases) traps via JC instead of wrapping to a
    // small in-bounds address the CMP would accept.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rcx, .rdx).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(.rcx, access_size).slice());
    const wrap_fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.b, 0).slice()); // CF = ea+size wrapped past 2^64
    try ctx.oob_fixups.append(ctx.allocator, wrap_fixup);
    try ctx.buf.appendSlice(ctx.allocator, inst.encCmpR64MemDisp32(.rcx, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.a, 0).slice());
    try ctx.oob_fixups.append(ctx.allocator, fixup_at);
    trace.writeBounds(ctx.func_idx, fixup_at);

    if (is_store) {
        if (is_fp) {
            const src_x = try gpr.xmmLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 0);
            const kind: inst.SseScalarKind = if (op == .@"f64.store") .f64 else .f32;
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovssMovsdMemBaseIdx(kind, true, src_x, .rax, .rdx).slice());
        } else {
            const src_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 1);
            const enc = switch (op) {
                .@"i32.store", .@"i32.atomic.store" => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
                .@"i32.store8", .@"i32.atomic.store8" => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
                .@"i32.store16", .@"i32.atomic.store16" => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store", .@"i64.atomic.store" => inst.encStoreR64MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store8", .@"i64.atomic.store8" => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store16", .@"i64.atomic.store16" => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store32", .@"i64.atomic.store32" => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
                else => unreachable,
            };
            try ctx.buf.appendSlice(ctx.allocator, enc.slice());
        }
    } else {
        const result_v = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result_v >= ctx.alloc.slots.len) return Error.SlotOverflow;
        if (is_fp) {
            const dst_x = try gpr.xmmDefSpilled(ctx.alloc, result_v, 0);
            const kind: inst.SseScalarKind = if (op == .@"f64.load") .f64 else .f32;
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovssMovsdMemBaseIdx(kind, false, dst_x, .rax, .rdx).slice());
            try gpr.xmmStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
        } else {
            const dst_r = try gpr.gprDefSpilled(ctx.alloc, result_v, 0);
            const enc = switch (op) {
                .@"i32.load", .@"i32.atomic.load" => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load8_s" => inst.encMovsxR32_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load8_u", .@"i32.atomic.load8_u" => inst.encMovzxR32_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load16_s" => inst.encMovsxR32_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load16_u", .@"i32.atomic.load16_u" => inst.encMovzxR32_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load", .@"i64.atomic.load" => inst.encMovR64FromBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load8_s" => inst.encMovsxR64_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load8_u", .@"i64.atomic.load8_u" => inst.encMovzxR64_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load16_s" => inst.encMovsxR64_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load16_u", .@"i64.atomic.load16_u" => inst.encMovzxR64_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load32_s" => inst.encMovsxdR64_32MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load32_u", .@"i64.atomic.load32_u" => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
                else => unreachable,
            };
            try ctx.buf.appendSlice(ctx.allocator, enc.slice());
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
        }
        try ctx.pushed_vregs.append(ctx.allocator, result_v);
    }
}

/// `(ctx, ins)` adapters for the
/// bulk-memory cohort (`memory.fill`, `memory.copy`,
/// `memory.init`). Three distinct adapters — fill/copy share
/// the same 7-arg legacy signature but init takes an extra
/// `dataidx` (= `ins.payload`). No aliases possible (each
/// dispatches to a distinct legacy helper body).
pub fn emitMemoryFillCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitMemoryFill(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oob_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        bulkIs64(ctx),
    );
}

pub fn emitMemoryCopyCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitMemoryCopy(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oob_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        bulkIs64(ctx),
    );
}

pub fn emitMemoryInitCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitMemoryInit(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.oob_fixups,
        ctx.spill_base_off,
        ctx.func_idx,
        @as(u32, @intCast(ins.payload)),
        bulkIs64(ctx),
    );
}

/// D-324 — is this module's (single, memidx-0) memory i64-indexed?
/// Comptime-pruned below v3.0; mirrors arm64 op_memory.zig bulkIs64.
inline fn bulkIs64(ctx: *ctx_mod.EmitCtx) bool {
    if (comptime @intFromEnum(build_options.wasm_level) >= @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) {
        return ctx.memory0_idx_type == .i64;
    }
    return false;
}

/// D-324 — bulk-op bounds check: trap when `base + n(R10) > mem_limit`.
/// i32 path keeps the historical MOV.d/ADD/CMP/JA (zero-extended u32
/// operands cannot wrap). i64 path's operands are full u64 where
/// `base + n` CAN wrap — subtraction scheme: `n > limit` → trap;
/// `base > limit - n` → trap. Clobbers RAX.
fn emitBulkBounds(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    oob_fixups: *std.ArrayList(u32),
    func_idx: u32,
    is64: bool,
    base: inst.Gpr,
) Error!void {
    if (is64) {
        try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.r10, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
            try oob_fixups.append(allocator, fixup_at);
            trace.writeBounds(func_idx, fixup_at);
        }
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
        try buf.appendSlice(allocator, inst.encSubRR(.q, .rax, .r10).slice());
        try buf.appendSlice(allocator, inst.encCmpRR(.q, base, .rax).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
            try oob_fixups.append(allocator, fixup_at);
            trace.writeBounds(func_idx, fixup_at);
        }
        return;
    }
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rax, base).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rax, .r10).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
    try oob_fixups.append(allocator, fixup_at);
    trace.writeBounds(func_idx, fixup_at);
}

// ============================================================
// Bulk-memory ops (Wasm 2.0 §4.4.7 — memory.fill / memory.copy)
//
// Stack effect: pops three i32 (n: top, val|src: middle, dst: bottom).
// No result pushed. Trap on out-of-bounds.
//
// Inline byte loop. Performance is Phase 8 work; correctness first.
//
// Register convention:
//   R15 = runtime_ptr_save (callee-saved). vm_base / mem_limit are
//     reloaded from `[R15 + offset]` at point of use.
//   R10/R11 = spill_stage_gprs (private to gprLoadSpilled; clobberable
//     between two such calls because each call only stages one value
//     and we capture into a private holder before the next load).
//   RAX = vm_base scratch. RCX = dst pointer / counter scratch.
//   RDX = src pointer (memory.copy) / val (memory.fill).
//
// The bounds-check trap stub (mem_limit overflow) is reached via a
// JA Jcc patched via `oob_fixups` exactly like emitMemOp.
// ============================================================

/// Wasm spec §4.4.7 (memory.fill) — pop n / val / dst (top→bottom);
/// set `n` bytes at `[dst, dst+n)` to `val & 0xFF`. Trap if
/// `dst+n > mem_size`.
///
/// x86_64 lowering (Intel SDM Vol 2):
///   ; capture: RDX = val (32-bit), RCX = dst (zero-ext u32 → u64),
///   ;          R10 = n (zero-ext, used as counter — repurposing the
///   ;          spill-stage reg AFTER all spill-loads complete).
///   ;
///   ; bounds check: ea = dst + n;
///   ;   MOV RAX, dst              ; RAX = dst (zero-ext)
///   ;   ADD RAX, n
///   ;   CMP RAX, [R15 + mem_limit_off]
///   ;   JA  trap_stub             ; oob_fixups append
///   ;
///   ; pointer setup:
///   ;   MOV RAX, [R15 + vm_base_off]
///   ;   ADD RCX, RAX              ; RCX = vm_base + dst
///   ;
///   ; loop:
///   ;   TEST R10, R10
///   ;   JZ   .end
///   ;   .loop:
///   ;     MOV  byte ptr [RCX], DL
///   ;     ADD  RCX, 1
///   ;     SUB  R10, 1                     (encoded as ADD imm32 -1)
///   ;     JNZ  .loop
///   ; .end:
pub fn emitMemoryFill(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    is64: bool,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const val_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: load each operand and capture into private holders.
    //   dst → RCX (32-bit MOV zero-extends to RCX; D-324: full
    //         64-bit MOV on memory64 — dst/n are u64 there),
    //   val → RDX (low byte goes to DL),
    //   n   → R10 (overwriting stage 0 since all spill-loads done
    //         after this point).
    const addr_w: inst.Width = if (is64) .q else .d;
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(addr_w, .rcx, dst_r).slice());
    const val_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, val_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(addr_w, .r10, n_r).slice());

    // Step B: bounds check — dst + n > mem_limit → trap (D-324:
    // overflow-safe subtraction scheme on memory64).
    try emitBulkBounds(allocator, buf, oob_fixups, func_idx, is64, .rcx);

    // Step C: convert dst to absolute pointer.
    //   MOV RAX, [R15 + vm_base_off]
    //   ADD RCX, RAX
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .rax).slice());

    // Step D: skip if n == 0.
    //   TEST R10, R10  ; sets ZF if n == 0
    //   JZ   .end      ; placeholder, patched after loop
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice()); // JE = JZ

    // Step E: loop body.
    //   .loop:
    //     MOV [RCX], DL                    (encStoreR8MemBaseIdx with idx=ZERO not avail; use disp=0 form)
    //     ADD RCX, 1
    //     ADD R10, -1                      (= SUB R10, 1)
    //     JNZ .loop
    //
    // For the byte-store at `[RCX]` (no index reg), we synthesise it
    // via the existing base+idx encoder by passing idx=RAX with
    // RAX zeroed beforehand. Cleaner: use the encoder whose only
    // form takes [base+idx]. We previously zero-extended dst via
    // `MOV RAX, [R15+vm_base_off]` + `ADD RCX, RAX`; RAX now holds
    // vm_base which is non-zero. So instead, use base=RCX, idx=ZeroIdxReg.
    // We don't have a "no-idx" byte-store helper; the cheapest fix is
    // to zero a register (e.g. RAX) here and use it as the SIB index.
    //
    // Alternative: introduce a new encoder for `MOV [base+disp8], r8`.
    // For now, zero RAX once before the loop and reuse in every
    // iteration:
    //   XOR EAX, EAX        ; RAX = 0 (zero-extends)
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());

    const loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.rdx, .rcx, .rax).slice()); // [RCX + 0] = DL
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice()); // SUB R10, 1 via ADD -1; sets ZF
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6; // JNZ rel32 = 6 bytes
        const disp: i32 = @as(i32, @intCast(loop_start)) - after_jnz;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }

    // Step F: patch the skip target.
    const end_byte: u32 = @intCast(buf.items.len);
    const skip_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_at)) + 6);
    const skip_word: [6]u8 = inst.encJccRel32(.e, skip_disp).slice()[0..6].*;
    @memcpy(buf.items[skip_at..][0..6], &skip_word);
}

/// Wasm spec §4.4.7 (memory.copy) — pop n / src / dst (top→bottom);
/// copy `n` bytes [src,src+n) → [dst,dst+n). memmove-style overlap
/// handling (backward when dst > src). Trap if either dst+n or
/// src+n > mem_size.
///
/// x86_64 lowering: same operand-capture discipline as memory.fill,
/// then a forward / backward branch on `dst <= src`.
///
/// Register layout after capture:
///   RCX = dst (zero-ext, then absolute pointer = vm_base + dst)
///   RDX = src (zero-ext, then absolute pointer)
///   R10 = n (counter)
///
/// Bounds check uses RAX as scratch; vm_base is loaded once (kept in
/// RAX) for both `ADD RCX, RAX` and `ADD RDX, RAX` after the bounds
/// pass.  Byte-load/store via `MOVZX` + `MOV [..]` through scratch.
pub fn emitMemoryCopy(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    is64: bool,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const src_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: capture operands into RCX, RDX, R10. D-324: full
    // 64-bit MOVs on memory64 (dst/src/n are u64 — the JIT compiles
    // only memidx 0, so the memories are uniform and it_min = i64).
    const addr_w: inst.Width = if (is64) .q else .d;
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(addr_w, .rcx, dst_r).slice());
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(addr_w, .rdx, src_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(addr_w, .r10, n_r).slice());

    // Step B1: bounds check dst + n. (D-324: overflow-safe on i64.)
    try emitBulkBounds(allocator, buf, oob_fixups, func_idx, is64, .rcx);

    // Step B2: bounds check src + n.
    try emitBulkBounds(allocator, buf, oob_fixups, func_idx, is64, .rdx);

    // Step C: convert dst / src to absolute pointers.
    //   MOV RAX, [R15 + vm_base_off]
    //   ADD RCX, RAX ; ADD RDX, RAX
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .rax).slice());

    // Step D: skip if n == 0.
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_zero_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    // Step E: direction switch — CMP RCX, RDX; JBE forward.
    //   JBE = unsigned ≤. dst <= src → forward copy is safe.
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rcx, .rdx).slice());
    const fwd_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());

    // ---- Backward path (copy high→low, 8 bytes/iter while n >= 8, then a
    // ≤7-byte tail). D-285: the prior byte loop made bulk copies slower than
    // the interpreter's vectorized copy. ----
    //   ADD RCX, R10 ; ADD RDX, R10   ; dst_p/src_p += n (point past end)
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .r10).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .r10).slice());
    // Zero scratch RAX for the [base+idx] encoders (idx held at 0; pointers
    // advance via ADD). RAX held vm_base, no longer needed.
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    // .bwd_word: while (n >= 8) { dst-=8; src-=8; *dst = *src; n-=8; }
    const bwd_word_top: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encCmpRImm8(.q, .r10, 8).slice());
    const bwd_word_exit_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.b, 0).slice()); // JB .bwd_tail (fixup)
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, -8).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, -8).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR64MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -8).slice());
    {
        const after_jmp: i32 = @as(i32, @intCast(buf.items.len)) + 5;
        try buf.appendSlice(allocator, inst.encJmpRel32(@as(i32, @intCast(bwd_word_top)) - after_jmp).slice());
    }
    // .bwd_tail: patch JB to here; copy ≤7 remaining bytes high→low.
    const bwd_tail_top: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(bwd_tail_top)) - (@as(i32, @intCast(bwd_word_exit_at)) + 6);
        @memcpy(buf.items[bwd_word_exit_at..][0..6], inst.encJccRel32(.b, disp).slice()[0..6]);
    }
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const bwd_tail_skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice()); // JZ .bwd_done (fixup)
    const bwd_byte_loop: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, -1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, -1).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, @as(i32, @intCast(bwd_byte_loop)) - after_jnz).slice());
    }
    // .bwd_done: JMP .end (patched after fwd path).
    const bwd_end_jmp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    // Patch the no-tail JZ to skip straight to .bwd_done (the JMP→.end).
    {
        const disp: i32 = @as(i32, @intCast(bwd_end_jmp_at)) - (@as(i32, @intCast(bwd_tail_skip_at)) + 6);
        @memcpy(buf.items[bwd_tail_skip_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
    }

    // ---- Forward path. Patch the JBE to here. ----
    const fwd_byte: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(fwd_byte)) - (@as(i32, @intCast(fwd_at)) + 6);
        @memcpy(buf.items[fwd_at..][0..6], inst.encJccRel32(.be, disp).slice()[0..6]);
    }
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    // .fwd_word: while (n >= 8) { *dst = *src; dst+=8; src+=8; n-=8; }
    const fwd_word_top: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encCmpRImm8(.q, .r10, 8).slice());
    const fwd_word_exit_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.b, 0).slice()); // JB .fwd_tail (fixup)
    try buf.appendSlice(allocator, inst.encMovR64FromBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR64MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, 8).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 8).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -8).slice());
    {
        const after_jmp: i32 = @as(i32, @intCast(buf.items.len)) + 5;
        try buf.appendSlice(allocator, inst.encJmpRel32(@as(i32, @intCast(fwd_word_top)) - after_jmp).slice());
    }
    // .fwd_tail: patch JB to here; copy ≤7 remaining bytes low→high.
    const fwd_tail_top: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(fwd_tail_top)) - (@as(i32, @intCast(fwd_word_exit_at)) + 6);
        @memcpy(buf.items[fwd_word_exit_at..][0..6], inst.encJccRel32(.b, disp).slice()[0..6]);
    }
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const fwd_tail_skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice()); // JZ .end (fixup)
    const fwd_byte_loop: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, @as(i32, @intCast(fwd_byte_loop)) - after_jnz).slice());
    }

    // .end: patch n==0 skip, bwd→end JMP, and the fwd no-tail JZ.
    const end_byte: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_zero_at)) + 6);
        @memcpy(buf.items[skip_zero_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
    }
    {
        const disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(bwd_end_jmp_at)) + 5);
        @memcpy(buf.items[bwd_end_jmp_at..][0..5], inst.encJmpRel32(disp).slice()[0..5]);
    }
    {
        const disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(fwd_tail_skip_at)) + 6);
        @memcpy(buf.items[fwd_tail_skip_at..][0..6], inst.encJccRel32(.e, disp).slice()[0..6]);
    }
}

/// Wasm spec §4.5.3.10 (memory.init dataidx) — copy `n` bytes from
/// data segment `dataidx` at offset `src` into linear memory at
/// offset `dst`. Traps OutOfBoundsMemoryAccess on `src+n > seg.len`
/// (with `len = 0` when dropped) or `dst+n > mem_limit`.
///
/// Register layout (caller-saved scratch only):
///   RCX = dst (then dst_p = vm_base + dst)
///   RDX = src (then src_p = seg.ptr + src)
///   R10 = n   (counter)
///   R9  = seg.ptr (preserved across bounds checks)
///   R8  = seg.len (zeroed if dropped)
///   RAX, R11, RDI = ad-hoc scratch (RDI repurposed since the
///                   JIT body never re-uses arg0 mid-function)
pub fn emitMemoryInit(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    oob_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
    dataidx: u32,
    is64: bool,
) Error!void {
    // Encoding-budget guard: 16-byte stride means disp32 always
    // suffices for realistic segment counts. Match the arm64 path's
    // 2048 cap for cross-arch consistency (validator already rejects
    // out-of-range dataidx).
    if (dataidx >= 2048) return Error.UnsupportedOp;

    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const src_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: capture pop'd operands into RCX, RDX, R10 (private
    // holders that survive subsequent spill-aware loads). D-324: dst
    // is the TARGET memory's address — full 64-bit MOV on memory64;
    // src + n stay i32 (data-segment offsets).
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(if (is64) .q else .d, .rcx, dst_r).slice());
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, src_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .r10, n_r).slice());

    // Step B: read seg.ptr (R9) + seg.len (R8) from data_segments_ptr.
    //   MOV RAX, [R15 + data_segments_ptr_off]    ; seg table base
    //   MOV R9,  [RAX + idx*16 + 0]                ; seg.ptr
    //   MOV R8,  [RAX + idx*16 + 8]                ; seg.len
    const seg_byte_off: i32 = @intCast(@as(u64, dataidx) * 16);
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.data_segments_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r9, .rax, seg_byte_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r8, .rax, seg_byte_off + 8).slice());

    // Step C: dropped flag override. dropped != 0 → seg.len = 0.
    //   MOV R11, [R15 + data_dropped_ptr_off]
    //   ADD R11, idx                               ; &dropped[idx]
    //   XOR EDI, EDI                                ; zero idx (one-shot)
    //   MOVZX R11d, byte [R11 + RDI]                ; R11 = dropped (R11 clobbered)
    //   XOR EAX, EAX                                ; zero source for CMOVNE
    //   TEST R11, R11                               ; ZF=1 when NOT dropped
    //   CMOVNE R8, RAX                              ; if dropped → R8 = 0
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r11, abi.runtime_ptr_save_gpr, jit_abi.data_dropped_ptr_off).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r11, @intCast(dataidx)).slice());
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rdi, .rdi).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.r11, .r11, .rdi).slice());
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r11, .r11).slice());
    try buf.appendSlice(allocator, inst.encCmovccRR(.q, .ne, .r8, .rax).slice());

    // Step D1: bounds — src + n > seg.len → trap.
    //   MOV RAX, RDX
    //   ADD RAX, R10
    //   CMP RAX, R8
    //   JA trap
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rax, .r10).slice());
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rax, .r8).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try oob_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // Step D2: bounds — dst + n > mem_limit → trap. (D-324:
    // overflow-safe subtraction scheme on memory64.)
    try emitBulkBounds(allocator, buf, oob_fixups, func_idx, is64, .rcx);

    // Step E: if n == 0, skip the copy.
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_zero_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    // Step F: compute absolute pointers.
    //   MOV RAX, [R15 + vm_base_off]
    //   ADD RCX, RAX                                ; dst_p = vm_base + dst
    //   ADD RDX, R9                                 ; src_p = seg.ptr + src
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .r9).slice());

    // Step G: forward byte loop. Data segments live in host-owned
    // storage; linear memory is disjoint, so no overlap concern
    // (unlike memory.copy).
    //   XOR EAX, EAX                                ; zero idx
    // .loop:
    //   MOVZX R11d, byte [RDX + RAX]
    //   MOV   byte [RCX + RAX], R11B
    //   ADD   RCX, 1
    //   ADD   RDX, 1
    //   ADD   R10, -1
    //   JNE   .loop
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    const loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        const disp: i32 = @as(i32, @intCast(loop_start)) - after_jnz;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }

    // .end: patch the n==0 skip JE.
    const end_byte: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_zero_at)) + 6);
        const word: [6]u8 = inst.encJccRel32(.e, disp).slice()[0..6].*;
        @memcpy(buf.items[skip_zero_at..][0..6], &word);
    }
}

/// Wasm threads (ADR-0168) `tNN.atomic.rmw*` — callout through
/// `JitRuntime.atomic_rmw_fn`. C-ABI args: arg0 = rt (R15 alias),
/// arg1 = ea (addr + offset), arg2 = operand (full 64-bit; the helper
/// truncates to width), arg3 = opcode. Returns the OLD value in RAX;
/// on unaligned/oob the helper sets trap_flag (epilogue raises). The
/// marshal writes the argument registers in order; the operand fence
/// (`abi.op_regs`, ADR-0077) keeps the operand/addr vregs out of them. R11 (caller-
/// saved, non-arg both ABIs) stages the offset. vm_base/mem_limit are
/// re-read from [R15+off] on every memory op, so no post-call reload.
pub fn emitAtomicRmw(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const m = jit_abi.rmwMapOf(ins.op) orelse return Error.UnsupportedOp;
    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const operand_v = ctx.pushed_vregs.pop().?;
    const addr_v = ctx.pushed_vregs.pop().?;
    const ag = abi.current.arg_gprs;
    const arg1 = ag[1]; // ea
    const arg2 = ag[2]; // operand
    const arg3 = ag[3]; // opcode
    // operand → arg2 (full 64-bit; helper truncates). Stage 0.
    const op_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, operand_v, 0);
    if (op_src != arg2) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, arg2, op_src).slice());
    // ea → arg1 = addr (32-bit MOV zero-extends) + offset. Stage 1.
    const addr_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_v, 1);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, arg1, addr_src).slice());
    const offset_imm = ins.payload;
    if (offset_imm != 0) {
        // R11 free here (addr already copied to arg1); non-arg scratch.
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(.r11, @as(u64, offset_imm)).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, arg1, .r11).slice());
    }
    // arg3 = opcode (imm32).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(arg3, m.code).slice());
    // arg0 = rt.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
    // RAX = atomic_rmw_fn; CALL through it (Win64 shadow-space gated).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.atomic_rmw_fn_off).slice());
    try op_call.emitShadowAlloc(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.rax).slice());
    try op_call.emitShadowFree(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    // Capture old value (RAX for i64, EAX zero-ext for i32) → result vreg.
    const result_v = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_v >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, result_v, 0);
    if (m.res64) {
        if (dst_r != abi.return_gpr) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, dst_r, abi.return_gpr).slice());
    } else {
        // i32: 32-bit MOV zero-extends bits 63:32 (canonical i32 form).
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, dst_r, abi.return_gpr).slice());
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_v);
}

/// Wasm threads (ADR-0168) `tNN.atomic.rmw*.cmpxchg*` — callout through
/// `JitRuntime.atomic_cmpxchg_fns[width_log2]`. C-ABI args: arg0 = rt,
/// arg1 = ea, arg2 = expected (full 64-bit; helper truncates), arg3 =
/// replacement. Returns OLD in RAX; helper sets trap_flag on
/// unaligned/oob. Mirror of emitAtomicRmw (3 operands + per-width slot).
pub fn emitAtomicCmpxchg(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    const m = jit_abi.cmpxchgMapOf(ins.op) orelse return Error.UnsupportedOp;
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const repl_v = ctx.pushed_vregs.pop().?;
    const exp_v = ctx.pushed_vregs.pop().?;
    const addr_v = ctx.pushed_vregs.pop().?;
    const ag = abi.current.arg_gprs;
    const arg1 = ag[1]; // ea
    const arg2 = ag[2]; // expected
    const arg3 = ag[3]; // replacement
    // arg3 = replacement (full 64-bit). Stage 0.
    const r_repl = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, repl_v, 0);
    if (r_repl != arg3) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, arg3, r_repl).slice());
    // arg2 = expected (full 64-bit). Stage 1.
    const r_exp = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, exp_v, 1);
    if (r_exp != arg2) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, arg2, r_exp).slice());
    // arg1 = ea = addr (32-bit MOV zero-extends) + offset. Stage 0 reused.
    const r_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_v, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, arg1, r_addr).slice());
    const offset_imm = ins.payload;
    if (offset_imm != 0) {
        // R11 free here (operands already copied to arg regs); non-arg scratch.
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(.r11, @as(u64, offset_imm)).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, arg1, .r11).slice());
    }
    // arg0 = rt.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
    // RAX = atomic_cmpxchg_fns[width_log2]; CALL through it.
    const fn_off: i32 = @intCast(jit_abi.atomic_cmpxchg_fns_off + @as(u32, m.wlog2) * 8);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, fn_off).slice());
    try op_call.emitShadowAlloc(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.rax).slice());
    try op_call.emitShadowFree(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    // Capture old value (RAX for i64, EAX zero-ext for i32) → result vreg.
    const result_v = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_v >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, result_v, 0);
    if (m.res64) {
        if (dst_r != abi.return_gpr) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, dst_r, abi.return_gpr).slice());
    } else {
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, dst_r, abi.return_gpr).slice());
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_v);
}

/// Capture EAX (i32 callout result) → `result` vreg (zero-extended).
fn captureEaxI32(ctx: *ctx_mod.EmitCtx) Error!void {
    const result_v = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_v >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, result_v, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, dst_r, abi.return_gpr).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_v);
}

/// `ea = addr (32-bit MOV zero-extends) + ins.payload` → `arg1`. R11
/// (caller-saved, non-arg) stages a >0 offset.
fn eaIntoArg1(ctx: *ctx_mod.EmitCtx, addr_v: u32, stage: u2, arg1: inst.Gpr, offset_imm: u64) Error!void {
    const addr_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_v, stage);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, arg1, addr_src).slice());
    if (offset_imm != 0) {
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(.r11, @as(u64, offset_imm)).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, arg1, .r11).slice());
    }
}

/// Wasm threads (ADR-0168) `memory.atomic.notify` — callout through
/// `JitRuntime.atomic_notify_fn`. arg0 = rt, arg1 = ea (count popped +
/// dropped). Returns 0 in EAX; helper sets trap_flag on unaligned/oob.
pub fn emitAtomicNotify(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    _ = ctx.pushed_vregs.pop().?; // count (unused)
    const addr_v = ctx.pushed_vregs.pop().?;
    const arg1 = abi.current.arg_gprs[1];
    try eaIntoArg1(ctx, addr_v, 0, arg1, ins.payload);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.atomic_notify_fn_off).slice());
    try op_call.emitShadowAlloc(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.rax).slice());
    try op_call.emitShadowFree(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try captureEaxI32(ctx);
}

/// Wasm threads (ADR-0168) `memory.atomic.wait{32,64}` — callout through
/// `JitRuntime.atomic_wait_fns[idx]`. arg0 = rt, arg1 = ea, arg2 =
/// expected (timeout popped + dropped). Returns status in EAX; helper
/// sets trap_flag on unaligned/oob/non-shared.
pub fn emitAtomicWait(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    _ = ctx.pushed_vregs.pop().?; // timeout (unused)
    const exp_v = ctx.pushed_vregs.pop().?;
    const addr_v = ctx.pushed_vregs.pop().?;
    const arg1 = abi.current.arg_gprs[1];
    const arg2 = abi.current.arg_gprs[2];
    // arg2 = expected (full 64-bit; helper truncates). Stage 0.
    const r_exp = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, exp_v, 0);
    if (r_exp != arg2) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, arg2, r_exp).slice());
    try eaIntoArg1(ctx, addr_v, 1, arg1, ins.payload);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
    const fn_off: i32 = @intCast(jit_abi.atomic_wait_fns_off + jit_abi.waitIdxOf(ins.op) * 8);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, fn_off).slice());
    try op_call.emitShadowAlloc(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.rax).slice());
    try op_call.emitShadowFree(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try captureEaxI32(ctx);
}
