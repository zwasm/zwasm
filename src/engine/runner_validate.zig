//! Setup-time const-expression evaluation for the JIT runner,
//! extracted from `runner.zig` per ADR-0064. Self-contained: takes
//! `expr: []const u8` (and optional context) → returns a typed
//! result or a tagged error.
//!
//! Evaluation only (i32 / scalar-as-u64 / v128 16-byte payload). A
//! const expression's *validity* is the shared validator's verdict
//! (`validate/validator_helpers.zig:validateConstExpr`, Wasm 3.0
//! §3.3.13.1), which `compile.zig` consults; an expression this
//! module cannot evaluate is a capability decline
//! (`UnsupportedConstExpr` / `UnsupportedEntrySignature`), never a
//! validity verdict (#397).
//!
//! Zone 2 (`src/engine/`); imports Zone 0 (`leb128`) and Zone 1
//! (`ir/zir`) only.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");

/// Errors originating in this module. Subset of `runner.Error`;
/// merged in via `runner.Error = ... || runner_validate.Error || ...`.
pub const Error = error{
    /// Const-expression decode failed at the scalar / v128
    /// helper level (mostly: truncated body, unknown opcode,
    /// missing trailing `end`). The runner upgrades this to
    /// `Error.UnsupportedEntrySignature` for setup-time const
    /// init paths.
    UnsupportedEntrySignature,
    /// `evalConstI32Expr` reached a shape it doesn't decode
    /// (anything besides `i32.const N; end`). Active data /
    /// elem offset_expr resolution surfaces this in the
    /// runner.
    UnsupportedConstExpr,
};

/// §9.9 / 9.9-l-1b-d093-d82 — extract the funcidx from a global
/// init-expression of shape `ref.func N; end`. Returns `null`
/// for any other shape (i32.const, ref.null, global.get of
/// import, SIMD v128.const, or a malformed expression). Used by
/// `compileWasm` to seed the declared-funcrefs bitset per Wasm
/// spec §3.4.10. The full validity check (range, trailing
/// `end`, type match) is the shared validator's
/// (`validateConstExpr`); this helper is best-effort extraction only.
pub fn initExprRefFunc(expr: []const u8) ?u32 {
    if (expr.len < 3) return null;
    if (expr[0] != 0xD2) return null;
    var pos: usize = 1;
    const idx = leb128.readUleb128(u32, expr, &pos) catch return null;
    if (pos >= expr.len or expr[pos] != 0x0B) return null;
    return idx;
}

/// Context for resolving `global.get N` inside a const-expression
/// during init-time (active data offset, active elem offset,
/// defined-global init). `buf` is the importer-side globals buffer;
/// the caller pre-populates the slots the expression may read
/// before invoking any eval helper below. When `ctx` is `null`, the
/// helpers behave as before — `global.get` reaches the `else`
/// arm and returns `UnsupportedConstExpr` / `UnsupportedEntrySignature`.
pub const GlobalsCtx = struct {
    offsets: []const u32,
    valtypes: []const zir.ValType,
    buf: []const u8,
    /// Slots `[0, num_imports)` hold the resolved import values; a
    /// reference there is a real `FuncEntity` pointer.
    num_imports: u32,
    /// `global.get N` reads a slot only when `N < readable` — the
    /// window Wasm 3.0 §3.3.13.1 gives the expression's position:
    /// the imports plus the globals defined before it for a global
    /// init, and whatever the caller has evaluated so far for an
    /// active offset. Never above `offsets.len`.
    readable: u32,
};

/// Decode a scalar const-expression's raw bits as a u64. Used by
/// setupRuntime to initialise defined-global slots from their
/// init_expr. Returns `Error.UnsupportedEntrySignature` for
/// shapes not yet supported (the const-expr corpus consumed by
/// the Wasm 2.0 spec runner is finite — i32/i64/f32/f64.const,
/// ref.null, ref.func, v128.const is handled by the separate
/// `evalConstV128Expr`). `global.get N` reads a slot inside
/// `ctx.readable` when `ctx` is non-null (close-plan §6 (j) Step B
/// cohort 1; the defined-global window since #397).
pub fn evalConstScalarRaw(expr: []const u8) Error!u64 {
    return evalConstScalarRawCtx(expr, null);
}

