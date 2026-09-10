//! #233 / ADR-0229 — the `.auto` boundary tells a validity VERDICT from a
//! capability DECLINE. A verdict is final on `.auto` and `.jit` alike and comes
//! with a `ZWASM_TRAP_INVALID_MODULE` trap naming the reason; a decline is a
//! bare `null` on `.jit` and the interpreter on `.auto`. Discovered by the
//! unit-test loader via `src/zwasm.zig`'s `test {}` block.

const std = @import("std");
const testing = std.testing;

const instance = @import("instance.zig");
const extern_new = @import("extern_new.zig");
const types = @import("types.zig");
const vec = @import("vec.zig");
const trap_surface = @import("trap_surface.zig");
const runner = @import("../engine/runner.zig");

fn inTable(table: []const []const u8, name: []const u8) bool {
    for (table) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "every runner.Error name is a verdict or a decline, never neither or both (#233)" {
    // The point of the walk: a new JIT-side check adds a name to
    // `runner.Error`, and this test refuses to pass until the author has said
    // which of the two it is.
    inline for (@typeInfo(runner.Error).error_set.?) |e| {
        const v = inTable(&instance.jit_verdict_names, e.name);
        const d = inTable(&instance.jit_decline_names, e.name);
        if (v == d) {
            std.debug.print("runner.Error.{s} is {s} (jit_verdict_names / jit_decline_names in api/instance.zig)\n", .{ e.name, if (v) "in both tables" else "in neither table" });
            return error.Unclassified;
        }
    }
    // And no table row names an error that no longer exists.
    for (instance.jit_verdict_names ++ instance.jit_decline_names) |row| {
        var found = false;
        inline for (@typeInfo(runner.Error).error_set.?) |e| {
            if (std.mem.eql(u8, e.name, row)) found = true;
        }
        if (!found) {
            std.debug.print("table row {s} is not a runner.Error\n", .{row});
            return error.StaleRow;
        }
    }
    try testing.expect(instance.isValidityVerdict(error.InvalidStartFunction));
    try testing.expect(!instance.isValidityVerdict(error.UnsupportedOp));
}

// The two modules chaploud probed in #233: the front-end validator lets them
// through (#285's remainder), the JIT's module-level check does not.
// (module (func $s (param i32)) (start $s))
const start_param_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, // type (i32) -> ()
    0x03, 0x02, 0x01, 0x00, // func 0: type 0
    0x08, 0x01, 0x00, // start 0
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: end
};
// (module (func) (export "a" (func 0)) (export "a" (func 0)))
const dup_export_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type () -> ()
    0x03, 0x02, 0x01, 0x00, // func 0: type 0
    0x07, 0x09, 0x02, 0x01, 0x61, 0x00, 0x00, 0x01, 0x61, 0x00, 0x00, // export "a" twice
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: end
};

fn expectVerdict(bytes: []const u8, engine: instance.EngineKind, reason: []const u8) !void {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = @constCast(bytes.ptr) };
    // Accepted here today; when #285 closes this, pick a module the JIT alone
    // still judges, or retire the case.
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var trap: ?*trap_surface.Trap = null;
    const inst = instance.instanceNewWithEngine(s, m, null, &trap, engine);
    defer if (inst) |i| instance.wasm_instance_delete(i);
    try testing.expect(inst == null);
    const t = trap orelse return error.NoTrap;
    defer trap_surface.wasm_trap_delete(t);
    try testing.expectEqual(trap_surface.TrapKind.invalid_module, t.kind);
    const msg = t.message_ptr.?[0..t.message_len];
    try testing.expect(std.mem.startsWith(u8, msg, "invalid module: "));
    try testing.expect(std.mem.find(u8, msg, reason) != null);
}

test ".auto and .jit: a validity verdict is NULL with an invalid_module trap naming the reason (#233)" {
    try expectVerdict(&start_param_wasm, .auto, "InvalidStartFunction");
    try expectVerdict(&start_param_wasm, .jit, "InvalidStartFunction");
    try expectVerdict(&dup_export_wasm, .auto, "DuplicateExport");
    try expectVerdict(&dup_export_wasm, .jit, "DuplicateExport");
}

