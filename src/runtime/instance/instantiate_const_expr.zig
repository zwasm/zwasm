//! Const-expression evaluators extracted from `instantiate.zig` to keep that
//! file under its size cap (the marker's planned extraction). Pure byte→value
//! helpers (Wasm §3.4 const-expr): single-value (`evalConstExprValue`),
//! GC-aware global init (`evalGlobalInitGc`), and the i32 / memory-address
//! (i32|i64) offset evaluators. They take bytes + GC heap / globals as params
//! and touch NO Instance state — a separable sub-language. `instantiate.zig`
//! re-exports each so external callers keep using `instantiate.<fn>` unchanged.
//!
//! SIBLING-PUB: the `pub` fns are consumed by the sibling `instantiate.zig`
//! (which re-exports them) + its callers; the pub-ness is an extraction
//! artifact, not a wide public API surface.
const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const sections = @import("../../parse/sections.zig");
const leb128 = @import("../../support/leb128.zig");
const heap_mod = @import("../../feature/gc/heap.zig");
const type_info_mod = @import("../../feature/gc/type_info.zig");

const Value = runtime_mod.Value;
const FuncEntity = runtime_mod.FuncEntity;

/// Evaluate a global init-expression and return the initial Value.
/// Supported shapes for v0.1.0: `<i32|i64|f32|f64>.const N; end`,
/// `ref.null funcref|externref; end`, and Wasm 2.0 `v128.const
/// b0..b15; end` (post-ADR-0110 §9.13-V Phase A.4f; closes D-169).
/// `global.get N` (importing from another module's globals) defers
/// with the rest of cross-module global imports. Every byte of the
/// result is defined: the value's own bytes, zero above them, since
/// every arm builds it with a `Value.from*` constructor.
pub fn evalConstExprValue(expr: []const u8) !Value {
    if (expr.len < 2) return error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v: Value = switch (expr[0]) {
        0x41 => blk: {
            const n = try leb128.readSleb128(i32, expr, &pos);
            break :blk Value.fromI32(n);
        },
        0x42 => blk: {
            const n = try leb128.readSleb128(i64, expr, &pos);
            break :blk Value.fromI64(n);
        },
        0x43 => blk: {
            if (pos + 4 > expr.len) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u32, expr[pos..][0..4], .little);
            pos += 4;
            break :blk Value.fromF32Bits(bits);
        },
        0x44 => blk: {
            if (pos + 8 > expr.len) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u64, expr[pos..][0..8], .little);
            pos += 8;
            break :blk Value.fromF64Bits(bits);
        },
        0xD0 => blk: {
            if (pos >= expr.len) return error.UnsupportedConstExpr;
            pos += 1;
            break :blk Value.fromRef(Value.null_ref);
        },
        // Wasm 2.0 SIMD prefix — currently only `v128.const`
        // (sub-opcode 0x0C) is a valid const-expression op (per
        // Wasm 2.0 §3.5.4 + ADR-0110 D-169 discharge).
        0xFD => blk: {
            if (pos >= expr.len) return error.UnsupportedConstExpr;
            const sub = expr[pos];
            pos += 1;
            if (sub != 0x0C) return error.UnsupportedConstExpr;
            if (pos + 16 > expr.len) return error.UnsupportedConstExpr;
            var bytes: [16]u8 = undefined;
            @memcpy(&bytes, expr[pos..][0..16]);
            pos += 16;
            break :blk Value.fromV128(bytes);
        },
        else => return error.UnsupportedConstExpr,
    };
    // Wasm 3.0 GC: `ref.i31` (0xFB 0x1C) is a constant-expression op —
    // it wraps a preceding `i32.const N` into a non-null `(ref i31)`.
    // (struct.new / array.new const exprs need heap alloc → later chunk.)
    var result = v;
    if (pos < expr.len and expr[pos] == 0xFB) {
        pos += 1;
        const sub = try leb128.readUleb128(u32, expr, &pos);
        if (sub != 28) return error.UnsupportedConstExpr; // 0x1C = ref.i31
        result = Value.fromI31Truncate(result.i32);
    }
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return result;
}

