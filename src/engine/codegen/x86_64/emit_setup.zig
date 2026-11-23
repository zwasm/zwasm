//! x86_64 codegen setup-phase helpers — frame shape + outgoing-region
//! + local-layout computation.
//!
//! Phase 1 of the emit.zig refactor per ADR-0081: pure top-level
//! helpers extracted from emit.zig to keep that file's `compile()`
//! driver focused on the dispatch loop. Phase 2 (compile() body
//! extraction) is deferred to ADR-0082+ when concrete pressure
//! surfaces.
//!
//! The helpers here are stateless / pure-function — they have no
//! dependency on compile()'s inner scope. emit.zig re-imports them
//! and aliases the symbols so call-sites inside compile() body
//! remain unchanged.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");

const zir = @import("../../../ir/zir.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Error = types.Error;

/// Mirror of `arm64/emit.zig:computeOutgoingMaxBytes`.
/// Pre-scan the function body for the worst-case outgoing-args
/// region size at the bottom of the caller's frame (`[RSP, #0]`
/// upward). For each `call N` / `call_indirect type_idx` /
/// `call_ref` / cross-module `return_call`, take the max over its
/// calls of where the stack arguments end plus the MEMORY-class
/// return buffer. `abi.callStackLayout` owns the per-Cc layout, so
/// this reserves exactly what `op_call.marshalCallArgs` writes —
/// including a `v128` stack argument, which earlier counts left
/// past the region.
pub fn computeOutgoingMaxBytes(
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
    num_imports: u32,
) u32 {
    var max_bytes: u32 = 0;
    for (func.instrs.items) |ins| {
        // D-248: GC ops issue an INTRA-OP CALL to a
        // `callconv(.c)` runtime helper (jitGcAlloc & friends) — NOT
        // a `.call` / `.call_indirect` ZIR op — so they are invisible
        // to the sig-scan below. On Win64 the callee is entitled to a
        // 32-byte shadow space, and the ≥5-arg helpers (array.copy /
        // fill / init_data / init_elem / new_data / new_elem) spill
        // args 5/6 to `[RSP + 32 + 8*k]` above it. Reserve that region
        // here so the spill / shadow lands inside the frame, not on
        // the pushed return address (SEGV otherwise). SysV reserves 0
        // — it has no shadow space and 6 GPR arg slots fit every GC
        // helper, so this contributes nothing (byte-identical prologue).
        if (abi.current_cc == .win64) {
            const gc_bytes: u32 = switch (ins.op) {
                // ≥5 integer args → 32 shadow + 2×8 spill, 16-aligned = 48.
                .@"array.copy",
                .@"array.fill",
                .@"array.init_data",
                .@"array.init_elem",
                .@"array.new_data",
                .@"array.new_elem",
                => 48,
                // ≤4-arg GC helpers: shadow space only.
                .@"struct.new",
                .@"struct.new_default",
                .@"array.new",
                .@"array.new_default",
                .@"array.new_fixed",
                .@"ref.test",
                .@"ref.test_null",
                .@"ref.cast",
                .@"ref.cast_null",
                .br_on_cast,
                .br_on_cast_fail,
                => abi.current.shadow_space_bytes,
                else => 0,
            };
            if (gc_bytes > max_bytes) max_bytes = gc_bytes;
        }
        const sig: ?zir.FuncType = switch (ins.op) {
            .call => if (ins.payload < func_sigs.len) func_sigs[ins.payload] else null,
            .call_indirect => if (ins.payload < module_types.len) module_types[ins.payload] else null,
            // `call_ref` marshals through the same outgoing region (`emitCallRef`);
            // left out, a function whose only call is a `call_ref` reserved no
            // region and its overflow words landed on its locals — and under
            // Win64 the per-call shadow SUB then moved them out from under the
            // callee (ADR-0228, found by the #390 funcref test on the Windows leg).
            .call_ref => if (ins.payload < module_types.len) module_types[ins.payload] else null,
            // A CROSS-MODULE `return_call` keeps its frame (call-and-return
            // through the ADR-0066 thunk), so its overflow words must be
            // reserved here; left out, they landed on this function's spill
            // slots and the callee read its 8th and later integer args from
            // the wrong place (#424, `cross_module_abi.c`'s `tail` case). The
            // three FRAME-CONSUMING forms stay absent: their teardown releases
            // whatever is reserved, so they decline (`op_tail_call`).
            .return_call => if (ins.payload < num_imports and ins.payload < func_sigs.len) func_sigs[ins.payload] else null,
            else => null,
        };
        const callee_sig = sig orelse continue;
        // ADR-0069 §Phase 2: a MEMORY-class callee (`results.len > 2`) reserves
        // an N×8 B return buffer above its stack arguments; the caller LEAs the
        // hidden pointer there before CALL (ADR-0026 Convention Swap).
        const args_end = abi.callStackLayout(abi.current_cc, callee_sig).return_buffer_off;
        const return_buf_bytes: u32 = if (callee_sig.results.len > 2)
            @as(u32, @intCast(callee_sig.results.len)) * 8
        else
            0;
        const bytes: u32 = args_end + return_buf_bytes;
        if (bytes > max_bytes) max_bytes = bytes;
    }
    return max_bytes;
}

/// RBP-relative disp formula for scalar locals.
/// Caller uses the `(idx+1)*8` shape directly when no v128 mix is
/// possible (e.g. test fixtures + scalar emit_test_local sites that
/// hard-code the `(idx+1)*8` shape). v128-aware emit paths must
/// route through `localDispLayout(layout, idx, ...)` so the
/// per-type stride is honoured.
pub fn localDisp(idx: u32, total_locals: u32, uses_runtime_ptr: bool) Error!i32 {
    if (idx >= total_locals) {
        dbg.print("codegen", "x86_64/emit: UnsupportedOp[localDisp-idx>=total_locals] (idx={d}, total={d})\n", .{ idx, total_locals });
        return Error.UnsupportedOp;
    }
    const base_off: i32 = if (uses_runtime_ptr) -8 else 0;
    return base_off - @as(i32, @intCast((idx + 1) * 8));
}

/// Per-function local-frame layout. Mirror of
/// `arm64/emit.zig:LocalLayout` (group-by-type strategy C):
/// scalars at 8-byte stride in the low part of the locals zone,
/// v128 at 16-byte stride in the high part. RBP-relative
/// negative-disp coordinate space (frame grows DOWN from RBP).
///
/// `disps[i]` is the RBP-relative negative byte offset for Wasm-
/// local-index `i` (i.e. the value passed to `MOV [RBP+disp]`).
/// `total_bytes` is the locals-zone size in bytes (used by frame
/// sizing). The v128-region disp is the most-negative end of
/// each v128 slot, 16-byte aligned by construction (the scalar
/// region's tail rounds up to 16 before v128 slots start).
pub const LocalLayout = struct {
    disps: []i32,
    total_bytes: u32,
    v128_count: u32,

    pub fn deinit(self: *LocalLayout, allocator: Allocator) void {
        if (self.disps.len != 0) allocator.free(self.disps);
    }
};

/// Compute `LocalLayout` per `func.sig.params` + `func.locals` (+
/// synthetic) in declaration order. Two passes: count scalars vs
/// v128, then assign disps. Caller passes the `base_off_for_locals`
/// (= -8 if uses_runtime_ptr else 0) so the helper produces the
/// final RBP-relative disps directly.
pub fn computeLocalLayout(allocator: Allocator, func: *const ZirFunc, base_off_for_locals: i32) Error!LocalLayout {
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    const total_locals: u32 = num_params + num_locals;
    if (total_locals == 0) {
        return .{ .disps = &.{}, .total_bytes = 0, .v128_count = 0 };
    }
    const disps = try allocator.alloc(i32, total_locals);
    errdefer allocator.free(disps);

    var scalar_count: u32 = 0;
    var v128_count: u32 = 0;
    var i: u32 = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) v128_count += 1 else scalar_count += 1;
    }

    const scalar_bytes: u32 = scalar_count * 8;
    // Scalars sit at the low (closer to RBP) end. v128 region
    // starts at -(scalar_bytes + 16-aligned padding). Since the
    // base RBP-relative origin (`base_off_for_locals`) is either
    // 0 or -8 (uses_runtime_ptr), the v128 region's most-positive
    // disp is `base_off_for_locals - aligned(scalar_bytes, 16)`.
    const v128_region_off: u32 = if (v128_count == 0) scalar_bytes else (scalar_bytes + 15) & ~@as(u32, 15);
    const total_bytes: u32 = v128_region_off + v128_count * 16;

    var scalar_within: u32 = 0;
    var v128_within: u32 = 0;
    i = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) {
            // Each v128 occupies 16 bytes; disps point to the
            // LOW byte (= the most-negative disp, since
            // `MOVUPS [RBP+disp]` writes 16 bytes upward from
            // there).
            disps[i] = base_off_for_locals - @as(i32, @intCast(v128_region_off + (v128_within + 1) * 16));
            v128_within += 1;
        } else {
            disps[i] = base_off_for_locals - @as(i32, @intCast((scalar_within + 1) * 8));
            scalar_within += 1;
        }
    }

    return .{ .disps = disps, .total_bytes = total_bytes, .v128_count = v128_count };
}
