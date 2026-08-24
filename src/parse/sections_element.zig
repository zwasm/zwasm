//! Wasm element section decoder (Wasm 2.0 §5.5.12, 8 forms 0–7).
//! Originally extracted per ADR-0095 (superseded by ADR-0101);
//! const-expression helpers now live in `init_expr.zig` per
//! ADR-0099 §D2 (P3 deep utility). This file keeps `sections.zig`
//! imported for `sections.Error` (the externally-observable
//! section-decoder error union).

const std = @import("std");
const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");
const sections = @import("sections.zig");
const init_expr = @import("init_expr.zig");
const i31_enc = @import("../feature/gc/i31.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;

pub const ElementKind = enum { active, passive, declarative };

/// Wasm 3.0 §5.5.12 — an element segment's element type depends on its FORM,
/// and the two forms disagree on nullability:
///
///   flags 0x00-0x03  funcidx vector  -> NON-NULLABLE `(ref func)`
///   flags 0x04       expr vector     -> nullable `funcref`
///   flags 0x05-0x07  expr vector     -> the declared reftype
///
/// which is exactly what the reference decoder assigns — `(NoNull, FuncHT)`
/// for the first group via `elem`/`elem_kind`, `(Null, FuncHT)` for 0x04
/// (`interpreter/binary/decode.ml`). Recording the nullable `funcref` for the
/// funcidx form made a `(ref func)` table refuse its own legacy segment, while
/// recording the non-nullable one for 0x04 would have let a `funcref` segment
/// pass into a `(ref func)` table.
const FUNCIDX_ELEM_TYPE: ValType = .{ .ref = zir.RefType.abs(.func, false) };

pub const ElementSegment = struct {
    kind: ElementKind,
    tableidx: u32 = 0,
    offset_expr: []const u8 = &.{},
    elem_type: ValType = .funcref,
    /// funcref / ref.null / i31 / global.get items — u32-encoded (funcidx,
    /// `maxInt` null sentinel, or i31-pack). Legacy path; load-bearing for
    /// every funcref-table fixture. Mutually exclusive with `item_exprs`.
    funcidxs: []const u32 = &.{},
    /// 10.G cycle 164 — Wasm 3.0 GC general const-expr items (array.new /
    /// array.new_fixed / struct.new …): raw per-item expression bytes,
    /// evaluated to Values at instantiate via `evalGlobalInitGc`. Populated
    /// instead of `funcidxs` when a flag-5 segment's items start with 0xFB.
    item_exprs: []const []const u8 = &.{},
};

pub const Elements = struct {
    arena: std.heap.ArenaAllocator,
    items: []ElementSegment,

    pub fn deinit(self: *Elements) void {
        self.arena.deinit();
    }
};

/// Decode the body of an element section (Wasm 2.0 §5.5.12).
/// 10.G cycle 164 — classify a flag-4/5/6/7 element item const-expr:
/// true iff it constructs a GC aggregate (struct.new / array.new family),
/// false for a simple ref.func / ref.null / global.get / i31 item.
/// Scans the expr the same way `scanInitExpr` does (LEB-aware, so a 0xFB
/// byte inside an immediate doesn't false-match) and reports whether a
/// struct.new/array.new opcode appears before the `0x0B` end. Items start
/// with their ARGS (e.g. `i32.const`), so peeking the first byte is not
/// enough; and the segment's concrete reftype can't disambiguate
/// func-vs-array in the element section (no type-section access here).
fn itemIsGeneralConstExpr(body: []const u8, start: usize) bool {
    var p = start;
    while (p < body.len) {
        const op = body[p];
        p += 1;
        switch (op) {
            0x0B => return false,
            // LEB-immediate ops (i32/i64.const, global.get, ref.func):
            // skip the immediate by reading it (value discarded).
            0x41, 0x42, 0x23, 0xD2 => _ = leb128.readUleb128(u64, body, &p) catch return false,
            0x43 => p += 4,
            0x44 => p += 8,
            0xD0 => p += 1, // ref.null reftype byte
            0xFB => {
                const sub = leb128.readUleb128(u32, body, &p) catch return false;
                switch (sub) {
                    // struct.new / struct.new_default / array.new[_default] /
                    // array.new_fixed → general GC constructor.
                    0, 1, 6, 7, 8 => return true,
                    else => {}, // ref.i31 (28) / convert ops — keep scanning
                }
            },
            else => return false,
        }
    }
    return false;
}

/// Supports all 8 forms (0–7) per ADR-0014 §2.1 / 6.K.4. Forms
/// 0/1/3/4 ship in chunk 5d-2; 2/5/6/7 land in 6.K.4. Funcref is
/// the only supported reftype in v0.1.0; externref defers to a
/// follow-up row when the externref test corpus arrives.
pub fn decodeElement(parent_alloc: Allocator, body: []const u8) sections.Error!Elements {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    // An element segment occupies ≥1 byte (its flag prefix) — reject an
    // oversized count before allocating (Wasm spec §5.1.3 vec).
    if (count > body.len - pos) return sections.Error.UnexpectedEnd;
    const items = try alloc.alloc(ElementSegment, count);

    for (items) |*e| {
        const flag = try leb128.readUleb128(u32, body, &pos);
        switch (flag) {
            0 => {
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{
                    .kind = .active,
                    .tableidx = 0,
                    .offset_expr = expr,
                    .elem_type = FUNCIDX_ELEM_TYPE,
                    .funcidxs = funcs,
                };
            },
            1 => {
                if (pos >= body.len) return sections.Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return sections.Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{ .kind = .passive, .elem_type = FUNCIDX_ELEM_TYPE, .funcidxs = funcs };
            },
            3 => {
                if (pos >= body.len) return sections.Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return sections.Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{ .kind = .declarative, .elem_type = FUNCIDX_ELEM_TYPE, .funcidxs = funcs };
            },
            4 => {
                // active, table 0, offset expr, vec(reftype-expr).
                // wast2json with --enable-function-references emits
                // funcref segments in this form. Each expr is either
                // `ref.func F; end` (0xD2 LEB128(F) 0x0B) or
                // `ref.null funcref; end` (0xD0 0x70 0x0B); the
                // latter resolves to the spec null sentinel via
                // `funcidxs` carrying `std.math.maxInt(u32)`.
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, .funcref);
                e.* = .{
                    .kind = .active,
                    .tableidx = 0,
                    .offset_expr = expr,
                    .elem_type = .funcref,
                    .funcidxs = funcs,
                };
            },
            2 => {
                // active, explicit tableidx, offset_expr, elemkind,
                // vec(funcidx).
                const tableidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                if (pos >= body.len) return sections.Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return sections.Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{
                    .kind = .active,
                    .tableidx = tableidx,
                    .offset_expr = expr,
                    .elem_type = FUNCIDX_ELEM_TYPE,
                    .funcidxs = funcs,
                };
            },
            5 => {
                // passive, reftype, vec(reftype-expr).
                // function-references: element reftype may be any
                // reftype incl. typed `(ref null? $t)` — shared reader.
                const reftype_vt = init_expr.readRefType(body, &pos) catch |err| switch (err) {
                    error.UnexpectedEnd => return sections.Error.UnexpectedEnd,
                    else => return sections.Error.InvalidFunctype,
                };
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                // 10.G cycle 164 — discriminate by the first item's opcode.
                // WasmGC general const-expr items (array.new / struct.new …)
                // start with 0xFB; ref.func / ref.null / global.get / i31
                // (0xD2 / 0xD0 / 0x23 / 0x41) take the legacy funcidx reader.
                // gc/array.8: `(elem (ref $bvec) (array.new …) (array.new_fixed …))`.
                if (n > 0 and itemIsGeneralConstExpr(body, pos)) {
                    const exprs = try alloc.alloc([]const u8, n);
                    for (exprs) |*ex| {
                        const s = pos;
                        try init_expr.scanInitExpr(body, &pos);
                        ex.* = body[s..pos];
                    }
                    e.* = .{ .kind = .passive, .elem_type = reftype_vt, .item_exprs = exprs };
                } else {
                    const funcs = try alloc.alloc(u32, n);
                    for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, reftype_vt);
                    e.* = .{ .kind = .passive, .elem_type = reftype_vt, .funcidxs = funcs };
                }
            },
            6 => {
                // active, explicit tableidx, offset_expr, reftype,
                // vec(reftype-expr).
                const tableidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                // function-references: element reftype may be any
                // reftype incl. typed `(ref null? $t)` — shared reader.
                const reftype_vt = init_expr.readRefType(body, &pos) catch |err| switch (err) {
                    error.UnexpectedEnd => return sections.Error.UnexpectedEnd,
                    else => return sections.Error.InvalidFunctype,
                };
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, reftype_vt);
                e.* = .{
                    .kind = .active,
                    .tableidx = tableidx,
                    .offset_expr = expr,
                    .elem_type = reftype_vt,
                    .funcidxs = funcs,
                };
            },
            7 => {
                // declarative, reftype, vec(reftype-expr).
                // function-references: element reftype may be any
                // reftype incl. typed `(ref null? $t)` — shared reader.
                const reftype_vt = init_expr.readRefType(body, &pos) catch |err| switch (err) {
                    error.UnexpectedEnd => return sections.Error.UnexpectedEnd,
                    else => return sections.Error.InvalidFunctype,
                };
                const n = try leb128.readUleb128(u32, body, &pos);
                try sections.checkVecCount(n, body, pos); // ≥1 byte/elem — reject oversized count pre-alloc
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, reftype_vt);
                e.* = .{ .kind = .declarative, .elem_type = reftype_vt, .funcidxs = funcs };
            },
            else => return sections.Error.InvalidFunctype,
        }
    }

    if (pos != body.len) return sections.Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

