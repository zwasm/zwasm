//! TYPED component invoke — the canonical-ABI value bridge (ADR-0183).
//!
//! The closed sub-language this file implements is `CanonicalABI.md`
//! lift/lower at the VALUE level: public `ComponentValue` ⇄ canon value
//! model (`toCanonValue` / `fromCanonValue*`), plus the shared typed-invoke
//! core both entry points delegate to (`ComponentInstance.invokeTyped` for
//! single-module components, `invokeTypedBuilt` for the general WASI-P2
//! graph). The entry points stay in `component.zig` — they own the
//! instance-shaped resolution (which core instance, which realloc); this
//! file owns everything from "typed args" to "typed result".
//!
//! Zone 3 sibling of `component.zig` (split per `file_size_smell` P1).

const std = @import("std");

const canon = @import("../feature/component/canon.zig");
const ctypes = @import("../feature/component/types.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");
const runtime_value = @import("../runtime/value.zig");
const value_conv = @import("../zwasm/value_conv.zig");
const zwasm = @import("../zwasm.zig");

const Allocator = std.mem.Allocator;
const Instance = @import("../zwasm/instance.zig").Instance;
const Value = zwasm.Value;

pub const ComponentValue = @import("../feature/component/value.zig").ComponentValue;

pub const CanonContextError = error{NoMemory};

pub const InvokeTypedError = error{
    ExportNotResolved,
    ArgArityMismatch,
    UnsupportedEncoding,
    /// A value's shape does not match the export's WIT type (wrong union
    /// arm, record arity, variant case range, ...).
    ValueShapeMismatch,
} || canon.TypeBridgeError || canon.LowerFlatError || canon.LiftFlatError || canon.LoadError ||
    Instance.InvokeError || CanonContextError || std.mem.Allocator.Error;

/// Bridge a lowered core value (`runtime.Value`) to a facade `Value` for the
/// `invoke` path, per the flattened core type.
pub fn coreToFacade(rv: runtime_value.Value, ct: canon.CoreType) Value {
    return switch (ct) {
        .i32 => .{ .i32 = rv.i32 },
        .i64 => .{ .i64 = rv.i64 },
        .f32 => .{ .f32 = @bitCast(rv.f32) },
        .f64 => .{ .f64 = @bitCast(rv.f64) },
    };
}

/// REQ-6 (cw CM-API) — set a per-argument diagnostic (which arg index, the
/// expected WIT type kind, the actual host-value kind) before re-returning
/// the lowering error. Lets a host render "arg 2: expected u32, got list".
fn diagArg(err: InvokeTypedError, idx: usize, expected: canon.CanonType, got: ComponentValue) InvokeTypedError {
    diagnostic.setDiag(.execute, .other, .unknown, "typed invoke arg {d}: expected {s}, got {s}", .{
        idx,
        @tagName(std.meta.activeTag(expected)),
        @tagName(std.meta.activeTag(got)),
    });
    return err;
}