// (module (import "e" "g" (global i32)) (func (export "get") (result i32) global.get 0))
// A non-func import is a shape the JIT declines (`collectFuncImportTargets`).
const global_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> (i32)
    0x02, 0x08, 0x01, 0x01, 0x65, 0x01, 0x67, 0x03, 0x7f, 0x00, // import e.g global i32
    0x03, 0x02, 0x01, 0x00, // func 0: type 0
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, // export "get" func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, // code: global.get 0
};

test ".auto: a capability decline falls through to the interpreter with no trap; .jit is a bare NULL (#233)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const gt = types.wasm_globaltype_new(types.wasm_valtype_new(0), 0) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt);
    var seven: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 7 } };
    const hg = extern_new.wasm_global_new(s, gt, &seven) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(hg);

    var bytes = global_import_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    var iarr = [_]?*instance.Extern{extern_new.wasm_global_as_extern(hg)};
    var imports: vec.ExternVec = .{ .size = iarr.len, .data = &iarr };

    var trap: ?*trap_surface.Trap = null;
    const jit_only = instance.instanceNewWithEngine(s, m, &imports, &trap, .jit);
    defer if (jit_only) |i| instance.wasm_instance_delete(i);
    try testing.expect(jit_only == null);
    try testing.expect(trap == null);

    const auto = instance.instanceNewWithEngine(s, m, &imports, &trap, .auto) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(auto);
    try testing.expect(trap == null);
    try testing.expect(auto.runtime != null); // the interpreter backs it
}

fn startCallback(args: ?*const vec.ValVec, results: ?*vec.ValVec) callconv(.c) ?*trap_surface.Trap {
    _ = args;
    _ = results;
    return null;
}

test ".auto: an imported start is a decline the interpreter runs, and no trap is left beside the instance (#233)" {
    // (module (import "e" "init" (func)) (start 0)) — the JIT cannot dispatch
    // an imported start (`runStart` → UnsupportedEntrySignature); PR #429
    // review: the decline used to write a trap first, so the interpreter's
    // instance came back beside a stale trap.
    const imported_start_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type () -> ()
        0x02, 0x0a, 0x01, 0x01, 0x65, 0x04, 0x69, 0x6e, 0x69, 0x74, 0x00, 0x00, // import e.init func 0
        0x08, 0x01, 0x00, // start 0
    };
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    var pv: types.ValTypeVec = undefined;
    var rv: types.ValTypeVec = undefined;
    types.wasm_valtype_vec_new_empty(&pv);
    types.wasm_valtype_vec_new_empty(&rv);
    const ft = types.wasm_functype_new(&pv, &rv) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    const hf = extern_new.wasm_func_new(s, ft, startCallback) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    var bytes = imported_start_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    var iarr = [_]?*instance.Extern{extern_new.wasm_func_as_extern(hf)};
    var imports: vec.ExternVec = .{ .size = iarr.len, .data = &iarr };

    var trap: ?*trap_surface.Trap = null;
    const auto = instance.instanceNewWithEngine(s, m, &imports, &trap, .auto) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(auto);
    try testing.expect(trap == null);
    try testing.expect(auto.runtime != null); // the interpreter ran the start
}

test ".jit: a defined start that traps is Final with the trap's own kind (#233)" {
    // (module (func $s unreachable) (start $s)) — the trap is read off the JIT
    // runtime, so it must be built before the JIT is torn down (PR #429
    // review, round 3).
    const start_traps_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type () -> ()
        0x03, 0x02, 0x01, 0x00, // func 0
        0x08, 0x01, 0x00, // start 0
        0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, // code: unreachable
    };
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = start_traps_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    for ([_]instance.EngineKind{ .jit, .auto }) |engine| {
        var trap: ?*trap_surface.Trap = null;
        const inst = instance.instanceNewWithEngine(s, m, null, &trap, engine);
        defer if (inst) |i| instance.wasm_instance_delete(i);
        try testing.expect(inst == null);
        const t = trap orelse return error.NoTrap;
        defer trap_surface.wasm_trap_delete(t);
        try testing.expectEqual(trap_surface.TrapKind.unreachable_, t.kind);
    }
}