/// Evaluate a Wasm 3.0 GC `struct.new` / `array.new` constant expression
/// at instantiation (§3.5.10 const-expr extension). The global-init loop
/// falls here when `evalConstExprValue` rejects with
/// `UnsupportedConstExpr`. A small const-stack handles numeric consts +
/// ref.i31 + struct.new[_default] + array.new[_default]/array.new_fixed:
/// allocate on `rt.gc_heap` using the materialised Struct/ArrayInfo and
/// write the leading const operands into the object slots (mirrors
/// struct_ops.zig / array_ops.zig / ADR-0116 §3a).
/// Primitive-param form so both the interp instantiate path and the JIT
/// setup path (`engine/setup.zig`) can evaluate GC const-expr globals
/// without coupling engine → Instance. `gc_heap` / `gc_type_infos` are
/// nullable; a GC const-expr op on a module without them rejects with
/// `UnsupportedConstExpr` (D-223).
pub fn evalGlobalInitGc(
    expr: []const u8,
    gc_heap: ?*heap_mod.Heap,
    gc_type_infos: ?type_info_mod.GcTypeInfos,
    func_entities: []FuncEntity,
    imported_globals: []const *Value,
) anyerror!Value {
    const type_info = @import("../../feature/gc/type_info.zig");
    const header_size: u32 = @sizeOf(type_info.ObjectHeader);
    var stack: [16]Value = undefined;
    var sp: usize = 0;
    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        if (op == 0x0B) break;
        if (sp >= stack.len) return error.UnsupportedConstExpr;
        switch (op) {
            0x41 => {
                stack[sp] = Value.fromI32(try leb128.readSleb128(i32, expr, &pos));
                sp += 1;
            },
            0x42 => {
                stack[sp] = Value.fromI64(try leb128.readSleb128(i64, expr, &pos));
                sp += 1;
            },
            0x43 => {
                if (pos + 4 > expr.len) return error.UnsupportedConstExpr;
                stack[sp] = Value.fromF32Bits(std.mem.readInt(u32, expr[pos..][0..4], .little));
                pos += 4;
                sp += 1;
            },
            0x44 => {
                if (pos + 8 > expr.len) return error.UnsupportedConstExpr;
                stack[sp] = Value.fromF64Bits(std.mem.readInt(u64, expr[pos..][0..8], .little));
                pos += 8;
                sp += 1;
            },
            // Extended-const proposal (Wasm 3.0): i32/i64 add/sub/mul evaluate at
            // instantiation with WRAPPING arithmetic (spec §4.4.8 binop). Pop two,
            // push the result. evalConstExprValue defers the multi-instruction
            // form here via its UnsupportedConstExpr fallback.
            0x6A, 0x6B, 0x6C => { // i32.add / i32.sub / i32.mul
                if (sp < 2) return error.UnsupportedConstExpr;
                sp -= 1;
                const a = stack[sp - 1].i32;
                const b = stack[sp].i32;
                stack[sp - 1] = Value.fromI32(switch (op) {
                    0x6A => a +% b,
                    0x6B => a -% b,
                    else => a *% b,
                });
            },
            0x7C, 0x7D, 0x7E => { // i64.add / i64.sub / i64.mul
                if (sp < 2) return error.UnsupportedConstExpr;
                sp -= 1;
                const a = stack[sp - 1].i64;
                const b = stack[sp].i64;
                stack[sp - 1] = Value.fromI64(switch (op) {
                    0x7C => a +% b,
                    0x7D => a -% b,
                    else => a *% b,
                });
            },
            0xFD => { // SIMD prefix — only v128.const (sub 0x0C) is constant
                // (Wasm 2.0 §3.5.4). Needed for a v128 GC aggregate field/
                // element initialised in a const-expr (D-460).
                const sub = try leb128.readUleb128(u32, expr, &pos);
                if (sub != 0x0C) return error.UnsupportedConstExpr;
                if (pos + 16 > expr.len) return error.UnsupportedConstExpr;
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, expr[pos..][0..16]);
                pos += 16;
                stack[sp] = Value.fromV128(bytes);
                sp += 1;
            },
            0x23 => { // global.get N — Wasm §3.5.10 const-expr; read an
                // already-evaluated prior global (imported or earlier-
                // defined). i31.wast $i31ref_of_global_global_initializer:
                // `(global i31ref (ref.i31 (global.get $g)))`.
                const gidx = try leb128.readUleb128(u32, expr, &pos);
                if (gidx >= imported_globals.len) return error.UnsupportedConstExpr;
                stack[sp] = imported_globals[gidx].*;
                sp += 1;
            },
            0xD2 => { // ref.func N — Wasm §3.5.10 const-expr; push funcref
                // Value resolved against rt.func_entities (mirrors the
                // simple-global ref.func path + element-init above). Needed
                // when ref.func feeds a GC const-expr, e.g. array.init_elem.3
                // `(array.new $arrref (ref.func $dummy) (i32.const 12))`.
                const fidx = try leb128.readUleb128(u32, expr, &pos);
                if (fidx >= func_entities.len) return error.UnsupportedConstExpr;
                stack[sp] = Value.fromFuncRef(&func_entities[fidx]);
                sp += 1;
            },
            0xFB => {
                const sub = try leb128.readUleb128(u32, expr, &pos);
                switch (sub) {
                    28 => { // ref.i31: wrap the preceding i32 const
                        if (sp == 0) return error.UnsupportedConstExpr;
                        stack[sp - 1] = Value.fromI31Truncate(stack[sp - 1].i32);
                    },
                    0, 1 => { // struct.new / struct.new_default
                        const typeidx = try leb128.readUleb128(u32, expr, &pos);
                        const gti = gc_type_infos orelse return error.UnsupportedConstExpr;
                        if (typeidx >= gti.struct_infos.len) return error.UnsupportedConstExpr;
                        const si = gti.struct_infos[typeidx] orelse return error.UnsupportedConstExpr;
                        const heap = gc_heap orelse return error.UnsupportedConstExpr;
                        const ref = try heap.allocate(header_size + si.payload_size);
                        const hdr: type_info.ObjectHeader = .{ .kind = .struct_, .info = typeidx };
                        @memcpy(heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr));
                        if (sub == 0) {
                            // Fields are on the const-stack in declared order;
                            // write top-down so field[i] gets its operand.
                            var i: usize = si.type_info.field_count;
                            while (i > 0) {
                                i -= 1;
                                if (sp == 0) return error.UnsupportedConstExpr;
                                sp -= 1;
                                const off = ref + header_size + si.fields[i].offset;
                                const fsz = si.fields[i].size; // 8 scalar/ref, 16 v128 (D-460)
                                @memcpy(heap.bytes[off .. off + fsz], std.mem.asBytes(&stack[sp])[0..fsz]);
                            }
                        }
                        stack[sp] = Value.fromRef(ref);
                        sp += 1;
                    },
                    6, 7 => { // array.new / array.new_default
                        const typeidx = try leb128.readUleb128(u32, expr, &pos);
                        const gti = gc_type_infos orelse return error.UnsupportedConstExpr;
                        if (typeidx >= gti.array_infos.len) return error.UnsupportedConstExpr;
                        const ai = gti.array_infos[typeidx] orelse return error.UnsupportedConstExpr;
                        const heap = gc_heap orelse return error.UnsupportedConstExpr;
                        const ahs: u32 = @sizeOf(type_info.ArrayHeader);
                        // Stack (top first): size:i32, then init value (sub 6 only).
                        if (sp == 0) return error.UnsupportedConstExpr;
                        sp -= 1;
                        if (stack[sp].i32 < 0) return error.UnsupportedConstExpr;
                        const length: u32 = @intCast(stack[sp].i32);
                        var init_v: Value = Value.zero;
                        if (sub == 6) {
                            if (sp == 0) return error.UnsupportedConstExpr;
                            sp -= 1;
                            init_v = stack[sp];
                        }
                        // u64 size arithmetic: a huge `array.new*` length (here
                        // from a global const-expr) overflows the u32 product
                        // before Heap.allocate's 4 GiB cap fires → trap OutOfHeap
                        // instead of an integer-overflow panic (wasmtime gc/
                        // array-alloc-too-large). Mirrors object_alloc.allocArrayObject.
                        const total_u64: u64 = @as(u64, ahs) + @as(u64, length) * @as(u64, ai.element.size);
                        if (total_u64 > std.math.maxInt(u32)) return error.OutOfHeap;
                        const ref = try heap.allocate(@intCast(total_u64));
                        const ah: type_info.ArrayHeader = .{ .header = .{ .kind = .array, .info = typeidx }, .length = length };
                        @memcpy(heap.bytes[ref .. ref + ahs], std.mem.asBytes(&ah)[0..ahs]);
                        var k: u32 = 0;
                        while (k < length) : (k += 1) {
                            const off = ref + ahs + k * @as(u32, ai.element.size);
                            if (sub == 6) {
                                @memcpy(heap.bytes[off .. off + ai.element.size], std.mem.asBytes(&init_v)[0..ai.element.size]);
                            } else {
                                @memset(heap.bytes[off .. off + ai.element.size], 0);
                            }
                        }
                        stack[sp] = Value.fromRef(ref);
                        sp += 1;
                    },
                    26, 27 => {}, // any.convert_extern / extern.convert_any:
                    // Wasm 3.0 §3.5.10 constant ops; externref≡anyref in zwasm's
                    // tagged repr so the conversion is pure identity (mirrors
                    // codegen emit.zig). Value on the const-stack is unchanged.
                    8 => { // array.new_fixed $t N
                        const typeidx = try leb128.readUleb128(u32, expr, &pos);
                        const nlen = try leb128.readUleb128(u32, expr, &pos);
                        const gti = gc_type_infos orelse return error.UnsupportedConstExpr;
                        if (typeidx >= gti.array_infos.len) return error.UnsupportedConstExpr;
                        const ai = gti.array_infos[typeidx] orelse return error.UnsupportedConstExpr;
                        const heap = gc_heap orelse return error.UnsupportedConstExpr;
                        const ahs: u32 = @sizeOf(type_info.ArrayHeader);
                        const ref = try heap.allocate(ahs + nlen * @as(u32, ai.element.size));
                        const ah: type_info.ArrayHeader = .{ .header = .{ .kind = .array, .info = typeidx }, .length = nlen };
                        @memcpy(heap.bytes[ref .. ref + ahs], std.mem.asBytes(&ah)[0..ahs]);
                        var k: u32 = nlen;
                        while (k > 0) {
                            k -= 1;
                            if (sp == 0) return error.UnsupportedConstExpr;
                            sp -= 1;
                            const off = ref + ahs + k * @as(u32, ai.element.size);
                            @memcpy(heap.bytes[off .. off + ai.element.size], std.mem.asBytes(&stack[sp])[0..ai.element.size]);
                        }
                        stack[sp] = Value.fromRef(ref);
                        sp += 1;
                    },
                    else => return error.UnsupportedConstExpr,
                }
            },
            else => return error.UnsupportedConstExpr,
        }
    }
    if (sp == 0) return error.UnsupportedConstExpr;
    return stack[sp - 1];
}