/// The shared typed-invoke pipeline (`CanonicalABI.md` canon_lift of a
/// canon-lowered call, host side): validate arity, lower the typed args
/// flat (spilling > MAX_FLAT_PARAMS to a guest-memory tuple), invoke the
/// lifted core func on `main_inst`, lift the result back into a
/// caller-owned `ComponentValue`, then run `post_return` on `pr_inst`.
///
/// `cx` must RE-FETCH guest memory on access (`memory_fn` contract) — a
/// guest `cabi_realloc` may grow/move it mid-call, so one context serves
/// the whole pipeline.
pub fn invokeTypedCore(
    gpa: Allocator,
    info: *const ctypes.TypeInfo,
    cx: canon.CanonContext,
    main_inst: *Instance,
    pr_inst: ?*Instance,
    ft: ctypes.FuncType,
    r: ctypes.TypeInfo.ResolvedLift,
    args: []const ComponentValue,
    out_alloc: Allocator,
) InvokeTypedError!?ComponentValue {
    // REQ-6 (cw CM-API): name the arity in the diagnostic so a host can
    // turn the bare error into a user-facing message.
    if (args.len != ft.params.len) {
        diagnostic.setDiag(.execute, .other, .unknown, "typed invoke: expected {d} argument(s), got {d}", .{ ft.params.len, args.len });
        return InvokeTypedError.ArgArityMismatch;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Lower the params flat (CanonicalABI lower_flat; spill > 16 flats).
    const ptypes = try a.alloc(canon.CanonType, ft.params.len);
    var flat_param_types: std.ArrayList(canon.CoreType) = .empty;
    for (ft.params, ptypes) |param, *slot| {
        slot.* = try canon.canonTypeFromDecoded(a, info, param.ty);
        try canon.flattenType(a, slot.*, &flat_param_types);
    }
    var flats: std.ArrayList(canon.CoreValue) = .empty;
    if (flat_param_types.items.len <= canon.MAX_FLAT_PARAMS) {
        for (args, ptypes, 0..) |arg, pt, i| {
            // REQ-6: blame the specific arg index + its expected/actual shape.
            const lowered = toCanonValue(a, arg, pt) catch |e| return diagArg(e, i, pt, arg);
            try canon.lowerFlat(cx, a, lowered, pt, &flats);
        }
    } else {
        // Spill: the params become one record stored in guest memory,
        // passed as a single i32 pointer (CanonicalABI flatten cap).
        const spill_fields = try a.alloc(canon.CanonType.Field, ptypes.len);
        for (ptypes, spill_fields) |pt, *f| f.* = .{ .name = "", .ty = pt };
        const spill_ty: canon.CanonType = .{ .record = spill_fields };
        const spill_vals = try a.alloc(canon.Value, args.len);
        for (args, ptypes, spill_vals, 0..) |arg, pt, *slot, i| slot.* = toCanonValue(a, arg, pt) catch |e| return diagArg(e, i, pt, arg);
        const size: u32 = @intCast(canon.sizeOf(spill_ty));
        const base = try cx.realloc(0, 0, @intCast(canon.alignmentOf(spill_ty)), size);
        try canon.store(cx, .{ .record = spill_vals }, spill_ty, base);
        try flats.append(a, canon.CoreValue.fromI32(@bitCast(base)));
        flat_param_types.clearRetainingCapacity();
        try flat_param_types.append(a, .i32);
    }

    // Result flattening shape (≤ 1 flat returns directly; else the guest
    // returns a pointer to the result area — the canon-lift convention).
    var ret_ct: ?canon.CanonType = null;
    var ret_flat_n: usize = 0;
    if (ft.result) |rt| {
        ret_ct = try canon.canonTypeFromDecoded(a, info, rt);
        var rtl: std.ArrayList(canon.CoreType) = .empty;
        try canon.flattenType(a, ret_ct.?, &rtl);
        ret_flat_n = rtl.items.len;
    }

    const argbuf = try a.alloc(Value, flats.items.len);
    for (flats.items, flat_param_types.items, argbuf) |fv, ct, *slot| slot.* = coreToFacade(fv, ct);
    var resbuf: [1]Value = .{.{ .i32 = 0 }};
    const results: []Value = if (ret_ct == null) resbuf[0..0] else resbuf[0..1];
    try main_inst.invoke(r.core_func.name, argbuf, results);

    var out: ?ComponentValue = null;
    if (ret_ct) |rc| {
        var lifted: canon.Value = undefined;
        if (ret_flat_n <= canon.MAX_FLAT_RESULTS) {
            var idx: usize = 0;
            const rcore = [_]canon.CoreValue{value_conv.zwasmToRuntime(resbuf[0])};
            lifted = try canon.liftFlat(cx, a, rc, rcore[0..ret_flat_n], &idx);
        } else {
            const ret_ptr: u32 = @bitCast(resbuf[0].i32);
            lifted = try canon.load(cx, a, rc, ret_ptr);
        }
        out = try fromCanonValue(out_alloc, info, ft.result.?, lifted);
    }
    errdefer if (out) |o| o.deinit(out_alloc);

    if (r.post_return) |pr| {
        if (pr_inst) |pri| {
            var pr_args = [_]Value{resbuf[0]};
            const pa: []Value = if (ret_ct == null) pr_args[0..0] else pr_args[0..1];
            try pri.invoke(pr.name, pa, &.{});
        }
    }
    return out;
}

/// Convert a public `ComponentValue` into the canon value model
/// (arena-allocated; record fields are matched POSITIONALLY against the
/// type — `toCanon` is called with the canon type to validate shapes).
fn toCanonValue(arena: std.mem.Allocator, v: ComponentValue, ty: canon.CanonType) InvokeTypedError!canon.Value {
    switch (ty) {
        // D-322: handles pass through as canon handle values (lowerFlat
        // does the borrow->rep translation against the component table).
        .own => return if (v == .own) .{ .handle = v.own } else InvokeTypedError.ValueShapeMismatch,
        .borrow => return if (v == .borrow) .{ .handle = v.borrow } else InvokeTypedError.ValueShapeMismatch,
        .prim => |p| return switch (p) {
            .string => if (v == .string) .{ .string = v.string } else InvokeTypedError.ValueShapeMismatch,
            .bool => if (v == .bool) .{ .bool = v.bool } else InvokeTypedError.ValueShapeMismatch,
            .s8 => if (v == .s8) .{ .s8 = v.s8 } else InvokeTypedError.ValueShapeMismatch,
            .u8 => if (v == .u8) .{ .u8 = v.u8 } else InvokeTypedError.ValueShapeMismatch,
            .s16 => if (v == .s16) .{ .s16 = v.s16 } else InvokeTypedError.ValueShapeMismatch,
            .u16 => if (v == .u16) .{ .u16 = v.u16 } else InvokeTypedError.ValueShapeMismatch,
            .s32 => if (v == .s32) .{ .s32 = v.s32 } else InvokeTypedError.ValueShapeMismatch,
            .u32 => if (v == .u32) .{ .u32 = v.u32 } else InvokeTypedError.ValueShapeMismatch,
            .s64 => if (v == .s64) .{ .s64 = v.s64 } else InvokeTypedError.ValueShapeMismatch,
            .u64 => if (v == .u64) .{ .u64 = v.u64 } else InvokeTypedError.ValueShapeMismatch,
            .f32 => if (v == .f32) .{ .f32 = v.f32 } else InvokeTypedError.ValueShapeMismatch,
            .f64 => if (v == .f64) .{ .f64 = v.f64 } else InvokeTypedError.ValueShapeMismatch,
            .char => if (v == .char) .{ .char = v.char } else InvokeTypedError.ValueShapeMismatch,
            .error_context => InvokeTypedError.ValueShapeMismatch,
        },
        // REQ-2: input dispatches by the numeric ordinal/bits (the label /
        // labels fields are output-only introspection aids).
        .enum_ => return if (v == .@"enum") .{ .enum_value = v.@"enum".index } else InvokeTypedError.ValueShapeMismatch,
        .flags => return if (v == .flags) .{ .flags = v.flags.bits } else InvokeTypedError.ValueShapeMismatch,
        .list => |elem| {
            const items = if (v == .list) v.list else return InvokeTypedError.ValueShapeMismatch;
            const out = try arena.alloc(canon.Value, items.len);
            for (items, out) |item, *slot| slot.* = try toCanonValue(arena, item, elem.*);
            return .{ .list = out };
        },
        .record => |fields| {
            // record OR (despecialized) tuple — both match positionally.
            const vals: []const ComponentValue = switch (v) {
                .record => |r| blk: {
                    const tmp = try arena.alloc(ComponentValue, r.len);
                    for (r, tmp) |f, *slot| slot.* = f.value;
                    break :blk tmp;
                },
                .tuple => |t| t,
                else => return InvokeTypedError.ValueShapeMismatch,
            };
            if (vals.len != fields.len) return InvokeTypedError.ValueShapeMismatch;
            const out = try arena.alloc(canon.Value, fields.len);
            for (fields, vals, out) |f, val, *slot| slot.* = try toCanonValue(arena, val, f.ty);
            return .{ .record = out };
        },
        .variant => |cases| {
            // variant OR a despecialized option/result value.
            const cv: ComponentValue.Variant = switch (v) {
                .variant => |vv| vv,
                .option => |opt| .{ .case = if (opt == null) 0 else 1, .payload = opt },
                .result => |r| .{ .case = if (r.is_ok) 0 else 1, .payload = r.payload },
                else => return InvokeTypedError.ValueShapeMismatch,
            };
            if (cv.case >= cases.len) return InvokeTypedError.ValueShapeMismatch;
            if (cases[cv.case].payload) |pt| {
                const pv = cv.payload orelse return InvokeTypedError.ValueShapeMismatch;
                const slot = try arena.create(canon.Value);
                slot.* = try toCanonValue(arena, pv.*, pt);
                return .{ .variant = .{ .case = cv.case, .payload = slot } };
            }
            if (cv.payload != null) return InvokeTypedError.ValueShapeMismatch;
            return .{ .variant = .{ .case = cv.case, .payload = null } };
        },
        // stream/future values aren't exposed through the typed public API yet
        // (CM-async; WASI-0.3 Unit F). Symmetric with fromCanonDefType.
        .stream, .future => return InvokeTypedError.UnsupportedType,
    }
}

/// Convert a canon value back into a caller-owned `ComponentValue`, guided
/// by the DECODED type (so records keep field NAMES and option/result/tuple
/// re-specialize from the variant/record canon forms).
fn fromCanonValue(out_alloc: std.mem.Allocator, info: *const ctypes.TypeInfo, vt: ctypes.ValType, cv: canon.Value) InvokeTypedError!ComponentValue {
    var arena_state = std.heap.ArenaAllocator.init(out_alloc);
    defer arena_state.deinit();
    return fromCanonValueScoped(out_alloc, arena_state.allocator(), info, &.{}, vt, cv);
}

/// `fromCanonValue` with an explicit NESTED-scope context: `locals` is the
/// decl-order local type space when `vt` came from an imported-instance
/// type declaration (empty at top level). `scratch` backs resolver
/// allocations only — output values are owned by `out_alloc`.
fn fromCanonValueScoped(out_alloc: std.mem.Allocator, scratch: std.mem.Allocator, info: *const ctypes.TypeInfo, locals: []const ?*const ctypes.DefType, vt: ctypes.ValType, cv: canon.Value) InvokeTypedError!ComponentValue {
    switch (vt) {
        .primitive => |p| return switch (p) {
            .string => .{ .string = try out_alloc.dupe(u8, cv.string) },
            .bool => .{ .bool = cv.bool },
            .s8 => .{ .s8 = cv.s8 },
            .u8 => .{ .u8 = cv.u8 },
            .s16 => .{ .s16 = cv.s16 },
            .u16 => .{ .u16 = cv.u16 },
            .s32 => .{ .s32 = cv.s32 },
            .u32 => .{ .u32 = cv.u32 },
            .s64 => .{ .s64 = cv.s64 },
            .u64 => .{ .u64 = cv.u64 },
            .f32 => .{ .f32 = cv.f32 },
            .f64 => .{ .f64 = cv.f64 },
            .char => .{ .char = cv.char },
            .error_context => InvokeTypedError.UnsupportedType,
        },
        .type_index => |ti| {
            if (locals.len != 0) {
                if (ti >= locals.len) return InvokeTypedError.InvalidTypeIndex;
                const dt = locals[ti] orelse return InvokeTypedError.UnsupportedType;
                return fromCanonDefType(out_alloc, scratch, info, locals, dt.*, cv);
            }
            const resolved = try canon.resolveTypeIndex(scratch, info, ti);
            return fromCanonDefType(out_alloc, scratch, info, resolved.locals, resolved.dt, cv);
        },
    }
}

fn fromCanonDefType(out_alloc: std.mem.Allocator, scratch: std.mem.Allocator, info: *const ctypes.TypeInfo, locals: []const ?*const ctypes.DefType, dt: ctypes.DefType, cv: canon.Value) InvokeTypedError!ComponentValue {
    switch (dt) {
        .value => |vt| return fromCanonValueScoped(out_alloc, scratch, info, locals, vt, cv),
        .record => |rec| {
            const fields = try out_alloc.alloc(ComponentValue.Field, rec.fields.len);
            errdefer out_alloc.free(fields);
            for (rec.fields, cv.record, fields) |f, val, *slot| {
                slot.* = .{ .name = f.name, .value = try fromCanonValueScoped(out_alloc, scratch, info, locals, f.ty, val) };
            }
            return .{ .record = fields };
        },
        .tuple => |t| {
            const items = try out_alloc.alloc(ComponentValue, t.types.len);
            errdefer out_alloc.free(items);
            for (t.types, cv.record, items) |ty, val, *slot| slot.* = try fromCanonValueScoped(out_alloc, scratch, info, locals, ty, val);
            return .{ .tuple = items };
        },
        .list => |l| {
            const items = try out_alloc.alloc(ComponentValue, cv.list.len);
            errdefer out_alloc.free(items);
            for (cv.list, items) |val, *slot| slot.* = try fromCanonValueScoped(out_alloc, scratch, info, locals, l.element.*, val);
            return .{ .list = items };
        },
        // A map value is its despecialized `list<tuple<k, v>>` (value.zig).
        .map => |m| {
            const items = try out_alloc.alloc(ComponentValue, cv.list.len);
            errdefer out_alloc.free(items);
            for (cv.list, items) |val, *slot| {
                const pair = try out_alloc.alloc(ComponentValue, 2);
                errdefer out_alloc.free(pair);
                pair[0] = try fromCanonValueScoped(out_alloc, scratch, info, locals, m.key, val.record[0]);
                pair[1] = try fromCanonValueScoped(out_alloc, scratch, info, locals, m.value, val.record[1]);
                slot.* = .{ .tuple = pair };
            }
            return .{ .list = items };
        },
        .option => |o| {
            if (cv.variant.case == 0) return .{ .option = null };
            const slot = try out_alloc.create(ComponentValue);
            errdefer out_alloc.destroy(slot);
            slot.* = try fromCanonValueScoped(out_alloc, scratch, info, locals, o.payload.*, cv.variant.payload.?.*);
            return .{ .option = slot };
        },
        .result => |r| {
            const is_ok = cv.variant.case == 0;
            const pt: ?ctypes.ValType = if (is_ok) r.ok else r.err;
            if (pt) |ty| {
                const slot = try out_alloc.create(ComponentValue);
                errdefer out_alloc.destroy(slot);
                slot.* = try fromCanonValueScoped(out_alloc, scratch, info, locals, ty, cv.variant.payload.?.*);
                return .{ .result = .{ .is_ok = is_ok, .payload = slot } };
            }
            return .{ .result = .{ .is_ok = is_ok, .payload = null } };
        },
        .variant => |v| {
            const case = cv.variant.case;
            if (case >= v.cases.len) return InvokeTypedError.ValueShapeMismatch;
            // REQ-2: carry the case label (borrows from the decoded TypeInfo).
            const case_name = v.cases[case].name;
            if (v.cases[case].payload) |pt| {
                const slot = try out_alloc.create(ComponentValue);
                errdefer out_alloc.destroy(slot);
                slot.* = try fromCanonValueScoped(out_alloc, scratch, info, locals, pt, cv.variant.payload.?.*);
                return .{ .variant = .{ .case = case, .case_name = case_name, .payload = slot } };
            }
            return .{ .variant = .{ .case = case, .case_name = case_name, .payload = null } };
        },
        // REQ-2: carry the enum label + the flags label list (borrow from TypeInfo).
        .enum_ => |e| {
            if (cv.enum_value >= e.labels.len) return InvokeTypedError.ValueShapeMismatch;
            return .{ .@"enum" = .{ .index = cv.enum_value, .label = e.labels[cv.enum_value] } };
        },
        .flags => |fl| return .{ .flags = .{ .bits = cv.flags, .labels = fl.labels } },
        .own => return .{ .own = cv.handle },
        // Borrow results are spec-invalid; func/type-scope forms aren't values.
        // stream/future typed lifting lands in WASI-0.3 Unit C.
        .func, .borrow, .stream, .future, .instance_type, .component_type, .resource => return InvokeTypedError.UnsupportedType,
    }
}

// ============================================================
// Tests (value-bridge unit level; e2e typed invokes live in
// component.zig + the corpus runner's assert_typed directive)
// ============================================================
const testing = std.testing;

test "REQ-2 (cw CM-API): lifted enum carries its label (borrow from TypeInfo)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `.enum_`/`.flags` leaf lifts read only the DefType — info/scratch unused.
    const dt = ctypes.DefType{ .enum_ = .{ .labels = &.{ "red", "green", "blue" } } };
    const out = try fromCanonDefType(a, a, undefined, &.{}, dt, .{ .enum_value = 1 });
    try testing.expectEqual(@as(u32, 1), out.@"enum".index);
    try testing.expectEqualStrings("green", out.@"enum".label);
    // Out-of-range ordinal is a shape error, not a crash.
    try testing.expectError(
        InvokeTypedError.ValueShapeMismatch,
        fromCanonDefType(a, a, undefined, &.{}, dt, .{ .enum_value = 3 }),
    );
}

