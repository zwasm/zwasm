//! Central comptime dispatch collector — Phase 9 substrate audit Q3 C
//! adoption (per ADR-0023 §4.5 amend + ADR-0073, both Accepted 2026-05-19).
//!
//! This module is the **§9.12-A bootstrap** of the per-op file pattern:
//!
//!   `src/instruction/wasm_X_Y/<op>.zig` exports the canonical 5-axis
//!   handler aggregate (`pub const handlers = .{...}`) plus the
//!   `wasm_level` / `wasi_level` metadata. The collector imports every
//!   op module at comptime, validates the shape, applies the
//!   build-option DCE filter, and builds the central dispatcher per
//!   axis via `inline switch (op) { inline else => |tag| ... }`.
//!
//! In §9.12-A the framework + validation logic lands with an **empty**
//! `collected_ops` tuple. As §9.12-B migrates the 581 ZirOp handlers
//! into per-op files, each is appended here and the comptime validation
//! catches any missing axis / metadata.
//!
//! Design references:
//! - ADR-0023 §4.5 amend (per-op file migration plan).
//! - ADR-0073 (all-layer build-option DCE substrate).
//! - `private/spikes/q3-build-option-dce-poc/dispatch_collector.zig`
//!   (spike reference; 5-op PoC verified DCE works literally).
//!
//! Zone 1 (`src/ir/`) — imports Zone 0 (`build_options`) + Zone 1.

const std = @import("std");
const build_options = @import("build_options");
const zir = @import("zir.zig");

const ZirOp = zir.ZirOp;

/// WasmLevel + WasiLevel are declared inside `build.zig` and reach
/// every `build_options` consumer via `options.addOption`. We
/// re-export the runtime *values* below; per-op files type-annotate
/// against `@TypeOf(build_options.wasm_level)` so the build remains
/// the single source of truth for the enum shape.
pub const WasmLevel = @TypeOf(build_options.wasm_level);
pub const WasiLevel = @TypeOf(build_options.wasi_level);

/// IR-zone dispatch axes (per ADR-0074 split). The arch axes
/// (`arm64` / `x86_64`) live at the Zone 2 collector
/// `src/engine/codegen/dispatch_collector.zig::ArchAxis`.
pub const IRAxis = enum {
    validate,
    lower,
    interp,
};

/// Future-use feature gate tag set; placeholder for Phase 10 / 11
/// extensions (memory64, threads, custom-page-sizes, …).
pub const Feature = enum {
    /// No feature gate (always enabled).
    none,
};

// ---------------------------------------------------------------------
// Per-op module shape (the contract every `src/instruction/wasm_X_Y/<op>.zig`
// must satisfy):
//
//   pub const op_tag: ZirOp = .i32_add;
//   pub const wasm_level: ?WasmLevel = .v1_0;
//   pub const wasi_level: ?WasiLevel = null;
//   pub const enable_features: []const Feature = &.{};
//   pub const handlers = .{
//       .validate = validate_fn,
//       .lower    = lower_fn,
//       .arm64    = emit_arm64_fn,
//       .x86_64   = emit_x86_64_fn,
//       .interp   = interp_fn,
//   };
//
// `validateOpModule(comptime mod)` enforces this shape with
// `@compileError` messages that name what's missing.
// ---------------------------------------------------------------------

/// Comptime invariant check: a per-op file must export `op_tag`,
/// `wasm_level`, and a `handlers` struct with all IR-zone axes
/// (validate / lower / interp). Per-arch handlers live in Zone 2
/// per-arch op files per ADR-0074 and are validated separately by
/// `engine/codegen/dispatch_collector.zig::validateArchOpModule`.
pub fn validateOpModule(comptime mod: type) void {
    comptime {
        if (!@hasDecl(mod, "op_tag")) {
            @compileError("per-op file missing `pub const op_tag: ZirOp = ...;`");
        }
        if (!@hasDecl(mod, "wasm_level")) {
            @compileError("per-op file missing `pub const wasm_level: ?WasmLevel = ...;`");
        }
        if (!@hasDecl(mod, "handlers")) {
            @compileError("per-op file missing `pub const handlers = .{ .validate, .lower, .interp };`");
        }
        const H = @TypeOf(mod.handlers);
        for (@typeInfo(IRAxis).@"enum".field_names) |axis_name| {
            if (!@hasField(H, axis_name)) {
                @compileError("per-op file '" ++ @tagName(mod.op_tag) ++ "' missing handler `." ++ axis_name ++ "` in `pub const handlers`");
            }
        }
    }
}