pub fn evalConstScalarRawCtx(expr: []const u8, ctx: ?GlobalsCtx) Error!u64 {
    if (expr.len < 2) return Error.UnsupportedEntrySignature;
    var pos: usize = 1;
    const v: u64 = switch (expr[0]) {
        0x41 => blk: { // i32.const
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            const u: u32 = @bitCast(n);
            break :blk @as(u64, u);
        },
        0x42 => blk: { // i64.const
            const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedEntrySignature;
            break :blk @bitCast(n);
        },
        0x43 => blk: { // f32.const
            if (pos + 4 > expr.len) return Error.UnsupportedEntrySignature;
            const bits = std.mem.readInt(u32, expr[pos..][0..4], .little);
            pos += 4;
            break :blk @as(u64, bits);
        },
        0x44 => blk: { // f64.const
            if (pos + 8 > expr.len) return Error.UnsupportedEntrySignature;
            const bits = std.mem.readInt(u64, expr[pos..][0..8], .little);
            pos += 8;
            break :blk bits;
        },
        0xD0 => blk: { // ref.null reftype
            if (pos >= expr.len) return Error.UnsupportedEntrySignature;
            pos += 1;
            break :blk 0;
        },
        0xD2 => blk: { // ref.func funcidx — Wasm 2.0 §5.4.3
            // Encode as the funcidx itself. Runtime-side funcref
            // resolution (turning funcidx into a JIT entry ptr)
            // is Phase 10+ scope; the spec corpus modules that
            // EXPORT a reftype global via `ref.func` are
            // currently only imported by cross-module fixtures
            // that the d-37 unbindable-imports pre-filter
            // SKIPs, so the stored value is never read by any
            // assertion in the Wasm 2.0 corpus.
            const fidx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            break :blk @as(u64, fidx);
        },
        0x23 => blk: { // global.get N — close-plan §6 (j) Step B cohort 1
            const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            const c = ctx orelse return Error.UnsupportedEntrySignature;
            if (idx >= c.readable) return Error.UnsupportedEntrySignature;
            if (idx >= c.offsets.len or idx >= c.valtypes.len) return Error.UnsupportedEntrySignature;
            // v128 globals are not scalar — caller must dispatch v128 init
            // via `evalConstV128Expr` instead. Reject early.
            if (c.valtypes[idx] == .v128) return Error.UnsupportedEntrySignature;
            // A defined reference global's slot may still hold the
            // `ref.func` funcidx placeholder (`resolveFuncrefGlobals`
            // runs after this pass and rewrites only the globals whose
            // own init is `ref.func`), so copying it would carry the
            // placeholder past the resolver. Decline rather than copy.
            if (idx >= c.num_imports and c.valtypes[idx] == .ref) return Error.UnsupportedEntrySignature;
            // Post-ADR-0110 widen: every slot occupies uniform 16 bytes;
            // scalar values live in the low 8 bytes (little-endian).
            const off = c.offsets[idx];
            if (off + 8 > c.buf.len) return Error.UnsupportedEntrySignature;
            break :blk std.mem.readInt(u64, c.buf[off..][0..8], .little);
        },
        else => return Error.UnsupportedEntrySignature,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedEntrySignature;
    return v;
}

/// Decode a `v128.const` (0xFD 0x0C) terminated init-expression
/// and return the 16-byte little-endian-encoded constant.
pub fn evalConstV128Expr(expr: []const u8) Error!([16]u8) {
    // (v128.const v128) (end) — 0xFD 0x0C <16 bytes> 0x0B
    if (expr.len < 2 + 16 + 1) return Error.UnsupportedEntrySignature;
    if (expr[0] != 0xFD or expr[1] != 0x0C) return Error.UnsupportedEntrySignature;
    if (expr[18] != 0x0B) return Error.UnsupportedEntrySignature;
    var out: [16]u8 = undefined;
    @memcpy(&out, expr[2..][0..16]);
    return out;
}

/// Evaluate a Wasm const-expression that resolves to an i32.
/// Active data-segment offsets reach this path; v0.1.0's only
/// supported shape is `i32.const N; end` (3+ bytes: opcode 0x41,
/// sleb128 N, opcode 0x0B). Mirrors the shape in
/// `runtime/instance/instantiate.zig:evalConstI32Expr` but stays
/// JIT-runner-local to avoid pulling instance/ into engine/.
pub fn evalConstI32Expr(expr: []const u8) Error!i32 {
    return evalConstI32ExprCtx(expr, null);
}

/// Context-aware variant per close-plan §6 (j) Step B cohort 1.
/// Accepts the `global.get N` shape (opcode 0x23) for a slot inside
/// `ctx.readable` when `ctx` is non-null. The importer-side
/// `ctx.buf` must be pre-populated with each readable global's
/// value (see spec runner's `applyImportedGlobalsFromRegistered`).
pub fn evalConstI32ExprCtx(expr: []const u8, ctx: ?GlobalsCtx) Error!i32 {
    if (expr.len < 2) return Error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v: i32 = switch (expr[0]) {
        0x41 => blk: { // i32.const
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedConstExpr;
            break :blk n;
        },
        0x23 => blk: { // global.get N
            const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedConstExpr;
            const c = ctx orelse return Error.UnsupportedConstExpr;
            if (idx >= c.readable) return Error.UnsupportedConstExpr;
            if (idx >= c.offsets.len or idx >= c.valtypes.len) return Error.UnsupportedConstExpr;
            if (c.valtypes[idx] != .i32) return Error.UnsupportedConstExpr;
            const off = c.offsets[idx];
            if (off + 4 > c.buf.len) return Error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u32, c.buf[off..][0..4], .little);
            break :blk @bitCast(bits);
        },
        else => return Error.UnsupportedConstExpr,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedConstExpr;
    return v;
}

/// Context-aware u64 offset evaluator (D-475 table64). Mirrors
/// `evalConstI32ExprCtx`'s single-op shape but returns u64: accepts
/// `i32.const` (zero-extended), `i64.const` (table64 / memory64), and
/// `global.get N` of a readable i32 (zero-extended) or i64 global when
/// `ctx` is non-null.
pub fn evalConstOffsetU64Ctx(expr: []const u8, ctx: ?GlobalsCtx) Error!u64 {
    if (expr.len < 2) return Error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v: u64 = switch (expr[0]) {
        0x41 => blk: { // i32.const — zero-extend
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedConstExpr;
            break :blk @as(u32, @bitCast(n));
        },
        0x42 => blk: { // i64.const (table64 / memory64)
            const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedConstExpr;
            break :blk @bitCast(n);
        },
        0x23 => blk: { // global.get N (imported i32 / i64)
            const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedConstExpr;
            const c = ctx orelse return Error.UnsupportedConstExpr;
            if (idx >= c.readable) return Error.UnsupportedConstExpr;
            if (idx >= c.offsets.len or idx >= c.valtypes.len) return Error.UnsupportedConstExpr;
            const off = c.offsets[idx];
            switch (c.valtypes[idx]) {
                .i32 => {
                    if (off + 4 > c.buf.len) return Error.UnsupportedConstExpr;
                    break :blk std.mem.readInt(u32, c.buf[off..][0..4], .little);
                },
                .i64 => {
                    if (off + 8 > c.buf.len) return Error.UnsupportedConstExpr;
                    break :blk std.mem.readInt(u64, c.buf[off..][0..8], .little);
                },
                else => return Error.UnsupportedConstExpr,
            }
        },
        else => return Error.UnsupportedConstExpr,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedConstExpr;
    return v;
}

/// Evaluate an active-segment offset const-expr to a u64. Accepts
/// `i32.const` (mem32 / table — zero-extended) and `i64.const`
/// (memory64), each followed by `end`. An offset is unsigned; the
/// caller's bounds check rejects out-of-range values. D-219.
pub fn evalConstOffsetU64(expr: []const u8) Error!u64 {
    // Small const-expr stack machine: i32/i64.const + the extended-const
    // proposal's i32/i64 add/sub/mul (Wasm 3.0). A computed active data/element
    // offset like `(i32.add (i32.const 4) (i32.const 6))` is valid. i32 values
    // are kept zero-extended in the u64 slot; i32 arithmetic wraps at 32 bits.
    var stack: [16]u64 = undefined;
    var sp: usize = 0;
    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        if (op == 0x0B) break;
        switch (op) {
            0x41 => { // i32.const
                const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedConstExpr;
                if (sp >= stack.len) return Error.UnsupportedConstExpr;
                stack[sp] = @as(u32, @bitCast(n));
                sp += 1;
            },
            0x42 => { // i64.const (memory64)
                const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedConstExpr;
                if (sp >= stack.len) return Error.UnsupportedConstExpr;
                stack[sp] = @bitCast(n);
                sp += 1;
            },
            0x6A, 0x6B, 0x6C => { // i32 add/sub/mul — 32-bit wrapping
                if (sp < 2) return Error.UnsupportedConstExpr;
                sp -= 1;
                const a: u32 = @truncate(stack[sp - 1]);
                const b: u32 = @truncate(stack[sp]);
                stack[sp - 1] = switch (op) {
                    0x6A => a +% b,
                    0x6B => a -% b,
                    else => a *% b,
                };
            },
            0x7C, 0x7D, 0x7E => { // i64 add/sub/mul — 64-bit wrapping
                if (sp < 2) return Error.UnsupportedConstExpr;
                sp -= 1;
                const a = stack[sp - 1];
                const b = stack[sp];
                stack[sp - 1] = switch (op) {
                    0x7C => a +% b,
                    0x7D => a -% b,
                    else => a *% b,
                };
            },
            else => return Error.UnsupportedConstExpr,
        }
    }
    if (sp != 1) return Error.UnsupportedConstExpr;
    return stack[0];
}
