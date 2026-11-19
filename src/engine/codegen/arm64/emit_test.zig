//! arm64 emit pass — test orchestrator. Tests live in
//! sibling files by ZIR op family. This file pulls them
//! all into a single `zig build test` discoverable surface.
//!
//! Per ADR-0021 sub-deliverable b (emit.zig
//! 9-module split): the original 2356-LOC monolith
//! exceeded the §A2 hard cap. The split is by
//! ZIR op family so each sibling stays well under the soft cap
//! and `zig build test` discovery still reaches every test
//! through the root reference chain (`src/zwasm.zig`).
//!
//! `comptime` (not `test {}`) is used as the discovery aggregator
//! so this file adds zero new test entries — sibling test counts
//! sum verbatim into the unit-test runner.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const liveness_mod = @import("../../../ir/analysis/liveness.zig");

comptime {
    _ = @import("emit_test_alu_int.zig");
    _ = @import("emit_test_alu_float.zig");
    _ = @import("emit_test_control.zig");
    _ = @import("emit_test_call.zig");
    _ = @import("emit_test_call_stack_args.zig");
    _ = @import("emit_test_memory.zig");
    _ = @import("emit_test_local.zig");
    _ = liveness_mod; // hook upstream module so future regalloc tests are reachable
}