test "REQ-2 (cw CM-API): lifted flags carry the bit-order label list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dt = ctypes.DefType{ .flags = .{ .labels = &.{ "a", "b", "c" } } };
    const out = try fromCanonDefType(a, a, undefined, &.{}, dt, .{ .flags = 0b101 });
    try testing.expectEqual(@as(u32, 0b101), out.flags.bits);
    try testing.expectEqual(@as(usize, 3), out.flags.labels.len);
    try testing.expectEqualStrings("a", out.flags.labels[0]); // bit 0 set
    try testing.expectEqualStrings("c", out.flags.labels[2]); // bit 2 set
}

test "REQ-2 (cw CM-API): lifted variant carries the case label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]ctypes.Case{
        .{ .name = "off", .payload = null },
        .{ .name = "on", .payload = null },
    };
    const dt = ctypes.DefType{ .variant = .{ .cases = &cases } };
    const out = try fromCanonDefType(a, a, undefined, &.{}, dt, .{ .variant = .{ .case = 1, .payload = null } });
    try testing.expectEqual(@as(u32, 1), out.variant.case);
    try testing.expectEqualStrings("on", out.variant.case_name);
}

test "toCanonValue rejects a wrong union arm (shape mismatch, not coercion)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(
        InvokeTypedError.ValueShapeMismatch,
        toCanonValue(a, .{ .u32 = 1 }, .{ .prim = .u64 }),
    );
}

test "toCanonValue despecializes result -> variant and validates payload presence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]canon.CanonType.VCase{
        .{ .name = "ok", .payload = .{ .prim = .u32 } },
        .{ .name = "err", .payload = null },
    };
    var payload: ComponentValue = .{ .u32 = 7 };
    const got = try toCanonValue(a, .{ .result = .{ .is_ok = true, .payload = &payload } }, .{ .variant = &cases });
    try testing.expectEqual(@as(u32, 0), got.variant.case);
    try testing.expectEqual(@as(u32, 7), got.variant.payload.?.u32);
    // err carries no payload for this type — supplying one is a shape error.
    try testing.expectError(
        InvokeTypedError.ValueShapeMismatch,
        toCanonValue(a, .{ .result = .{ .is_ok = false, .payload = &payload } }, .{ .variant = &cases }),
    );
}