/// Evaluate a Wasm const-expression that resolves to an i32.
/// Active data-segment offsets currently reach this path; the
/// only shape v0.1.0 needs is `i32.const N; end` (3+ bytes:
/// opcode 0x41, sleb128 N, opcode 0x0B).
pub fn evalConstI32Expr(expr: []const u8) !i32 {
    // i32 const-expr stack machine: i32.const + the extended-const proposal's
    // i32 add/sub/mul (Wasm 3.0). A computed active element/data offset like
    // `(i32.add (i32.const 4) (i32.const 6))` is valid; arithmetic wraps.
    var stack: [16]i32 = undefined;
    var sp: usize = 0;
    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        if (op == 0x0B) break;
        switch (op) {
            0x41 => {
                if (sp >= stack.len) return error.UnsupportedConstExpr;
                stack[sp] = try leb128.readSleb128(i32, expr, &pos);
                sp += 1;
            },
            0x6A, 0x6B, 0x6C => {
                if (sp < 2) return error.UnsupportedConstExpr;
                sp -= 1;
                const a = stack[sp - 1];
                const b = stack[sp];
                stack[sp - 1] = switch (op) {
                    0x6A => a +% b,
                    0x6B => a -% b,
                    else => a *% b,
                };
            },
            else => return error.UnsupportedConstExpr,
        }
    }
    if (sp != 1) return error.UnsupportedConstExpr;
    return stack[0];
}

