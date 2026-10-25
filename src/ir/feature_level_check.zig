//! Comptime feature-level metadata check.
//!
//! Phase 9 completion master plan §7.9: makes "attaching incorrect
//! `wasm_level` metadata to an op file" physically impossible. Fires
//! on every `zig build` — the bidirectional invariant runs in
//! comptime context inside this module's `test` block + import-side
//! force in `src/zwasm.zig` (via the ladder that already pulls Zone 1).
//!
//! ## What we check
//!
//! For Wasm 3.0 ops registered in `dispatch_collector.collected_ops`:
//!
//! 1. **Registered → in list**: every `op_mod` with
//!    `wasm_level == .v3_0` has its `op_tag` listed in
//!    `v3_op_tags` below. `@compileError` if a registered
//!    v3_0 op_mod's tag is not in the list (= someone added
//!    a per-op file with wrong wasm_level).
//! 2. **In list → registered**: every tag in `v3_op_tags` has
//!    a matching registered op_mod with `wasm_level == .v3_0`.
//!    `@compileError` if a list-tag has no matching op_mod (=
//!    someone deleted a stub but forgot to remove the tag from
//!    the canonical list).
//!
//! v1_0 and v2_0 lists are deferred — current `collected_ops` has
//! 374 v1_0 ops and 0 v2_0 ops; enumerating 374 tags is a follow-up
//! that lands when (a) the wasm_2_0 cohort gets per-op migration,
//! or (b) someone wants v1_0 coverage. The v3_0 check exercises the
//! invariant shape; expansion is mechanical.
//!
//! Zone 1 (`src/ir/`) — imports Zone 0+1 only.

const std = @import("std");
const zir = @import("zir.zig");
const collector = @import("dispatch_collector.zig");

const ZirOp = zir.ZirOp;

/// Canonical list of ZirOp tags that belong to Wasm 3.0 features
/// (GC, EH, tail-call, typed function references). When a new
/// Wasm 3.0 op is registered (per-op file with `wasm_level: .v3_0`),
/// add its tag here in the same commit; comptime check below
/// catches the omission.
///
/// Cohorts (cumulative 41 tags as of §9.12-G):
/// - tail-call (3)
/// - exception-handling (3)
/// - typed function references (4)
/// - GC struct (6)
/// - GC array (14)
/// - GC ref/cast (8)
/// - GC i31 (3)
pub const v3_op_tags = [_]ZirOp{
    // tail-call
    .return_call,
    .return_call_indirect,
    .return_call_ref,
    // exception-handling
    .try_table,
    .throw,
    .throw_ref,
    // typed function references
    .call_ref,
    .br_on_null,
    .br_on_non_null,
    .@"ref.as_non_null",
    // GC struct
    .@"struct.new",
    .@"struct.new_default",
    .@"struct.get",
    .@"struct.get_s",
    .@"struct.get_u",
    .@"struct.set",
    // GC array
    .@"array.new",
    .@"array.new_default",
    .@"array.new_fixed",
    .@"array.new_data",
    .@"array.new_elem",
    .@"array.get",
    .@"array.get_s",
    .@"array.get_u",
    .@"array.set",
    .@"array.len",
    .@"array.fill",
    .@"array.copy",
    .@"array.init_data",
    .@"array.init_elem",
    // GC ref/cast
    .@"ref.test",
    .@"ref.test_null",
    .@"ref.cast",
    .@"ref.cast_null",
    .br_on_cast,
    .br_on_cast_fail,
    .@"any.convert_extern",
    .@"extern.convert_any",
    // GC i31
    .@"ref.i31",
    .@"i31.get_s",
    .@"i31.get_u",
};

fn tagInV3List(comptime tag: ZirOp) bool {
    comptime {
        for (v3_op_tags) |t| {
            if (t == tag) return true;
        }
        return false;
    }
}

/// Force evaluation of the bidirectional invariant at comptime.
/// Imported from `src/zwasm.zig` so `zig build` (any step) fires
/// the check; also exercised by the inline test block below for
/// `zig build test` coverage.
pub fn assertInvariant() void {
    comptime {
        @setEvalBranchQuota(20_000);

        // Direction 1: every registered v3_0 op_mod has its tag in v3_op_tags.
        for (collector.collected_ops) |op_mod| {
            if (@hasDecl(op_mod, "wasm_level")) {
                if (op_mod.wasm_level) |lvl| {
                    if (lvl == .v3_0) {
                        if (!tagInV3List(op_mod.op_tag)) {
                            @compileError("feature_level_check: op '" ++ @tagName(op_mod.op_tag) ++ "' has wasm_level=.v3_0 but is not listed in v3_op_tags — add the tag to feature_level_check.v3_op_tags or correct the per-op file's wasm_level.");
                        }
                    }
                }
            }
        }

        // Direction 2: every tag in v3_op_tags resolves to a
        // registered op_mod (caught via opModuleFor) AND that
        // op_mod's wasm_level is .v3_0.
        for (v3_op_tags) |tag| {
            const mod = collector.opModuleFor(tag) orelse @compileError(
                "feature_level_check: v3_op_tags entry '" ++ @tagName(tag) ++ "' has no registered op_mod — add a per-op file under src/instruction/wasm_3_0/ or remove the tag from the list.",
            );
            if (!@hasDecl(mod, "wasm_level") or mod.wasm_level == null or mod.wasm_level.? != .v3_0) {
                @compileError("feature_level_check: v3_op_tags entry '" ++ @tagName(tag) ++ "' has a registered op_mod but its wasm_level is not .v3_0 — fix the per-op file's wasm_level.");
            }
        }
    }
}

// Force comptime evaluation at module-load time.
comptime {
    assertInvariant();
}

// ============================================================
// Tests — exercise the framework (Step 5 gate coverage).
// ============================================================

test "feature_level_check: bidirectional v3 invariant holds for collected_ops" {
    // The comptime block above already runs the check; this test
    // serves as `zig build test` discoverability so the check is
    // covered by the standard test gate alongside dispatch_collector.
    assertInvariant();
}

test "feature_level_check: v3_op_tags has exactly 41 entries (cohorts: 3+3+4+6+14+8+3)" {
    try std.testing.expectEqual(@as(usize, 41), v3_op_tags.len);
}