/// Comptime build-option filter. Returns `true` when the op is
/// enabled by the current `-Dwasm=` / `-Dwasi=` build flags.
///
/// Used as the guard in `inline for` loops + `inline switch`
/// dispatchers so disabled op bodies are never instantiated → no
/// symbol emitted in the binary.
pub fn enabledByBuild(comptime mod: type) bool {
    comptime {
        if (@hasDecl(mod, "wasm_level")) {
            if (mod.wasm_level) |lvl| {
                if (@backingInt(lvl) > @backingInt(build_options.wasm_level)) {
                    return false;
                }
            }
        }
        if (@hasDecl(mod, "wasi_level")) {
            if (mod.wasi_level) |lvl| {
                // ADR-0193: WasiLevel is an ordered tier (none<p1<p2<p3);
                // an op needing a higher level than the build provides is
                // filtered out. The `both` wildcard was dropped — the tier
                // ordering subsumes it.
                const cur = @backingInt(build_options.wasi_level);
                const need = @backingInt(lvl);
                if (need > cur) {
                    return false;
                }
            }
        }
        return true;
    }
}

// ---------------------------------------------------------------------
// Collected op modules.
//
// §9.12-A bootstrap: empty. §9.12-B migration appends one entry per
// migrated op:
//
//     const i32_add = @import("../instruction/wasm_1_0/i32_add.zig");
//     ...
//     pub const collected_ops = .{
//         i32_add,
//         ...
//     };
//
// The validation at module top-level walks the tuple and runs
// `validateOpModule(@TypeOf(op))` on each, emitting a `@compileError`
// if any shape invariant is violated. This means **adding a malformed
// per-op file fails the build immediately** — the substrate cannot
// silently regress.
// ---------------------------------------------------------------------

// Per-op module imports. As §9.12-B sub-chunks migrate ops, each new
// per-op file is added below and appended to `collected_ops`.
// Op registry extracted to `dispatch_collector_ops.zig` per ADR-0082.
// The dispatcher framework + comptime helpers + tests remain in
// this file; the ~900-LOC registry is now a sibling. External
// callers (feature_level_check.zig, validator, lower, codegen)
// keep using `dispatch_collector.collected_ops` via the re-export.
const ops_registry = @import("dispatch_collector_ops.zig");
pub const collected_ops = ops_registry.collected_ops;

comptime {
    @setEvalBranchQuota(10_000);
    for (collected_ops) |op_mod| {
        validateOpModule(op_mod);
    }
}

/// Count of currently-migrated ops, filtered by the active build options.
/// All comptime-resolved; returns a constant for the current build.
pub fn migratedOpCount() usize {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        var n: usize = 0;
        for (collected_ops) |op_mod| {
            if (enabledByBuild(op_mod)) {
                n += 1;
            }
        }
        break :blk n;
    };
}

/// Count of ZirOp tags (canonical authoritative number; ~581 at Phase 9).
pub fn zirOpTagCount() usize {
    return @typeInfo(ZirOp).@"enum".field_names.len;
}

/// Whether the substrate migration is complete (= every ZirOp tag has
/// a corresponding per-op module). At §9.12-B exit this returns true;
/// during §9.12-A it returns false (collected_ops is empty).
pub fn migrationComplete() bool {
    return migratedOpCount() == zirOpTagCount();
}

// ---------------------------------------------------------------------
// Dispatcher framework (per-axis).
//
// In §9.12-B, validator.zig / lower.zig / arm64/emit.zig /
// x86_64/emit.zig / interp/dispatch.zig will replace their exhaustive
// switches with thin calls to `dispatcher(.<axis>)`. The dispatcher
// inline-switches on the ZirOp tag; each arm `comptime`-resolves the
// corresponding op_mod and either invokes the handler or `continue`s
// (skipping if disabled by build option).
//
// At §9.12-A the dispatcher returns a placeholder error for every op,
// because `collected_ops` is empty. The framework compiles, gets
// covered by tests, and is ready for §9.12-B to fill in.
// ---------------------------------------------------------------------

pub const DispatchError = error{
    /// The op is not migrated to a per-op file yet (§9.12-B incomplete).
    /// Eliminated once `migrationComplete()` returns true.
    NotMigrated,
    /// The op is filtered out by the current build option set (e.g.
    /// `-Dwasm=v1_0` building Wasm 2.0+ op).
    UnsupportedOpForBuildLevel,
};

