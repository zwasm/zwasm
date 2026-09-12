//! arm64 codegen setup-phase helpers — frame outgoing-region +
//! local-layout computation.
//!
//! Mirror of `x86_64/emit_setup.zig` (ADR-0081 Phase 1 for the
//! arm64 side). Pure top-level helpers extracted from emit.zig
//! to keep that file's `compile()` driver focused on the
//! dispatch loop.
//!
//! The helpers here are stateless / pure-function — they have
//! no dependency on compile()'s inner scope. emit.zig re-imports
//! them and aliases the symbols so call-sites inside compile()
//! body remain unchanged.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const builtin = @import("builtin");

const zir = @import("../../../ir/zir.zig");
const ctx_mod = @import("ctx.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Error = ctx_mod.Error;

/// Pre-scan the function body for the worst-case
/// outgoing-args region size (caller-side stack-arg lowering per
/// AAPCS64 §6.4.2). For each `call N` / `call_indirect type_idx`
/// instruction, count the args that overflow the X1..X7 (int) and
/// V0..V7 (fp) register pools and sum the per-slot 8-byte
/// allocations; track the max across all calls. This region sits
/// at the bottom of the caller's frame (`[SP, #0]` upward), so
/// callee can read overflows at `[X29, #16 + 8*K]`.
pub fn computeOutgoingMaxBytes(
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
    num_imports: u32,
) u32 {
    var max_bytes: u32 = 0;
    for (func.instrs.items) |ins| {
        const sig: ?zir.FuncType = switch (ins.op) {
            .call => if (ins.payload < func_sigs.len) func_sigs[ins.payload] else null,
            .call_indirect => if (ins.payload < module_types.len) module_types[ins.payload] else null,
            // `call_ref` marshals through the same outgoing region (`emitCallRef`);
            // left out, a function whose only call is a `call_ref` reserved no
            // region and its overflow words landed on its locals — and under
            // Win64 the per-call shadow SUB then moved them out from under the
            // callee (ADR-0228, found by the #390 funcref test on the Windows leg).
            .call_ref => if (ins.payload < module_types.len) module_types[ins.payload] else null,
            // Mirror of the x86_64 note: a CROSS-MODULE `return_call` keeps
            // its frame, so its overflow words are reserved here; the
            // frame-consuming forms decline instead (#424).
            .return_call => if (ins.payload < num_imports and ins.payload < func_sigs.len) func_sigs[ins.payload] else null,
            else => null,
        };
        const callee_sig = sig orelse continue;
        // X0 = `*JitRuntime` per ADR-0017, so user int args use
        // X1..X7 (7 slots). FP args use V0..V7 (8 slots).
        // Apple arm64 packs stack args at natural size; standard
        // AAPCS64 uses uniform 8-byte stride. Mirror of the
        // prologue's `apple_natural_packing` cursor.
        const apple_natural_packing: bool = builtin.target.os.tag == .macos or
            builtin.target.os.tag == .ios or
            builtin.target.os.tag == .watchos or
            builtin.target.os.tag == .tvos;
        var int_slot: u32 = 1; // X1..X7
        var fp_slot: u32 = 0; // V0..V7
        var stack_byte_off: u32 = 0;
        for (callee_sig.params) |p| {
            switch (p) {
                .i32 => {
                    if (int_slot >= 8) {
                        const sz: u32 = if (apple_natural_packing) 4 else 8;
                        stack_byte_off = (stack_byte_off + sz - 1) & ~(sz - 1);
                        stack_byte_off += sz;
                    } else int_slot += 1;
                },
                // i31ref u32 GcRef shares the
                // 8-byte gpr-class slot with other reftypes.
                .i64, .ref => {
                    if (int_slot >= 8) {
                        stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                        stack_byte_off += 8;
                    } else int_slot += 1;
                },
                .f32 => {
                    if (fp_slot >= 8) {
                        const sz: u32 = if (apple_natural_packing) 4 else 8;
                        stack_byte_off = (stack_byte_off + sz - 1) & ~(sz - 1);
                        stack_byte_off += sz;
                    } else fp_slot += 1;
                },
                .f64 => {
                    if (fp_slot >= 8) {
                        stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                        stack_byte_off += 8;
                    } else fp_slot += 1;
                },
                .v128 => {
                    if (fp_slot >= 8) {
                        stack_byte_off = (stack_byte_off + 15) & ~@as(u32, 15);
                        stack_byte_off += 16;
                    } else fp_slot += 1;
                },
            }
        }
        // Round up the outgoing-args region to 16-byte boundary to
        // preserve SP alignment (AAPCS64 §6.2.3 / Apple ABI both
        // require 16-byte aligned SP at BL).
        const overflow_bytes: u32 = (stack_byte_off + 15) & ~@as(u32, 15);
        // ADR-0069 §Phase 2: when callee returns
        // MEMORY-class (struct > 16 B per AAPCS64 §6.8.2; v2
        // trigger = `results.len > 2`), reserve a per-result
        // 8-byte buffer slot at the top of THIS call's outgoing-
        // args footprint. Buffer follows the overflow-args block:
        // `[SP, #0..overflow_bytes-1]` overflow + `[SP, #overflow_
        // bytes..overflow_bytes + n_results*8 - 1]` return buf.
        const return_buf_bytes: u32 = if (callee_sig.results.len > 2)
            @as(u32, @intCast(callee_sig.results.len)) * 8
        else
            0;
        const bytes: u32 = overflow_bytes + return_buf_bytes;
        if (bytes > max_bytes) max_bytes = bytes;
    }
    return max_bytes;
}

/// Per-function local-frame layout. Wasm locals
/// (params + declared) are split by type into two regions:
/// scalars (i32 / i64 / f32 / f64 / refs) at 8-byte stride, then
/// v128 at 16-byte stride. The split keeps the per-local offset
/// formula pure (a single offset table consulted by index) AND
/// avoids the per-slot 16-byte waste of a uniform v128-stride
/// frame.
///
/// `offsets[i]` is the byte offset within the locals zone
/// (relative to `local_base_off`) for Wasm-local-index `i`.
/// `total_bytes` includes any tail padding for v128 alignment.
/// The callee zero-initialises declared locals (Wasm spec
/// §4.5.3.1) using offsets[N..total_locals].
pub const LocalLayout = struct {
    offsets: []u32,
    total_bytes: u32,
    v128_count: u32,

    pub fn deinit(self: *LocalLayout, allocator: Allocator) void {
        if (self.offsets.len != 0) allocator.free(self.offsets);
    }
};

/// Compute `LocalLayout` from `func.sig.params` + `func.locals`
/// (+ synthetic_locals via `func.totalLocalCount`). Two-pass:
/// pass 1 counts scalars vs v128; pass 2 assigns offsets in
/// declaration order — scalars consume the low region (8-byte
/// stride), v128 the high region (16-byte stride, base rounded
/// up to 16 from the scalar tail). Caller frees `offsets` via
/// `LocalLayout.deinit`.
pub fn computeLocalLayout(allocator: Allocator, func: *const ZirFunc) Error!LocalLayout {
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    const total_locals: u32 = num_params + num_locals;
    if (total_locals == 0) {
        return .{ .offsets = &.{}, .total_bytes = 0, .v128_count = 0 };
    }
    const offsets = try allocator.alloc(u32, total_locals);
    errdefer allocator.free(offsets);

    var scalar_count: u32 = 0;
    var v128_count: u32 = 0;
    var i: u32 = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) v128_count += 1 else scalar_count += 1;
    }

    const scalar_bytes: u32 = scalar_count * 8;
    // v128 region must be 16-byte aligned within the locals zone.
    // Caller (compile()) rounds `local_base_off` up to 16 when
    // v128_count > 0 so that `local_base_off + v128_region_off`
    // is a multiple of 16 in the SP-relative absolute frame.
    const v128_region_off: u32 = if (v128_count == 0) scalar_bytes else (scalar_bytes + 15) & ~@as(u32, 15);
    const total_bytes: u32 = v128_region_off + v128_count * 16;

    var scalar_within: u32 = 0;
    var v128_within: u32 = 0;
    i = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) {
            offsets[i] = v128_region_off + v128_within * 16;
            v128_within += 1;
        } else {
            offsets[i] = scalar_within * 8;
            scalar_within += 1;
        }
    }

    return .{ .offsets = offsets, .total_bytes = total_bytes, .v128_count = v128_count };
}