/// Wasm spec §3.4.7 — active data segment offset's result type
/// matches the target memory's idx_type. memory64 modules emit
/// `i64.const N; end` (opcode 0x42) for offsets; legacy i32
/// memories emit `i32.const N; end` (opcode 0x41). Returns the
/// offset as `u64` so the caller can range-check against the
/// memory's byte length uniformly.
pub fn evalConstMemAddrExpr(
    expr: []const u8,
    idx_type: sections.MemoryEntry.IdxType,
) !u64 {
    return evalConstMemAddrExprWithGlobals(expr, idx_type, &.{});
}

/// 10.M-D195b cycle 78 — accepts `global.get N` (opcode 0x23) in
/// addition to the const-int shapes. The N index is into the
/// importer's `rt.globals` slice (post-import-binding). Spec testsuite
/// fixtures like `multi-memory/data0.{3,5}.wasm` declare
/// `(data (global.get 0) "a")` against an imported `spectest.global_i32`
/// global, hitting this path after the cycle-77 Linker.defineGlobal
/// wiring resolves the import.
pub fn evalConstMemAddrExprWithGlobals(
    expr: []const u8,
    idx_type: sections.MemoryEntry.IdxType,
    globals: []const *Value,
) !u64 {
    if (expr.len < 2) return error.UnsupportedConstExpr;
    switch (expr[0]) {
        0x23 => { // global.get N
            var pos: usize = 1;
            const idx = leb128.readUleb128(u32, expr, &pos) catch return error.UnsupportedConstExpr;
            if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
            if (idx >= globals.len) return error.UnsupportedConstExpr;
            const cell = globals[idx].*;
            return switch (idx_type) {
                .i32 => @as(u64, @intCast(@as(u32, @bitCast(cell.i32)))),
                .i64 => @bitCast(cell.i64),
            };
        },
        else => switch (idx_type) {
            .i32 => return @as(u64, @intCast(@as(u32, @bitCast(try evalConstI32Expr(expr))))),
            .i64 => {
                // i64 const-expr stack machine: i64.const + extended-const
                // i64 add/sub/mul (memory64 offsets), mirroring evalConstI32Expr.
                var stack: [16]i64 = undefined;
                var sp: usize = 0;
                var pos: usize = 0;
                while (pos < expr.len) {
                    const op = expr[pos];
                    pos += 1;
                    if (op == 0x0B) break;
                    switch (op) {
                        0x42 => {
                            if (sp >= stack.len) return error.UnsupportedConstExpr;
                            stack[sp] = try leb128.readSleb128(i64, expr, &pos);
                            sp += 1;
                        },
                        0x7C, 0x7D, 0x7E => {
                            if (sp < 2) return error.UnsupportedConstExpr;
                            sp -= 1;
                            const a = stack[sp - 1];
                            const b = stack[sp];
                            stack[sp - 1] = switch (op) {
                                0x7C => a +% b,
                                0x7D => a -% b,
                                else => a *% b,
                            };
                        },
                        else => return error.UnsupportedConstExpr,
                    }
                }
                if (sp != 1) return error.UnsupportedConstExpr;
                return @bitCast(stack[0]);
            },
        },
    }
}