/// Populate a `DispatchTable.interp` slot from each migrated op_mod
/// whose `handlers.interp` matches the `dispatch_table.InterpFn`
/// signature. Per ADR-0073 + `.dev/dispatcher_wire_design.md` §2.4:
/// the interp axis is structurally **table-population** (function
/// pointer table indexed by ZirOp) rather than per-call switch.
///
/// At §9.12-B / B6 this function is a no-op installer: i32_add and
/// any subsequent stubs use the zero-arg `fn() DispatchError!void`
/// shape — installing them as `InterpFn` would require a wrapper
/// that returns `error.NotMigrated` to the runtime, breaking
/// real-op interp paths. The function exists so the wire-in shape
/// is in place; later B-handler-migration sub-chunks (when per-op
/// interp handlers gain the proper `(ctx, instr) anyerror!void`
/// signature) will install them here. Comptime check via
/// `@TypeOf(op_mod.handlers.interp) == @import("dispatch_table.zig").InterpFn`
/// gates each installation; stubs remain skipped.
pub fn populateDispatchTable(table: *@import("dispatch_table.zig").DispatchTable) void {
    const InterpFn = @import("dispatch_table.zig").InterpFn;
    inline for (collected_ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        const handler = @field(op_mod.handlers, "interp");
        if (comptime @TypeOf(handler) == InterpFn) {
            // Install; per-op handler is real, matches the runtime
            // dispatch signature.
            table.interp[@backingInt(op_mod.op_tag)] = handler;
        }
        // Else: per-op handler is still a stub. Skip installation;
        // legacy interp slot retains authority.
    }
}

/// Look up the per-op module for `tag` at comptime; returns null when
/// no migrated module matches. The returned `type` is the imported
/// namespace (`@import("instruction/wasm_X_Y/<op>.zig")` — a `type`
/// value in Zig); callers can read `.op_tag` / `.handlers.*` off it.
pub fn opModuleFor(comptime tag: ZirOp) ?type {
    comptime {
        @setEvalBranchQuota(10_000);
        for (collected_ops) |op_mod| {
            if (op_mod.op_tag == tag) {
                return op_mod;
            }
        }
        return null;
    }
}

/// Per-axis dispatch. Walks `collected_ops` at comptime, picks the
/// arm matching `op`'s tag, applies the build-option filter, and
/// invokes the axis handler with `ctx`.
///
/// Returns `error.NotMigrated` when no migrated op_mod matches the
/// tag (= the legacy dispatcher in validator/lower/emit/interp is
/// still authoritative for that op). Returns
/// `error.UnsupportedOpForBuildLevel` when a migrated op exists but
/// is filtered out by the current `-Dwasm=` / `-Dwasi=` build.
/// Otherwise propagates whatever the axis handler returned.
///
/// §9.12-B / B2 lands this function with `anyerror!void` shape; the
/// validator / lower / emit / interp call sites (B3..Bn) wrap their
/// per-axis ctx types into the call. At each axis-migration sub-chunk,
/// the legacy dispatcher in that file becomes a thin call to
/// `dispatcher(.<axis>)(op, &ctx)` that falls through to a residual
/// legacy switch only when `error.NotMigrated` is returned.
pub fn dispatcher(comptime axis: IRAxis) fn (op: ZirOp, args: anytype) DispatchError!void {
    return dispatcherOver(axis, collected_ops);
}

/// Parametrised dispatcher backing `dispatcher()` + test entry-point.
/// Walks `ops` and returns:
///   - `UnsupportedOpForBuildLevel` — tag matches a registered op_mod
///     but the current `-Dwasm=` / `-Dwasi=` build filters it out.
///     The disabled op_mod's handler body is NOT instantiated (DCE
///     preserved); only the tag comparison + error return is emitted.
///   - `NotMigrated` — tag not present in `ops`. Legacy dispatcher
///     remains authoritative.
///   - whatever the axis handler returns — tag matches AND build-enabled.
fn dispatcherOver(comptime axis: IRAxis, comptime ops: anytype) fn (op: ZirOp, args: anytype) DispatchError!void {
    return struct {
        fn dispatch(op: ZirOp, args: anytype) DispatchError!void {
            inline for (ops) |op_mod| {
                if (comptime !enabledByBuild(op_mod)) {
                    if (op == op_mod.op_tag) {
                        return DispatchError.UnsupportedOpForBuildLevel;
                    }
                    continue;
                }
                if (op == op_mod.op_tag) {
                    // Per-op handlers in B-sub-chunks (until they migrate
                    // to real bodies) only return DispatchError values.
                    // Once real bodies land, the dispatcher will become
                    // generic over the axis's Error set; B-pre work uses
                    // the narrow set so callers can match exhaustively.
                    return @call(.auto, @field(op_mod.handlers, @tagName(axis)), args);
                }
            }
            return DispatchError.NotMigrated;
        }
    }.dispatch;
}

