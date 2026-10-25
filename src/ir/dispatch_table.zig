//! Central per-`ZirOp` dispatch table (ROADMAP §4.5 / A12).
//!
//! Per-feature modules (`src/feature/<feature>/mod.zig`, Phase 1.7+)
//! call `register(*DispatchTable)` at startup to install handlers
//! for the ops they own. The frontend / interpreter / JIT then
//! consult the table by `@intFromEnum(ZirOp.<op>)` and **never**
//! branch on feature flags (§A12 — no pervasive build-time `if`).
//!
//! Phase 1 / task 1.3 declares the type and the slot identities
//! only. The function-pointer signatures below thread an opaque
//! context (`ParserCtx` / `InterpCtx` / `EmitCtx`) so the layered
//! caller types can land in later phases (parser 1.4, interp
//! Phase 2, JIT Phase 7) without forcing this file to import
//! upward.
//!
//! Zone 1 — imports `ir/zir.zig` only.

const std = @import("std");
const zir = @import("zir.zig");

pub const ZirOp = zir.ZirOp;
pub const ZirInstr = zir.ZirInstr;

/// Compile-time count of declared `ZirOp` tags. Determines the
/// fixed-array size of every dispatch slot. Adding a tag to
/// `ZirOp` (a §4 deviation requiring an ADR) grows N_OPS.
pub const N_OPS: comptime_int = @typeInfo(ZirOp).@"enum".field_names.len;

pub const ParserCtx = opaque {};
pub const InterpCtx = opaque {};
pub const EmitCtx = opaque {};

pub const ParseFn = *const fn (ctx: *ParserCtx, instr: *ZirInstr) anyerror!void;
pub const InterpFn = *const fn (ctx: *InterpCtx, instr: *const ZirInstr) anyerror!void;
pub const EmitFn = *const fn (ctx: *EmitCtx, instr: *const ZirInstr) anyerror!void;

pub const DispatchTable = struct {
    parsers: [N_OPS]?ParseFn,
    interp: [N_OPS]?InterpFn,
    jit_arm64: [N_OPS]?EmitFn,
    jit_x86: [N_OPS]?EmitFn,

    pub fn init() DispatchTable {
        return .{
            .parsers = @splat(null),
            .interp = @splat(null),
            .jit_arm64 = @splat(null),
            .jit_x86 = @splat(null),
        };
    }
};

test "DispatchTable.init: every slot is null" {
    const t = DispatchTable.init();
    var i: usize = 0;
    while (i < N_OPS) : (i += 1) {
        try std.testing.expect(t.parsers[i] == null);
        try std.testing.expect(t.interp[i] == null);
        try std.testing.expect(t.jit_arm64[i] == null);
        try std.testing.expect(t.jit_x86[i] == null);
    }
}

test "DispatchTable: N_OPS matches ZirOp tag count" {
    try std.testing.expectEqual(@typeInfo(ZirOp).@"enum".field_names.len, N_OPS);
}

test "DispatchTable: per-op slot can be set and read back" {
    const Stub = struct {
        fn parse(_: *ParserCtx, _: *ZirInstr) anyerror!void {
            // Test stub — intentionally empty.
        }
        fn interp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
            // Test stub — intentionally empty.
        }
        fn emit(_: *EmitCtx, _: *const ZirInstr) anyerror!void {
            // Test stub — intentionally empty.
        }
    };
    var t = DispatchTable.init();
    const idx = @backingInt(ZirOp.@"i32.add");
    t.parsers[idx] = Stub.parse;
    t.interp[idx] = Stub.interp;
    t.jit_arm64[idx] = Stub.emit;
    t.jit_x86[idx] = Stub.emit;
    try std.testing.expect(t.parsers[idx] != null);
    try std.testing.expect(t.interp[idx] != null);
    try std.testing.expect(t.jit_arm64[idx] != null);
    try std.testing.expect(t.jit_x86[idx] != null);
    // A neighbouring slot stays null.
    const other = @backingInt(ZirOp.@"i32.sub");
    try std.testing.expect(t.parsers[other] == null);
}