const testing = std.testing;

/// Fill the stack below the caller's frame with `pattern`, so a callee
/// that leaves a byte undefined returns whatever the pattern put there.
noinline fn dirtyStack(pattern: u8) void {
    var buf: [4096]u8 = undefined;
    @memset(&buf, pattern);
    std.mem.doNotOptimizeAway(&buf);
}

/// The 16 bytes a value of `x`'s type defines: `x` little-endian, then zero.
fn definedBytes(x: anytype) [16]u8 {
    var out: [16]u8 = @splat(0);
    const T = @TypeOf(x);
    std.mem.writeInt(T, out[0..@sizeOf(T)], x, .little);
    return out;
}

test "evalConstExprValue: all 16 bytes of the result are the type's, the rest zero" {
    const v128_bytes = [16]u8{ 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF };
    const cases = [_]struct { expr: []const u8, want: [16]u8 }{
        .{ .expr = &.{ 0x41, 0x7E, 0x0B }, .want = definedBytes(@as(i32, -2)) }, // i32.const -2
        .{ .expr = &.{ 0x42, 0x7E, 0x0B }, .want = definedBytes(@as(i64, -2)) }, // i64.const -2
        .{ .expr = &.{ 0x43, 0x00, 0x00, 0x80, 0xBF, 0x0B }, .want = definedBytes(@as(u32, 0xBF80_0000)) }, // f32.const -1
        .{ .expr = &.{ 0x44, 0, 0, 0, 0, 0, 0, 0xF0, 0xBF, 0x0B }, .want = definedBytes(@as(u64, 0xBFF0_0000_0000_0000)) }, // f64.const -1
        .{ .expr = &([_]u8{ 0xFD, 0x0C } ++ v128_bytes ++ [_]u8{0x0B}), .want = v128_bytes }, // v128.const
        .{ .expr = &.{ 0xD0, 0x70, 0x0B }, .want = definedBytes(@as(u64, 0)) }, // ref.null func
        .{ .expr = &.{ 0xD0, 0x6F, 0x0B }, .want = definedBytes(@as(u64, 0)) }, // ref.null extern
        .{ .expr = &.{ 0x41, 0x2A, 0xFB, 0x1C, 0x0B }, .want = definedBytes(@as(u64, (42 << 1) | 1)) }, // ref.i31 (i32.const 42)
    };
    for (cases) |c| for ([_]u8{ 0x00, 0xA5, 0xFF }) |pattern| {
        dirtyStack(pattern);
        const v = try evalConstExprValue(c.expr);
        try testing.expectEqualSlices(u8, &c.want, &v.v128);
    };
}