/// Decode one funcref/externref init expression appearing in
/// element-section form 4 / 5 / 6 / 7. Supports per Wasm spec
/// §3.3.2.10 const-expr: `ref.func F; end` (0xD2 LEB128(F) 0x0B),
/// `ref.null t; end` (0xD0 0x70|0x6F 0x0B), and `global.get N;
/// end` (0x23 LEB128(N) 0x0B).
///
/// Encoding in funcidx slot:
/// - `ref.func F`: funcidx = F (assumed F < 0x80000000 which holds
///   for any realistic module — F is bound by total_funcs).
/// - `ref.null t`: funcidx = `std.math.maxInt(u32)` (null sentinel).
/// - `global.get N`: funcidx = `0x80000000 | N` (top-bit marker;
///   close-plan §6 (j) Step B cohort 6). Table-init then reads
///   the imported funcref global value at `scratch_globals[
///   globals_offsets[N]]` and substitutes it as the table entry.
fn readFuncrefInitExpr(body: []const u8, pos: *usize, expected: ValType) sections.Error!u32 {
    if (pos.* >= body.len) return sections.Error.UnexpectedEnd;
    const op = body[pos.*];
    pos.* += 1;
    const idx: u32 = switch (op) {
        0xD2 => blk: {
            // ref.func produces a (typed) funcref; valid when the
            // segment's reftype is in the func family — abstract `func`
            // (any nullability) or a concrete typed func ref `(ref $sig)`
            // (pre-GC every concrete type is a func type; ref_is_null.0
            // elem 1: `(ref 0)` with `ref.func 0`). Reject externref /
            // other heads (elem.51: ref.func into an externref segment).
            const ok = expected == .ref and switch (expected.ref.heap_type) {
                .abstract => |a| a == .func,
                .concrete => true,
            };
            if (!ok) return sections.Error.InvalidFunctype;
            break :blk try leb128.readUleb128(u32, body, pos);
        },
        0xD0 => blk: {
            // ref.null <heaptype>: the heaptype may be ANY abstract head
            // (func/extern/any/eq/i31/struct/array/none/noextern/nofunc/exn),
            // not just func/extern, AND the heaptype may be a CONCRETE typeidx
            // (`(ref.null $t)` = 0xD0 + s33 typeidx), not just an abstract head.
            // readTypedRef decodes the heaptype directly (abstract head byte OR
            // non-negative s33 concrete index) → `(ref null ht)`; a plain
            // readValType only handled the abstract heads (whose bytes coincide
            // with reftype shorthands) and rejected `(ref.null $t)` (D-476).
            const rt_vt = init_expr.readTypedRef(body, pos, true) catch return sections.Error.BadValType;
            if (!rt_vt.eql(expected)) return sections.Error.InvalidFunctype;
            break :blk std.math.maxInt(u32);
        },
        0x23 => blk: {
            // global.get produces the imported global's type. Strict
            // per-global type check is deferred to compileWasm
            // (validator owns the globals index space); decoder only
            // ensures the marker is structurally valid.
            const n = try leb128.readUleb128(u32, body, pos);
            if (n >= 0x80000000) return sections.Error.InvalidFunctype;
            break :blk 0x80000000 | n;
        },
        0x41 => blk: {
            // Wasm 3.0 GC: `i32.const N; ref.i31` constant expr for an
            // i31ref / anyref / eqref element segment. The slot holds the
            // i31-ENCODED value (not a funcidx); table-init interprets it
            // by `elem_type`. Only valid when the segment's reftype is in
            // the i31/eq/any family (ref.i31 : (ref i31) <: eqref <: anyref).
            const head_ok = expected == .ref and switch (expected.ref.heap_type) {
                .abstract => |a| a == .i31 or a == .eq or a == .any,
                .concrete => false,
            };
            if (!head_ok) return sections.Error.InvalidFunctype;
            const n = try leb128.readSleb128(i32, body, pos);
            if (pos.* >= body.len or body[pos.*] != 0xFB) return sections.Error.InvalidFunctype;
            pos.* += 1;
            const sub = try leb128.readUleb128(u32, body, pos);
            if (sub != 28) return sections.Error.InvalidFunctype; // 0x1C = ref.i31
            break :blk i31_enc.i32ToI31Truncate(n);
        },
        else => return sections.Error.InvalidFunctype,
    };
    if (pos.* >= body.len) return sections.Error.UnexpectedEnd;
    if (body[pos.*] != 0x0B) return sections.Error.InvalidFunctype;
    pos.* += 1;
    return idx;
}