// ---------------------------------------------------------------------
// Tests — exercise the framework (Step 5 gate coverage).
// ---------------------------------------------------------------------

test "zirOpTagCount matches the ZirOp enum field count" {
    const n = zirOpTagCount();
    // Phase 9 has 581 declared ZirOp tags (per ADR-0071 §Context).
    // Loose lower bound test — any drop indicates an accidental enum truncation.
    try std.testing.expect(n >= 200);
}

test "migratedOpCount tracks collected_ops length (415 after §9.12-G GC ref/cast + i31)" {
    // Running tally:
    //   374 §9.12-B / B52 baseline
    // +   3 Wasm 3.0 tail-call (return_call / _indirect / _ref)
    // +   3 Wasm 3.0 EH (try_table / throw / throw_ref)
    // +   4 Wasm 3.0 typed-func-refs (call_ref / br_on_null /
    //         br_on_non_null / ref.as_non_null)
    // +   6 Wasm 3.0 GC struct (6 ops)
    // +  14 Wasm 3.0 GC array (14 ops)
    // +   8 Wasm 3.0 GC ref/cast (ref.test / ref.test_null /
    //         ref.cast / ref.cast_null / br_on_cast /
    //         br_on_cast_fail / any.convert_extern /
    //         extern.convert_any)
    // +   3 Wasm 3.0 GC i31 (ref.i31 / i31.get_s / i31.get_u)
    // = 415.
    try std.testing.expectEqual(@as(usize, 415), migratedOpCount());
}

test "opModuleFor resolves GC struct cohort stubs" {
    try std.testing.expect(comptime opModuleFor(.@"struct.new") != null);
    try std.testing.expect(comptime opModuleFor(.@"struct.new_default") != null);
    try std.testing.expect(comptime opModuleFor(.@"struct.get") != null);
    try std.testing.expect(comptime opModuleFor(.@"struct.get_s") != null);
    try std.testing.expect(comptime opModuleFor(.@"struct.get_u") != null);
    try std.testing.expect(comptime opModuleFor(.@"struct.set") != null);
}

test "opModuleFor resolves GC array cohort stubs" {
    try std.testing.expect(comptime opModuleFor(.@"array.new") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.new_default") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.new_fixed") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.new_data") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.new_elem") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.get") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.get_s") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.get_u") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.set") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.len") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.fill") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.copy") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.init_data") != null);
    try std.testing.expect(comptime opModuleFor(.@"array.init_elem") != null);
}

test "opModuleFor resolves GC ref/cast + i31 cohort stubs" {
    try std.testing.expect(comptime opModuleFor(.@"ref.test") != null);
    try std.testing.expect(comptime opModuleFor(.@"ref.test_null") != null);
    try std.testing.expect(comptime opModuleFor(.@"ref.cast") != null);
    try std.testing.expect(comptime opModuleFor(.@"ref.cast_null") != null);
    try std.testing.expect(comptime opModuleFor(.br_on_cast) != null);
    try std.testing.expect(comptime opModuleFor(.br_on_cast_fail) != null);
    try std.testing.expect(comptime opModuleFor(.@"any.convert_extern") != null);
    try std.testing.expect(comptime opModuleFor(.@"extern.convert_any") != null);
    try std.testing.expect(comptime opModuleFor(.@"ref.i31") != null);
    try std.testing.expect(comptime opModuleFor(.@"i31.get_s") != null);
    try std.testing.expect(comptime opModuleFor(.@"i31.get_u") != null);
}

test "opModuleFor resolves Phase 10 Wasm 3.0 stubs (tail-call + EH + typed-func-refs)" {
    // §9.12-G Phase 10 prep: Wasm 3.0 ops registered with
    // `wasm_level: .v3_0`. Under default -Dwasm=v3_0 they pass
    // the build filter; stub handlers return NotMigrated. Under
    // -Dwasm=v2_0 the dispatcher returns UnsupportedOpForBuildLevel
    // (per the synthetic build-filter test above).
    // Tail-call cohort.
    try std.testing.expect(comptime opModuleFor(.return_call) != null);
    try std.testing.expect(comptime opModuleFor(.return_call_indirect) != null);
    try std.testing.expect(comptime opModuleFor(.return_call_ref) != null);
    // EH cohort.
    try std.testing.expect(comptime opModuleFor(.try_table) != null);
    try std.testing.expect(comptime opModuleFor(.throw) != null);
    try std.testing.expect(comptime opModuleFor(.throw_ref) != null);
    // Typed-func-refs cohort.
    try std.testing.expect(comptime opModuleFor(.call_ref) != null);
    try std.testing.expect(comptime opModuleFor(.br_on_null) != null);
    try std.testing.expect(comptime opModuleFor(.br_on_non_null) != null);
    try std.testing.expect(comptime opModuleFor(.@"ref.as_non_null") != null);
}

