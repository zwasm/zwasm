//! x86_64 emit pass — test aggregator (D-051 close per ADR-0030).
//!
//! Mirror of `arm64/emit_test.zig`'s aggregator pattern. Tests
//! live in family-split sibling files; this file is the entry
//! the test runner reaches via `src/zwasm.zig`'s discovery hook.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

comptime {
    _ = @import("emit_test_int.zig");
    _ = @import("emit_test_float.zig");
    _ = @import("emit_test_call_stack_args.zig");
}