test "evalGlobalInitGc: all 16 bytes of the result are the type's, the rest zero" {
    const cases = [_]struct { expr: []const u8, want: [16]u8 }{
        .{ .expr = &.{ 0x41, 40, 0x41, 2, 0x6A, 0x0B }, .want = definedBytes(@as(i32, 42)) }, // i32.add
        .{ .expr = &.{ 0x42, 0x7E, 0x42, 7, 0x7E, 0x0B }, .want = definedBytes(@as(i64, -14)) }, // i64.mul
        .{ .expr = &.{ 0x43, 0x00, 0x00, 0x80, 0xBF, 0x0B }, .want = definedBytes(@as(u32, 0xBF80_0000)) }, // f32.const -1
        .{ .expr = &.{ 0x41, 0x05, 0xFB, 0x1C, 0xFB, 0x1B, 0x0B }, .want = definedBytes(@as(u64, (5 << 1) | 1)) }, // extern.convert_any (ref.i31 5)
    };
    for (cases) |c| for ([_]u8{ 0x00, 0xA5, 0xFF }) |pattern| {
        dirtyStack(pattern);
        const v = try evalGlobalInitGc(c.expr, null, null, &.{}, &.{});
        try testing.expectEqualSlices(u8, &c.want, &v.v128);
    };
}