test "migrationComplete is false until §9.12-B migrates all 581 ops" {
    try std.testing.expect(!migrationComplete());
}

test "opModuleFor returns the registered op_mod for migrated ops" {
    // i32.add is the first per-op module migrated in §9.12-B / B1.
    const result = comptime opModuleFor(.@"i32.add");
    try std.testing.expect(result != null);
}

test "opModuleFor returns null for not-yet-migrated tags" {
    // Use a tag that's still in the legacy dispatch path. `unreachable`
    // is in the Wasm 1.0 control category — migrates in a later
    // §9.12-B sub-chunk.
    const result = comptime opModuleFor(.@"unreachable");
    try std.testing.expectEqual(@as(?type, null), result);
}

test "IRAxis enum has exactly 3 variants per ADR-0074 (Zone 1 IR-axes only)" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(IRAxis).@"enum".field_names.len);
}

test "dispatcherOver returns UnsupportedOpForBuildLevel for build-filtered op tag (Phase 10 prep)" {
    // §9.12-G prep: when a Phase 10 / Wasm 3.0 op_mod is registered
    // but the current build's -Dwasm= / -Dwasi= filters it out, the
    // dispatcher must distinguish "tag matched but disabled" from
    // "tag not registered". The former → UnsupportedOpForBuildLevel,
    // the latter → NotMigrated. Caller code in validator.zig /
    // lower.zig pattern-matches both as "fall through to legacy
    // switch" today; future Phase 10 paths can surface the disabled-
    // op case explicitly as an error.
    //
    // Synthetic op_mod with wasi_level: .p3 is filtered under the
    // default -Dwasi=p2 build (p3 > p2 in the ordered tier; ADR-0193).
    // A max-tier (.p3) build has nothing above it to filter, so the
    // "build-filtered" case is unreachable there — comptime-skip.
    if (comptime build_options.wasi_level == .p3) return;
    const synthetic = struct {
        pub const op_tag: ZirOp = .@"unreachable";
        pub const wasm_level: ?WasmLevel = null;
        pub const wasi_level: ?WasiLevel = .p3;
        pub const handlers = .{
            .validate = unreachable_axis_stub,
            .lower = unreachable_axis_stub,
            .interp = unreachable_axis_stub,
        };

        fn unreachable_axis_stub() DispatchError!void {
            return error.NotMigrated;
        }
    };

    const disp = dispatcherOver(.validate, .{synthetic});

    // Tag matches → build-filtered → UnsupportedOpForBuildLevel.
    try std.testing.expectError(error.UnsupportedOpForBuildLevel, disp(.@"unreachable", .{}));

    // Tag does NOT match → fall through to NotMigrated.
    try std.testing.expectError(error.NotMigrated, disp(.@"i32.add", .{}));
}

test "dispatcher(.validate) routes i32.add to its per-op stub (returns NotMigrated by design)" {
    // i32_add's validate handler is a B1 stub that returns
    // error.NotMigrated. The dispatcher finds the matching op_mod and
    // invokes the stub; the err propagates back to the caller. Once
    // B-sub-chunks implement real validate bodies, this same call
    // shape will return `void` on success.
    const result = dispatcher(.validate)(.@"i32.add", .{});
    try std.testing.expectError(error.NotMigrated, result);
}

test "dispatcher(.validate) returns NotMigrated for not-yet-migrated tags" {
    // `unreachable` is not migrated; collector returns NotMigrated so
    // the legacy validator switch retains authority.
    const result = dispatcher(.validate)(.@"unreachable", .{});
    try std.testing.expectError(error.NotMigrated, result);
}

test "populateDispatchTable is callable + no-op for current stubs" {
    // i32_add's interp handler is a zero-arg DispatchError!void stub —
    // signature doesn't match InterpFn, so populateDispatchTable
    // intentionally skips it. The table's interp slots remain all
    // null after this call.
    var table = @import("dispatch_table.zig").DispatchTable.init();
    populateDispatchTable(&table);
    try std.testing.expect(table.interp[@backingInt(ZirOp.@"i32.add")] == null);
}

test "dispatcher returns a callable function value per IR-axis" {
    inline for (@typeInfo(IRAxis).@"enum".field_values) |f_value| {
        const axis: IRAxis = @fromBackingInt(@intCast(f_value));
        const fn_ref = dispatcher(axis);
        _ = fn_ref;
    }
}
