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
/// upward). For each `call N` / `call_indirect type_idx`, count
/// the args that overflow the per-Cc register pools and sum the
/// per-slot 8-byte allocations; track the max across all calls.
///
/// **SysV** (System V x86_64 §3.2.3): int args use arg_gprs[1..6]
/// (5 user slots; arg_gprs[0] = RDI = runtime_ptr per ADR-0026).
/// FP args use arg_xmms[0..7] (8 user slots, independent counter).
/// Per-call overflow = `(max(0, n_int - 5) + max(0, n_fp - 8)) * 8`.
///
/// **Win64** (Microsoft x64): int and FP share slots arg_gprs[1..3]
/// (3 user slots; arg_gprs[0] = RCX = runtime_ptr). Total user
/// args > 3 ⇒ overflow. The shared shadow-space-prefixed region
/// places overflow at `[RSP + 32 + 8*K]`, so the outgoing region
/// must include the 32-byte shadow when any call exists. Per-call
/// outgoing = `32 + max(0, n_int + n_fp - 3) * 8`.
pub fn computeOutgoingMaxBytes(
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
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
            else => null,
        };
        const callee_sig = sig orelse continue;
        var n_int: u32 = 0;
        var n_fp: u32 = 0;
        var n_v128: u32 = 0;
        for (callee_sig.params) |p| {
            switch (p) {
                .i32, .i64, .ref => n_int += 1,
                .f32, .f64 => n_fp += 1,
                // Win64 v128 is a hidden-pointer
                // arg — consumes one int-arg-reg slot for the
                // pointer; on SysV it's an XMM-reg / stack-eightbyte
                // arg (already excluded from n_int / n_fp here).
                .v128 => n_v128 += 1,
            }
        }
        // SysV: v128 fp-class consumes 2 eightbytes
        // on stack per overflowed arg (SSE class).
        // Win64: v128 = hidden ptr in int-arg slot + 16-byte scratch
        // in caller's outgoing region (Microsoft x64 §Param passing).
        const bytes: u32 = switch (abi.current_cc) {
            .sysv => blk: {
                // ADR-0026 2026-05-18 Convention Swap: MEMORY-class
                // callee receives &buffer in RDI (slot 0) + rt in
                // RSI (slot 1), shrinking the user int-reg pool to
                // 4 slots (RDX/RCX/R8/R9). Non-MEMORY callee
                // retains 5 user int regs (RSI..R9).
                const callee_is_memory_class = callee_sig.results.len > 2;
                const n_user_int_regs: u32 = if (callee_is_memory_class) 4 else 5;
                const n_int_overflow: u32 = if (n_int > n_user_int_regs) n_int - n_user_int_regs else 0;
                const n_fp_total = n_fp + 2 * n_v128;
                const n_fp_overflow: u32 = if (n_fp_total > 8) n_fp_total - 8 else 0;
                const overflow_bytes: u32 = (n_int_overflow + n_fp_overflow) * 8;
                // MEMORY-class return reserves an N×8 B buffer slot
                // at the top of THIS call's outgoing-args footprint.
                // The caller LEAs RDI = &buffer immediately before
                // CALL (Convention Swap above); the callee captures
                // RDI into its own frame slot. Mirrors arm64's
                // `indirect_result_slot_bytes` accounting. Win64
                // MEMORY-class deferred.
                const return_buf_bytes: u32 = if (callee_is_memory_class)
                    @as(u32, @intCast(callee_sig.results.len)) * 8
                else
                    0;
                break :blk overflow_bytes + return_buf_bytes;
            },
            .win64 => blk: {
                // D-165 close (2026-05-23): Win64 internal JIT-to-JIT
                // MEMORY-class return ABI mirrors SysV §3.2.3 with
                // RCX-as-hidden-ptr / RDX-as-rt. Callee with > 2
                // results consumes 2 int-arg slots (RCX=&buffer,
                // RDX=rt) before user ints → 2 user int regs
                // (R8/R9). Non-MEMORY callees keep slot 0=RCX=rt
                // and have 3 user int regs (RDX/R8/R9).
                const callee_is_memory_class = callee_sig.results.len > 2;
                const n_int_w = n_int + n_v128;
                const n_total = n_int_w + n_fp;
                const n_user_int_regs: u32 = if (callee_is_memory_class) 2 else 3;
                const n_overflow: u32 = if (n_total > n_user_int_regs) n_total - n_user_int_regs else 0;
                const shadow_and_overflow = abi.current.shadow_space_bytes + n_overflow * 8;
                const scratch_base = (shadow_and_overflow + 15) & ~@as(u32, 15);
                // Return buffer for MEMORY-class lives at the TOP
                // of THIS call's outgoing-args footprint (= above
                // v128 scratch); caller LEA RCX=&buffer per
                // emitCall's Win64 hidden-ptr setup.
                const return_buf_bytes: u32 = if (callee_is_memory_class)
                    @as(u32, @intCast(callee_sig.results.len)) * 8
                else
                    0;
                break :blk scratch_base + n_v128 * 16 + return_buf_bytes;
            },
        };
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