/// Close-plan §6 (j) Step B cohort 6 — funcref init-expression
/// marker constants. Element segments carrying `global.get N`
/// entries encode the global index with the top bit set; consumers
/// (`applyTableInitForTable`, `populateTableRefs`) detect this and
/// resolve via `GlobalsCtx`.
pub const ELEM_GLOBAL_GET_MARKER: u32 = 0x80000000;
pub fn elemEntryIsGlobalGet(funcidx: u32) bool {
    return (funcidx & ELEM_GLOBAL_GET_MARKER) != 0 and funcidx != std.math.maxInt(u32);
}
pub fn elemEntryGlobalIdx(funcidx: u32) u32 {
    return funcidx & 0x7FFFFFFF;
}

const testing = std.testing;

test "decodeElement: empty section" {
    var e = try decodeElement(testing.allocator, &[_]u8{0x00});
    defer e.deinit();
    try testing.expectEqual(@as(usize, 0), e.items.len);
}

test "decodeElement: single active form 0 with two funcidxs" {
    // count=1; flag=0; offset_expr = i32.const 5 ; end; n=2; funcs=[0,1]
    const body = [_]u8{
        0x01,
        0x00,
        0x41,
        0x05,
        0x0B,
        0x02,
        0x00,
        0x01,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 0), e.items[0].tableidx);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, e.items[0].funcidxs);
    // The funcidx form's items are `ref.func`, so its element type is the
    // NON-NULLABLE `(ref func)` — not the nullable `funcref` this used to
    // record for every shape. A `(ref func)` table accepts this segment
    // precisely because of the nullability here.
    try testing.expect(e.items[0].elem_type.eql(.{ .ref = zir.RefType.abs(.func, false) }));
}

