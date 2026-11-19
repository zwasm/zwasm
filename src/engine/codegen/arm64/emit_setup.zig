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

const zir = @import("../../../ir/zir.zig");
const abi = @import("abi.zig");
const ctx_mod = @import("ctx.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Error = ctx_mod.Error;

/// Pre-scan the function body for the worst-case outgoing region (caller-side
/// stack-arg lowering per AAPCS64 §6.4.2): the max over its calls of
/// `abi.callOutgoingBytes`, which owns the per-call size. The region sits at
/// the bottom of the caller's frame (`[SP, #0]` upward), so the callee reads
/// its stack arguments from `[X29, #16]` upward.
pub fn computeOutgoingMaxBytes(
    packing: abi.StackArgPacking,
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
        const bytes: u32 = abi.callOutgoingBytes(packing, callee_sig);
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