test "decodeElement: form 6 typed-ref (ref 0) elem with ref.func init expr" {
    // ref_is_null.0 elem 1: active, tableidx, offset, reftype (ref 0),
    // vec [ref.func 0]. `ref.func` produces a typed funcref that must
    // satisfy the concrete (ref 0) segment type (not just abstract
    // funcref). count=1; flag=6; tableidx=0; offset=i32.const 0;end;
    // reftype=(ref 0)=0x64 0x00; n=1; expr=ref.func 0;end.
    const body = [_]u8{ 0x01, 0x06, 0x00, 0x41, 0x00, 0x0B, 0x64, 0x00, 0x01, 0xD2, 0x00, 0x0B };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expect(e.items[0].elem_type == .ref);
    try testing.expect(e.items[0].elem_type.ref.heap_type == .concrete);
    try testing.expectEqualSlices(u32, &[_]u32{0}, e.items[0].funcidxs);
}

test "decodeElement: passive form 1 with elemkind=funcref" {
    // count=1; flag=1; elemkind=0x00; n=1; funcs=[3]
    const body = [_]u8{ 0x01, 0x01, 0x00, 0x01, 0x03 };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.passive, e.items[0].kind);
    try testing.expectEqualSlices(u32, &[_]u32{3}, e.items[0].funcidxs);
}

test "decodeElement: declarative form 3" {
    const body = [_]u8{ 0x01, 0x03, 0x00, 0x00 };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.declarative, e.items[0].kind);
    try testing.expectEqual(@as(usize, 0), e.items[0].funcidxs.len);
}

test "decodeElement: active form 2 with explicit tableidx" {
    // Per Wasm 2.0 §5.5.12: flag=2, tableidx (uleb), offset_expr,
    // elemkind, vec(funcidx).
    // count=1; flag=2; tableidx=1; offset = i32.const 0; end;
    // elemkind=0x00; n=2; funcs=[0,1]
    const body = [_]u8{
        0x01,
        0x02,
        0x01,
        0x41,
        0x00,
        0x0B,
        0x00,
        0x02,
        0x00,
        0x01,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 1), e.items[0].tableidx);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, e.items[0].funcidxs);
}

test "decodeElement: passive form 5 (reftype + expr-vec)" {
    // Per Wasm 2.0 §5.5.12: flag=5, reftype, vec(reftype-expr).
    // count=1; flag=5; reftype=0x70 (funcref); n=2;
    // expr0 = ref.func 7; end; expr1 = ref.null funcref; end
    const body = [_]u8{
        0x01,
        0x05,
        0x70,
        0x02,
        0xD2,
        0x07,
        0x0B,
        0xD0,
        0x70,
        0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.passive, e.items[0].kind);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{ 7, std.math.maxInt(u32) }, e.items[0].funcidxs);
}

test "decodeElement: active form 6 (tableidx + offset + reftype + expr-vec)" {
    // Per Wasm 2.0 §5.5.12: flag=6, tableidx, offset_expr,
    // reftype, vec(reftype-expr).
    // count=1; flag=6; tableidx=2; offset = i32.const 4; end;
    // reftype=0x70; n=1; expr = ref.func 3; end
    const body = [_]u8{
        0x01,
        0x06,
        0x02,
        0x41,
        0x04,
        0x0B,
        0x70,
        0x01,
        0xD2,
        0x03,
        0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 2), e.items[0].tableidx);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{3}, e.items[0].funcidxs);
}

test "decodeElement: declarative form 7 (reftype + expr-vec)" {
    // Per Wasm 2.0 §5.5.12: flag=7, reftype, vec(reftype-expr).
    // count=1; flag=7; reftype=0x70; n=1; expr = ref.func 0; end
    const body = [_]u8{
        0x01,
        0x07,
        0x70,
        0x01,
        0xD2,
        0x00,
        0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.declarative, e.items[0].kind);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{0}, e.items[0].funcidxs);
}

test "decodeElement: form 6 i31ref segment with ref.i31 init (10.G cycle 131)" {
    // 1 segment: active form 6, table 0, offset i32.const 0, elemtype
    // i31ref (0x6C), 1 init expr `i32.const 42; ref.i31; end`.
    const body = [_]u8{
        0x01, // count
        0x06, 0x00, // flag 6, tableidx 0
        0x41, 0x00, 0x0B, // offset: i32.const 0; end
        0x6C, // elemtype: i31ref
        0x01, // n = 1
        0x41, 0x2A, 0xFB, 0x1C, 0x0B, // i32.const 42; ref.i31; end
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ValType.i31ref, e.items[0].elem_type);
    // The funcidxs slot holds the i31-ENCODED value (table-init reads it
    // as a ref value by elem_type, NOT as a funcidx).
    try testing.expectEqualSlices(u32, &[_]u32{i31_enc.i32ToI31Truncate(42)}, e.items[0].funcidxs);
}
