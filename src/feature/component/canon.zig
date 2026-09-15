// FILE-SIZE-EXEMPT: verified P1 seam (flatten surface → canon_flat.zig) SCHEDULED post-v2.5.0 as D-580 — the split is planned, not rejected (triage 2026-08-12, per ADR-0099)
//! Canonical ABI **lift/lower + memory layout** (spec
//! `component-model/design/mvp/CanonicalABI.md`). Design: ADR-0171 / ADR-0183.
//!
//! Lifts/lowers component-level values across the core/component boundary. A
//! component `Value` is DISTINCT from `runtime.Value` (`single_slot_dual_meaning`):
//! it carries interface semantics (a `char` is a Unicode scalar). The flat
//! lowered form of a scalar IS `runtime.Value` (`lower`/`lift`); aggregates are
//! laid out in guest linear memory (`store`/`load`).
//!
//! Coverage: flat scalars · enum/flags + size/align/discriminant · utf8 string
//! over memory · recursive `store`/`load` for list/record/variant · the
//! multi-value flat lowering for fn-call params (`flattenType`/`lowerFlat`/
//! `liftFlat`) · the decoded-`TypeInfo`→`CanonType` bridge · resource handle
//! own/borrow (D-322) · utf16 / latin1+utf16 string encodings (D-502).
//!
//! The realloc callback is INJECTED (vtable pattern, `zone_deps`): canon.zig
//! never imports the core runtime's instance/invoke; the orchestration layer
//! (B6) installs a callback that runs the guest's `cabi_realloc` export. Only
//! `runtime.Value` (the flattened core value type) is imported here.

const std = @import("std");

const types = @import("types.zig");
const core = @import("../../runtime/value.zig");

pub const CoreValue = core.Value;
const PrimValType = types.PrimValType;

/// A component-level runtime value: flat scalars, enum/flags, and the
/// aggregate forms (string / list / record / variant). `list`/`record` borrow
/// their element/field slices from the caller (or an arena on load).
pub const Value = union(enum) {
    bool: bool,
    s8: i8,
    u8: u8,
    s16: i16,
    u16: u16,
    s32: i32,
    u32: u32,
    s64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    char: u21,
    /// `enum` value = the case index (`0..len(labels)`).
    enum_value: u32,
    /// `flags` value = a packed bit-set (bit `i` ⇔ label `i`; ≤32 bits).
    flags: u32,
    string: []const u8,
    list: []const Value,
    /// `record` fields, positional (parallel to the `CanonType.record` fields).
    record: []const Value,
    /// `variant` value: the selected case index + its optional payload.
    variant: VariantValue,
    /// A resource HANDLE (own/borrow) — a component-table index (D-322).
    handle: u32,
};

/// A `variant`/`option`/`result` value: which case, and the (optional) payload.
pub const VariantValue = struct {
    case: u32,
    payload: ?*const Value,
};

/// The despecialized value type the canonical ABI computes layout over:
/// primitives + enum + flags + the recursive `list` / `record` / `variant`
/// forms (option/result/tuple despecialize into variant/record).
pub const CanonType = union(enum) {
    prim: PrimValType,
    /// number of enum cases (`> 0`).
    enum_: u32,
    /// number of flags labels (`0 < n <= 32`).
    flags: u32,
    /// variable-length list of an element type.
    list: *const CanonType,
    record: []const Field,
    /// tagged union of cases (option/result/tuple despecialize to this/record).
    variant: []const VCase,
    /// `own<i>` — an owning handle to resource type-space index `i` (D-322).
    own: u32,
    /// `borrow<i>` — a borrowed handle (lowered to the REP when the callee
    /// component owns the resource type — `CanonicalABI.md` lower_borrow).
    borrow: u32,
    /// `stream<T>` — an async stream handle (the readable end; element type
    /// `T`, or null for `stream`). ABI: a single i32 table-index handle, like
    /// `own`. The async read/write/state runtime is WASI-0.3 Unit D.
    stream: ?*const CanonType,
    /// `future<T>` — an async single-shot handle (value type `T`, or null).
    /// ABI: a single i32 handle, like `own`.
    future: ?*const CanonType,

    pub const Field = struct {
        name: []const u8,
        ty: CanonType,
    };

    pub const VCase = struct {
        name: []const u8,
        payload: ?CanonType,
    };
};

/// The core wasm type a flat primitive flattens to (`CanonicalABI.md`
/// flattening). Aggregates flatten to a sequence of these (later chunks).
pub const CoreType = enum { i32, i64, f32, f64 };

pub fn flatCoreType(p: PrimValType) ?CoreType {
    return switch (p) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => .i32,
        .s64, .u64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        // string / error-context are aggregate (ptr+len) — not a flat scalar.
        .string, .error_context => null,
    };
}

/// In-memory alignment of a primitive (`CanonicalABI.md` `alignment`).
fn primAlignment(p: PrimValType) usize {
    return switch (p) {
        .bool, .s8, .u8 => 1,
        .s16, .u16 => 2,
        .s32, .u32, .f32, .char, .error_context => 4,
        .s64, .u64, .f64 => 8,
        .string => 4, // ptr alignment (32-bit core memory)
    };
}

/// In-memory size of a primitive (`CanonicalABI.md` `elem_size`). For scalars
/// size == alignment; string is a (ptr,len) pair.
fn primSize(p: PrimValType) usize {
    return switch (p) {
        .string => 8, // 2 * ptr_size
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .error_context => primAlignment(p),
    };
}

/// Smallest integer width (bytes) covering `n` enum/variant cases
/// (`CanonicalABI.md` `discriminant_type`): ≤256→1, ≤65536→2, else 4.
pub fn discriminantSize(n_cases: u32) usize {
    if (n_cases <= 256) return 1;
    if (n_cases <= 65536) return 2;
    return 4;
}

/// Packed `flags` byte width (`CanonicalABI.md` `alignment_flags`/
/// `elem_size_flags`): ≤8→1, ≤16→2, else 4 (n is capped at 32).
pub fn flagsSize(n_labels: u32) usize {
    if (n_labels <= 8) return 1;
    if (n_labels <= 16) return 2;
    return 4;
}

/// `align_to(ptr, a)` (`CanonicalABI.md`): round `ptr` up to a multiple of `a`.
pub fn alignTo(ptr: usize, a: usize) usize {
    return (ptr + a - 1) / a * a;
}

/// Max alignment over a variant's case payloads (`max_case_alignment`); 1 if
/// no case carries a payload.
fn maxCaseAlignment(cases: []const CanonType.VCase) usize {
    var a: usize = 1;
    for (cases) |c| {
        if (c.payload) |p| a = @max(a, alignmentOf(p));
    }
    return a;
}

/// In-memory alignment of a value type (recursive).
pub fn alignmentOf(t: CanonType) usize {
    return switch (t) {
        .own, .borrow, .stream, .future => 4,
        .prim => |p| primAlignment(p),
        .enum_ => |n| discriminantSize(n),
        .flags => |n| flagsSize(n),
        .list => 4, // (ptr, len) → ptr alignment
        .record => |fields| blk: {
            var a: usize = 1;
            for (fields) |f| a = @max(a, alignmentOf(f.ty));
            break :blk a;
        },
        .variant => |cases| @max(discriminantSize(@intCast(cases.len)), maxCaseAlignment(cases)),
    };
}

/// In-memory size of a value type (recursive; `CanonicalABI.md` `elem_size`).
pub fn sizeOf(t: CanonType) usize {
    return switch (t) {
        .own, .borrow, .stream, .future => 4,
        .prim => |p| primSize(p),
        .enum_ => |n| discriminantSize(n),
        .flags => |n| flagsSize(n),
        .list => 8, // ptr + len
        .record => |fields| blk: {
            var s: usize = 0;
            for (fields) |f| {
                s = alignTo(s, alignmentOf(f.ty));
                s += sizeOf(f.ty);
            }
            break :blk alignTo(s, alignmentOf(t));
        },
        .variant => |cases| blk: {
            var s = discriminantSize(@intCast(cases.len));
            s = alignTo(s, maxCaseAlignment(cases));
            var cs: usize = 0;
            for (cases) |c| {
                if (c.payload) |p| cs = @max(cs, sizeOf(p));
            }
            break :blk alignTo(s + cs, alignmentOf(t));
        },
    };
}

pub const ReallocError = error{ AllocFailed, OutOfBounds };

/// Spec `cabi_realloc` contract: `(old_ptr, old_size, alignment, new_size) ->
/// new_ptr`. Injected by the orchestration layer (B6) to invoke the guest's
/// `cabi_realloc` export so allocation runs in the guest's own allocator
/// (ADR-0171). An error result signals OOM / trap.
pub const ReallocFn = *const fn (ctx: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) ReallocError!u32;

/// Guest string encoding (`canonopt` `string-encoding`). All three are
/// implemented at the canon lift/lower layer (D-502).
pub const StringEncoding = enum { utf8, utf16, latin1_utf16 };

/// Per-call canonical-ABI context: the guest linear memory (lift/lower target),
/// the injected realloc callback, and the string encoding option.
pub const CanonContext = struct {
    /// Guest linear memory is RE-FETCHED on every access (`mem()`): a
    /// `cabi_realloc` call may grow/move the backing mid-`store` (the
    /// nested-list staleness bug this closure shape fixes — a cached
    /// slice dangles after a moving grow).
    memory_ctx: *anyopaque,
    memory_fn: *const fn (*anyopaque) []u8,
    realloc_ctx: *anyopaque,
    realloc_fn: ReallocFn,
    string_encoding: StringEncoding = .utf8,
    /// OPTIONAL resource hook (D-322): translate a borrow HANDLE of
    /// resource type-space index `ti` to its REP — `CanonicalABI.md`
    /// lower_borrow's owner-component direct-rep rule. Null when the
    /// embedding has no guest resources in play.
    resource_ctx: ?*anyopaque = null,
    borrow_rep_fn: ?*const fn (*anyopaque, ti: u32, handle: u32) BorrowRepError!u32 = null,

    pub fn mem(self: CanonContext) []u8 {
        return self.memory_fn(self.memory_ctx);
    }

    pub fn realloc(self: CanonContext, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) ReallocError!u32 {
        return self.realloc_fn(self.realloc_ctx, old_ptr, old_size, alignment, new_size);
    }

    pub fn borrowRep(self: CanonContext, ti: u32, handle: u32) BorrowRepError!u32 {
        const f = self.borrow_rep_fn orelse return BorrowRepError.NoResourceContext;
        return f(self.resource_ctx.?, ti, handle);
    }

    /// Test/fixed-buffer constructor half: a `memory_fn` reading a stable
    /// `*[]u8` holder (tests update the holder when their buffer "grows").
    pub fn sliceMemoryFn(p: *anyopaque) []u8 {
        const holder: *[]u8 = @ptrCast(@alignCast(p));
        return holder.*;
    }
};

pub const BorrowRepError = error{ NoResourceContext, InvalidHandle };

/// `CanonicalABI.md` `MAX_STRING_BYTE_LENGTH` — a string's byte length must fit
/// 28 bits (leaves the high bit free as the latin1/utf16 tag).
pub const MAX_STRING_BYTE_LENGTH: u32 = (1 << 28) - 1;

/// `CanonicalABI.md` UTF16_TAG — bit 31 of the packed length. Set on a
/// latin1+utf16 string that had to be stored as utf16 (a code point ≥ 0x100);
/// clear means the payload is latin1 (1 byte per code point).
pub const UTF16_TAG: u32 = 1 << 31;

pub const LoweredString = struct { ptr: u32, packed_length: u32 };

pub const StringError = error{
    OutOfBounds,
    InvalidUtf8,
    /// A lone/mismatched UTF-16 surrogate encountered while lifting a utf16 /
    /// latin1+utf16 guest string.
    InvalidUtf16,
    StringTooLong,
    /// The host arena allocation backing a lifted (transcoded) string failed.
    OutOfMemory,
    /// A `string-encoding` a higher layer (e.g. `invokeStringExport`) doesn't
    /// yet thread through; the canon codec itself supports all three encodings.
    UnsupportedEncoding,
} || ReallocError;

/// Lower a host UTF-8 string into guest memory per the component's declared
/// `string-encoding` (`CanonicalABI.md` `store_string`). The host source is
/// ALWAYS validated UTF-8, so this is the 3-destination subset of the spec
/// (utf8 → {utf8, utf16, latin1+utf16}); there is no utf16-source machinery.
/// Returns the `(ptr, packed_length)` pair the canonical ABI flattens to two i32s.
pub fn lowerString(cx: CanonContext, s: []const u8) StringError!LoweredString {
    return switch (cx.string_encoding) {
        .utf8 => lowerUtf8(cx, s),
        .utf16 => lowerUtf16(cx, s),
        .latin1_utf16 => lowerLatin1OrUtf16(cx, s),
    };
}

/// utf8 dest: copy bytes verbatim, align 1, `packed_length == byte_length`.
fn lowerUtf8(cx: CanonContext, s: []const u8) StringError!LoweredString {
    if (s.len > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
    const byte_len: u32 = @intCast(s.len);
    const ptr = try cx.realloc(0, 0, 1, byte_len);
    if (@as(usize, ptr) + s.len > cx.mem().len) return StringError.OutOfBounds;
    @memcpy(cx.mem()[ptr..][0..s.len], s);
    return .{ .ptr = ptr, .packed_length = byte_len };
}

/// utf16 dest (`store_utf8_to_utf16`): host UTF-8 is validated, so the exact
/// code-unit count is known up front (no worst-case-alloc + shrink). align 2,
/// `packed_length == code_units` (no tag).
fn lowerUtf16(cx: CanonContext, s: []const u8) StringError!LoweredString {
    const units = std.unicode.calcUtf16LeLen(s) catch return StringError.InvalidUtf8;
    if (units > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
    const code_units: u32 = @intCast(units);
    const byte_len = code_units * 2;
    const ptr = try cx.realloc(0, 0, 2, byte_len);
    if (@as(usize, ptr) + byte_len > cx.mem().len) return StringError.OutOfBounds;
    writeUtf16LeInto(cx.mem()[ptr..][0..byte_len], s);
    return .{ .ptr = ptr, .packed_length = code_units };
}

/// latin1+utf16 dest (`store_string_to_latin1_or_utf16`): latin1 (1 byte/char)
/// iff every code point < 0x100, else utf16 with `UTF16_TAG` set. We SCAN the
/// source first — the observable result (bytes + packed length) is identical to
/// the spec's in-place inflate, with fewer footguns.
fn lowerLatin1OrUtf16(cx: CanonContext, s: []const u8) StringError!LoweredString {
    if (!std.unicode.utf8ValidateSlice(s)) return StringError.InvalidUtf8;
    var latin1_able = true;
    var n_cps: usize = 0;
    var scan = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (scan.nextCodepoint()) |cp| {
        n_cps += 1;
        if (cp >= 0x100) {
            latin1_able = false;
            break;
        }
    }
    if (latin1_able) {
        if (n_cps > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
        const byte_len: u32 = @intCast(n_cps);
        const ptr = try cx.realloc(0, 0, 2, byte_len);
        if (@as(usize, ptr) + byte_len > cx.mem().len) return StringError.OutOfBounds;
        var w: usize = ptr;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| : (w += 1) cx.mem()[w] = @intCast(cp); // cp < 0x100
        return .{ .ptr = ptr, .packed_length = byte_len };
    }
    const units = std.unicode.calcUtf16LeLen(s) catch return StringError.InvalidUtf8;
    if (units > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
    const code_units: u32 = @intCast(units);
    const byte_len = code_units * 2;
    const ptr = try cx.realloc(0, 0, 2, byte_len);
    if (@as(usize, ptr) + byte_len > cx.mem().len) return StringError.OutOfBounds;
    writeUtf16LeInto(cx.mem()[ptr..][0..byte_len], s);
    return .{ .ptr = ptr, .packed_length = code_units | UTF16_TAG };
}

/// Transcode validated UTF-8 `s` into UTF-16LE bytes in `dst` (len == 2×units).
/// Alignment-safe: `writeInt` is byte-wise, so a merely 2-aligned guest ptr is fine.
fn writeUtf16LeInto(dst: []u8, s: []const u8) void {
    var w: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            std.mem.writeInt(u16, dst[w..][0..2], @intCast(cp), .little);
            w += 2;
        } else {
            const c = cp - 0x10000;
            const hi: u16 = @intCast(0xD800 + (c >> 10));
            const lo: u16 = @intCast(0xDC00 + (c & 0x3FF));
            std.mem.writeInt(u16, dst[w..][0..2], hi, .little);
            std.mem.writeInt(u16, dst[w + 2 ..][0..2], lo, .little);
            w += 4;
        }
    }
}

/// Lift a guest string into HOST UTF-8 per the component's `string-encoding`
/// (`CanonicalABI.md` `load_string_from_range`). The result is ALWAYS allocated
/// from `arena` (uniform ownership): utf8 is validated + copied; utf16 /
/// latin1+utf16 are transcoded. (utf8 alone could borrow guest memory, but the
/// two non-utf8 encodings MUST allocate to transcode, so a uniform arena-owned
/// contract avoids a mixed borrow/owned return the callers would have to reason
/// about.)
pub fn liftString(cx: CanonContext, arena: std.mem.Allocator, ptr: u32, packed_length: u32) StringError![]u8 {
    switch (cx.string_encoding) {
        .utf8 => {
            const byte_length = packed_length; // code units == bytes, no tag bit
            if (byte_length > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
            if (@as(usize, ptr) + byte_length > cx.mem().len) return StringError.OutOfBounds;
            const bytes = cx.mem()[ptr..][0..byte_length];
            if (!std.unicode.utf8ValidateSlice(bytes)) return StringError.InvalidUtf8;
            return arena.dupe(u8, bytes) catch return StringError.OutOfMemory;
        },
        .utf16 => return liftUtf16(cx, arena, ptr, packed_length),
        .latin1_utf16 => {
            if (packed_length & UTF16_TAG != 0)
                return liftUtf16(cx, arena, ptr, packed_length & ~UTF16_TAG);
            return liftLatin1(cx, arena, ptr, packed_length);
        },
    }
}

/// utf16 lift: `packed_length` is the code-unit count, byte_length = 2×units,
/// guest ptr must be 2-aligned. Decode UTF-16LE (surrogate pairs) → host UTF-8.
fn liftUtf16(cx: CanonContext, arena: std.mem.Allocator, ptr: u32, code_units: u32) StringError![]u8 {
    if (code_units > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
    const byte_length: usize = @as(usize, code_units) * 2;
    if (ptr % 2 != 0) return StringError.OutOfBounds; // spec: utf16 range is 2-aligned
    if (@as(usize, ptr) + byte_length > cx.mem().len) return StringError.OutOfBounds;
    const src = cx.mem()[ptr..][0..byte_length];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < byte_length) {
        const unit = std.mem.readInt(u16, src[i..][0..2], .little);
        i += 2;
        var cp: u21 = undefined;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 2 > byte_length) return StringError.InvalidUtf16; // dangling high surrogate
            const lo = std.mem.readInt(u16, src[i..][0..2], .little);
            if (lo < 0xDC00 or lo > 0xDFFF) return StringError.InvalidUtf16;
            i += 2;
            cp = 0x10000 + (@as(u21, unit - 0xD800) << 10) + (lo - 0xDC00);
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return StringError.InvalidUtf16; // lone low surrogate
        } else cp = unit;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return StringError.InvalidUtf16;
        out.appendSlice(arena, buf[0..n]) catch return StringError.OutOfMemory;
    }
    return out.toOwnedSlice(arena) catch return StringError.OutOfMemory;
}

/// latin1 lift: one byte per code point (each < 0x100 → always a valid scalar),
/// transcode to host UTF-8.
fn liftLatin1(cx: CanonContext, arena: std.mem.Allocator, ptr: u32, byte_length: u32) StringError![]u8 {
    if (byte_length > MAX_STRING_BYTE_LENGTH) return StringError.StringTooLong;
    if (@as(usize, ptr) + byte_length > cx.mem().len) return StringError.OutOfBounds;
    const src = cx.mem()[ptr..][0..byte_length];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (src) |b| {
        var buf: [2]u8 = undefined;
        const n = std.unicode.utf8Encode(@as(u21, b), &buf) catch unreachable; // b < 0x100
        out.appendSlice(arena, buf[0..n]) catch return StringError.OutOfMemory;
    }
    return out.toOwnedSlice(arena) catch return StringError.OutOfMemory;
}

pub const LiftError = error{
    /// A `char` core value outside the Unicode scalar range (`> 0x10FFFF` or a
    /// surrogate).
    InvalidChar,
    /// An enum discriminant `>= len(cases)`.
    InvalidEnum,
    /// A flags bit-set with bits set beyond the declared label count.
    InvalidFlags,
    /// Lifting an aggregate / non-flat-scalar type — use `load` / `liftFlat`.
    NotFlatScalar,
};

pub const LowerError = error{
    /// An aggregate (string/list/record) has no single-core-value flat form —
    /// it lowers to a sequence via memory (`store`) or to flats (`lowerFlat`).
    NotFlatScalar,
};

/// Lower a flat-scalar component value to its single core value
/// (`CanonicalABI.md`: signed/unsigned ints zero/sign-extend into i32/i64;
/// bool → 0/1; char → its scalar value). Aggregates error (`NotFlatScalar`).
pub fn lower(value: Value) LowerError!CoreValue {
    return switch (value) {
        .handle => |h| CoreValue.fromI32(@bitCast(h)),
        .bool => |b| CoreValue.fromI32(if (b) 1 else 0),
        .s8 => |v| CoreValue.fromI32(v),
        .u8 => |v| CoreValue.fromI32(v),
        .s16 => |v| CoreValue.fromI32(v),
        .u16 => |v| CoreValue.fromI32(v),
        .s32 => |v| CoreValue.fromI32(v),
        .u32 => |v| CoreValue.fromI32(@bitCast(v)),
        .s64 => |v| CoreValue.fromI64(v),
        .u64 => |v| CoreValue.fromI64(@bitCast(v)),
        .f32 => |v| CoreValue{ .f32 = v },
        .f64 => |v| CoreValue{ .f64 = v },
        .char => |v| CoreValue.fromI32(@intCast(v)),
        // enum + flags both flatten to a single i32 (discriminant / bit-set).
        .enum_value => |idx| CoreValue.fromI32(@bitCast(idx)),
        .flags => |bits| CoreValue.fromI32(@bitCast(bits)),
        .string, .list, .record, .variant => LowerError.NotFlatScalar,
    };
}

/// Lift a single core value back to a flat-scalar component value of type `ty`.
pub fn lift(c: CoreValue, ty: PrimValType) LiftError!Value {
    const i32_bits: u32 = @bitCast(c.i32);
    return switch (ty) {
        .bool => .{ .bool = c.i32 != 0 },
        .s8 => .{ .s8 = @bitCast(@as(u8, @truncate(i32_bits))) },
        .u8 => .{ .u8 = @truncate(i32_bits) },
        .s16 => .{ .s16 = @bitCast(@as(u16, @truncate(i32_bits))) },
        .u16 => .{ .u16 = @truncate(i32_bits) },
        .s32 => .{ .s32 = c.i32 },
        .u32 => .{ .u32 = i32_bits },
        .s64 => .{ .s64 = c.i64 },
        .u64 => .{ .u64 = @bitCast(c.i64) },
        .f32 => .{ .f32 = c.f32 },
        .f64 => .{ .f64 = c.f64 },
        .char => blk: {
            if (i32_bits > 0x10FFFF or (i32_bits >= 0xD800 and i32_bits <= 0xDFFF)) return LiftError.InvalidChar;
            break :blk .{ .char = @intCast(i32_bits) };
        },
        .string, .error_context => LiftError.NotFlatScalar,
    };
}

/// Lift a single core value to a component value of type `t`. Dispatches
/// primitives to `lift`; validates enum/flags ranges. Aggregates have no
/// single-value flat form (`NotFlatScalar`) — use `load`.
pub fn liftTyped(c: CoreValue, t: CanonType) LiftError!Value {
    return switch (t) {
        .own, .stream, .future => .{ .handle = @bitCast(c.i32) },
        .borrow => LiftError.NotFlatScalar,
        .prim => |p| lift(c, p),
        .enum_ => |n| blk: {
            const idx: u32 = @bitCast(c.i32);
            if (idx >= n) return LiftError.InvalidEnum;
            break :blk .{ .enum_value = idx };
        },
        .flags => |n| blk: {
            const bits: u32 = @bitCast(c.i32);
            // Bits beyond the declared labels must be zero (n ≤ 32).
            if (n < 32 and (bits >> @intCast(n)) != 0) return LiftError.InvalidFlags;
            break :blk .{ .flags = bits };
        },
        .list, .record, .variant => LiftError.NotFlatScalar,
    };
}

// ============================================================
// Memory store / load — the recursive canonical-ABI tree (`store`/`load`).
// ============================================================

pub const StoreError = error{ OutOfBounds, ValueTypeMismatch } || StringError;
pub const LoadError = error{ OutOfBounds, ValueTypeMismatch, OutOfMemory } || StringError || LiftError;

/// Write an integer `v` as `nbytes` little-endian at `ptr` (`store_int`).
fn storeInt(cx: CanonContext, v: u64, ptr: u32, nbytes: usize) StoreError!void {
    if (@as(usize, ptr) + nbytes > cx.mem().len) return StoreError.OutOfBounds;
    var i: usize = 0;
    while (i < nbytes) : (i += 1) cx.mem()[ptr + i] = @truncate(v >> @intCast(i * 8));
}

/// Read `nbytes` little-endian at `ptr` as an unsigned integer (`load_int`).
fn loadInt(cx: CanonContext, ptr: u32, nbytes: usize) LoadError!u64 {
    if (@as(usize, ptr) + nbytes > cx.mem().len) return LoadError.OutOfBounds;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < nbytes) : (i += 1) v |= @as(u64, cx.mem()[ptr + i]) << @intCast(i * 8);
    return v;
}

/// Store a component value into guest memory at `ptr` per its type layout
/// (`CanonicalABI.md` `store`). Recursive over list/record.
pub fn store(cx: CanonContext, value: Value, ty: CanonType, ptr: u32) StoreError!void {
    switch (ty) {
        .own, .stream, .future => {
            const h = if (value == .handle) value.handle else return StoreError.ValueTypeMismatch;
            try storeInt(cx, h, ptr, 4);
        },
        .borrow => |ti| {
            const h = if (value == .handle) value.handle else return StoreError.ValueTypeMismatch;
            const rep = cx.borrowRep(ti, h) catch return StoreError.ValueTypeMismatch;
            try storeInt(cx, rep, ptr, 4);
        },
        .prim => |p| switch (p) {
            .string => {
                const s = if (value == .string) value.string else return StoreError.ValueTypeMismatch;
                const lowered = try lowerString(cx, s);
                try storeInt(cx, lowered.ptr, ptr, 4);
                try storeInt(cx, lowered.packed_length, ptr + 4, 4);
            },
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .error_context => try storeInt(cx, try scalarBits(value, p), ptr, primSize(p)),
        },
        .enum_ => |n| {
            if (value != .enum_value or value.enum_value >= n) return StoreError.ValueTypeMismatch;
            try storeInt(cx, value.enum_value, ptr, discriminantSize(n));
        },
        .flags => |n| {
            if (value != .flags) return StoreError.ValueTypeMismatch;
            try storeInt(cx, value.flags, ptr, flagsSize(n));
        },
        .list => |elem| {
            const items = if (value == .list) value.list else return StoreError.ValueTypeMismatch;
            const esize = sizeOf(elem.*);
            const ealign = alignmentOf(elem.*);
            const byte_len: u32 = @intCast(items.len * esize);
            const base = try cx.realloc(0, 0, @intCast(ealign), byte_len);
            if (@as(usize, base) + byte_len > cx.mem().len) return StoreError.OutOfBounds;
            for (items, 0..) |e, i| try store(cx, e, elem.*, base + @as(u32, @intCast(i * esize)));
            try storeInt(cx, base, ptr, 4);
            try storeInt(cx, items.len, ptr + 4, 4);
        },
        .record => |fields| {
            const vals = if (value == .record) value.record else return StoreError.ValueTypeMismatch;
            if (vals.len != fields.len) return StoreError.ValueTypeMismatch;
            var off: u32 = ptr;
            for (fields, vals) |f, v| {
                off = @intCast(alignTo(off, alignmentOf(f.ty)));
                try store(cx, v, f.ty, off);
                off += @intCast(sizeOf(f.ty));
            }
        },
        .variant => |cases| {
            const vv = if (value == .variant) value.variant else return StoreError.ValueTypeMismatch;
            if (vv.case >= cases.len) return StoreError.ValueTypeMismatch;
            const disc_size = discriminantSize(@intCast(cases.len));
            try storeInt(cx, vv.case, ptr, disc_size);
            if (cases[vv.case].payload) |pt| {
                const poff: u32 = @intCast(alignTo(@as(usize, ptr) + disc_size, maxCaseAlignment(cases)));
                const pv = vv.payload orelse return StoreError.ValueTypeMismatch;
                try store(cx, pv.*, pt, poff);
            }
        },
    }
}

/// Load a component value of type `ty` from guest memory at `ptr` (`load`).
/// list/record allocate their element/field slices from `arena`.
pub fn load(cx: CanonContext, arena: std.mem.Allocator, ty: CanonType, ptr: u32) LoadError!Value {
    switch (ty) {
        .own, .stream, .future => return .{ .handle = @truncate(try loadInt(cx, ptr, 4)) },
        .borrow => return LoadError.ValueTypeMismatch, // borrow results are spec-invalid
        .prim => |p| switch (p) {
            .string => {
                const sptr: u32 = @intCast(try loadInt(cx, ptr, 4));
                const slen: u32 = @intCast(try loadInt(cx, ptr + 4, 4));
                return .{ .string = try liftString(cx, arena, sptr, slen) };
            },
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .error_context => return lift(coreFromBits(try loadInt(cx, ptr, primSize(p)), p), p),
        },
        .enum_ => |n| {
            const disc: u32 = @intCast(try loadInt(cx, ptr, discriminantSize(n)));
            return liftTyped(CoreValue.fromI32(@bitCast(disc)), .{ .enum_ = n });
        },
        .flags => |n| {
            const bits: u32 = @intCast(try loadInt(cx, ptr, flagsSize(n)));
            return liftTyped(CoreValue.fromI32(@bitCast(bits)), .{ .flags = n });
        },
        .list => |elem| {
            const base: u32 = @intCast(try loadInt(cx, ptr, 4));
            const len: u32 = @intCast(try loadInt(cx, ptr + 4, 4));
            return loadListAt(cx, arena, elem.*, base, len);
        },
        .record => |fields| {
            const out = try arena.alloc(Value, fields.len);
            var off: u32 = ptr;
            for (fields, out) |f, *slot| {
                off = @intCast(alignTo(off, alignmentOf(f.ty)));
                slot.* = try load(cx, arena, f.ty, off);
                off += @intCast(sizeOf(f.ty));
            }
            return .{ .record = out };
        },
        .variant => |cases| {
            const disc_size = discriminantSize(@intCast(cases.len));
            const case_index: u32 = @intCast(try loadInt(cx, ptr, disc_size));
            if (case_index >= cases.len) return LoadError.ValueTypeMismatch;
            if (cases[case_index].payload) |pt| {
                const poff: u32 = @intCast(alignTo(@as(usize, ptr) + disc_size, maxCaseAlignment(cases)));
                const pv = try arena.create(Value);
                pv.* = try load(cx, arena, pt, poff);
                return .{ .variant = .{ .case = case_index, .payload = pv } };
            }
            return .{ .variant = .{ .case = case_index, .payload = null } };
        },
    }
}

/// Reconstruct the core value of primitive `p` from `nbytes` of loaded LE bits
/// (the inverse of how `store` placed them) so `lift` can decode it.
fn coreFromBits(bits: u64, p: PrimValType) CoreValue {
    return switch (p) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => CoreValue.fromI32(@bitCast(@as(u32, @truncate(bits)))),
        .s64, .u64 => CoreValue.fromI64(@bitCast(bits)),
        .f32 => CoreValue{ .f32 = @bitCast(@as(u32, @truncate(bits))) },
        .f64 => CoreValue{ .f64 = @bitCast(bits) },
        .string, .error_context => CoreValue.fromI32(0), // unreachable via load's string branch
    };
}

/// The unsigned bit pattern a scalar (non-string) primitive stores, widened to
/// u64 (LE-truncated to `primSize` by `storeInt`).
fn scalarBits(value: Value, p: PrimValType) StoreError!u64 {
    return switch (p) {
        .bool => if (value == .bool) @intFromBool(value.bool) else StoreError.ValueTypeMismatch,
        .s8 => if (value == .s8) @as(u8, @bitCast(value.s8)) else StoreError.ValueTypeMismatch,
        .u8 => if (value == .u8) value.u8 else StoreError.ValueTypeMismatch,
        .s16 => if (value == .s16) @as(u16, @bitCast(value.s16)) else StoreError.ValueTypeMismatch,
        .u16 => if (value == .u16) value.u16 else StoreError.ValueTypeMismatch,
        .s32 => if (value == .s32) @as(u32, @bitCast(value.s32)) else StoreError.ValueTypeMismatch,
        .u32 => if (value == .u32) value.u32 else StoreError.ValueTypeMismatch,
        .s64 => if (value == .s64) @as(u64, @bitCast(value.s64)) else StoreError.ValueTypeMismatch,
        .u64 => if (value == .u64) value.u64 else StoreError.ValueTypeMismatch,
        .f32 => if (value == .f32) @as(u32, @bitCast(value.f32)) else StoreError.ValueTypeMismatch,
        .f64 => if (value == .f64) @as(u64, @bitCast(value.f64)) else StoreError.ValueTypeMismatch,
        .char => if (value == .char) value.char else StoreError.ValueTypeMismatch,
        .string, .error_context => StoreError.ValueTypeMismatch,
    };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "round-trip: i32 (s32) through lower/lift" {
    const v = Value{ .s32 = 42 };
    const c = try lower(v);
    try testing.expectEqual(@as(i32, 42), c.i32);
    try testing.expectEqual(Value{ .s32 = 42 }, try lift(c, .s32));
}

test "round-trip: every flat scalar primitive" {
    const cases = [_]Value{
        .{ .bool = true }, .{ .bool = false },
        .{ .s8 = -5 },     .{ .u8 = 200 },
        .{ .s16 = -3000 }, .{ .u16 = 60000 },
        .{ .s32 = -1 },    .{ .u32 = 0xFFFF_FFFF },
        .{ .s64 = -9 },    .{ .u64 = 0xFFFF_FFFF_FFFF_FFFF },
        .{ .char = 'A' }, .{ .char = 0x1F600 }, // 😀
    };
    const tys = [_]PrimValType{
        .bool, .bool,
        .s8,   .u8,
        .s16,  .u16,
        .s32,  .u32,
        .s64,  .u64,
        .char, .char,
    };
    for (cases, tys) |v, ty| {
        try testing.expectEqual(v, try lift(try lower(v), ty));
    }
}

test "round-trip: floats preserve bits incl. NaN payload" {
    const f32v = Value{ .f32 = 3.5 };
    try testing.expectEqual(f32v, try lift(try lower(f32v), .f32));
    const f64v = Value{ .f64 = -2.25 };
    try testing.expectEqual(f64v, try lift(try lower(f64v), .f64));
}

test "lift: char out of range / surrogate rejected" {
    try testing.expectError(LiftError.InvalidChar, lift(CoreValue.fromI32(0x110000), .char));
    try testing.expectError(LiftError.InvalidChar, lift(CoreValue.fromI32(0xD800), .char));
}

test "lift: aggregate type is NotFlatScalar in B1" {
    try testing.expectError(LiftError.NotFlatScalar, lift(CoreValue.fromI32(0), .string));
}

test "flatCoreType: primitive flattening shape" {
    try testing.expectEqual(CoreType.i32, flatCoreType(.bool).?);
    try testing.expectEqual(CoreType.i32, flatCoreType(.u32).?);
    try testing.expectEqual(CoreType.i64, flatCoreType(.s64).?);
    try testing.expectEqual(CoreType.f64, flatCoreType(.f64).?);
    try testing.expectEqual(@as(?CoreType, null), flatCoreType(.string));
}

test "size/align: primitive layout matches spec" {
    try testing.expectEqual(@as(usize, 1), sizeOf(.{ .prim = .bool }));
    try testing.expectEqual(@as(usize, 1), alignmentOf(.{ .prim = .u8 }));
    try testing.expectEqual(@as(usize, 2), sizeOf(.{ .prim = .s16 }));
    try testing.expectEqual(@as(usize, 4), sizeOf(.{ .prim = .char }));
    try testing.expectEqual(@as(usize, 8), alignmentOf(.{ .prim = .u64 }));
    try testing.expectEqual(@as(usize, 8), sizeOf(.{ .prim = .f64 }));
    try testing.expectEqual(@as(usize, 8), sizeOf(.{ .prim = .string })); // (ptr,len)
}

test "discriminant width flips at 256 / 65536 boundaries" {
    try testing.expectEqual(@as(usize, 1), discriminantSize(1));
    try testing.expectEqual(@as(usize, 1), discriminantSize(256));
    try testing.expectEqual(@as(usize, 2), discriminantSize(257));
    try testing.expectEqual(@as(usize, 2), discriminantSize(65536));
    try testing.expectEqual(@as(usize, 4), discriminantSize(65537));
}

test "flags width flips at 8 / 16 boundaries" {
    try testing.expectEqual(@as(usize, 1), flagsSize(8));
    try testing.expectEqual(@as(usize, 2), flagsSize(9));
    try testing.expectEqual(@as(usize, 2), flagsSize(16));
    try testing.expectEqual(@as(usize, 4), flagsSize(17));
    try testing.expectEqual(@as(usize, 4), flagsSize(32));
}

test "round-trip: enum discriminant" {
    const v = Value{ .enum_value = 3 };
    try testing.expectEqual(@as(i32, 3), (try lower(v)).i32);
    try testing.expectEqual(v, try liftTyped(try lower(v), .{ .enum_ = 5 }));
}

test "lift: enum discriminant out of range rejected" {
    try testing.expectError(LiftError.InvalidEnum, liftTyped(CoreValue.fromI32(5), .{ .enum_ = 5 }));
}

test "round-trip: flags bit-set" {
    const v = Value{ .flags = 0b101 };
    try testing.expectEqual(@as(i32, 0b101), (try lower(v)).i32);
    try testing.expectEqual(v, try liftTyped(try lower(v), .{ .flags = 3 }));
}

test "lift: flags with bits beyond label count rejected" {
    // 3 labels → only bits 0..2 valid; bit 3 set is malformed.
    try testing.expectError(LiftError.InvalidFlags, liftTyped(CoreValue.fromI32(0b1000), .{ .flags = 3 }));
    // 32 labels → all 32 bits valid (no shift-overflow, no rejection).
    _ = try liftTyped(CoreValue.fromI32(@bitCast(@as(u32, 0xFFFF_FFFF))), .{ .flags = 32 });
}

/// A bump allocator over a `[]u8` standing in for the guest's `cabi_realloc`.
const Bump = struct {
    next: u32,
    fn realloc(ctx: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) ReallocError!u32 {
        _ = old_ptr;
        _ = old_size;
        const self: *Bump = @ptrCast(@alignCast(ctx));
        const aligned = std.mem.alignForward(u32, self.next, @max(alignment, 1));
        self.next = aligned + new_size;
        return aligned;
    }
};

test "round-trip: utf8 string guest↔host via realloc + memory" {
    var mem = [_]u8{0} ** 256;
    var bump = Bump{ .next = 8 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };

    const lowered = try lowerString(cx, "héllo, 世界"); // multibyte utf8
    try testing.expect(lowered.ptr >= 8);
    const back = try liftString(cx, testing.allocator, lowered.ptr, lowered.packed_length);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("héllo, 世界", back);
}

test "round-trip: empty string" {
    var mem = [_]u8{0} ** 16;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    const lowered = try lowerString(cx, "");
    try testing.expectEqual(@as(u32, 0), lowered.packed_length);
    const back = try liftString(cx, testing.allocator, lowered.ptr, lowered.packed_length);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("", back);
}

test "lift: out-of-bounds range rejected" {
    var mem = [_]u8{0} ** 8;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    try testing.expectError(StringError.OutOfBounds, liftString(cx, testing.allocator, 4, 100));
}

test "lift: invalid utf8 rejected" {
    var mem = [_]u8{ 0xFF, 0xFE, 0, 0, 0, 0, 0, 0 }; // 0xFF is never valid utf8
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    try testing.expectError(StringError.InvalidUtf8, liftString(cx, testing.allocator, 0, 2));
}

test "lowerString utf16: BMP + supplementary (surrogate pair)" {
    var mem = [_]u8{0} ** 32;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc, .string_encoding = .utf16 };
    // "A𐐷" = U+0041 + U+10437 (one BMP unit + a surrogate pair = 3 code units).
    const lowered = try lowerString(cx, "A\u{10437}");
    try testing.expectEqual(@as(u32, 3), lowered.packed_length); // 3 code units, no tag
    const b = mem[lowered.ptr..][0..6];
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x00, 0x01, 0xD8, 0x37, 0xDC }, b);
}

test "lowerString latin1+utf16: all-latin1 stays latin1, mixed flips to tagged utf16" {
    var mem = [_]u8{0} ** 64;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc, .string_encoding = .latin1_utf16 };
    // "Aÿ" — U+0041 + U+00FF, both < 0x100 → latin1, 1 byte each, no tag.
    const l1 = try lowerString(cx, "A\u{00FF}");
    try testing.expectEqual(@as(u32, 2), l1.packed_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0xFF }, mem[l1.ptr..][0..2]);
    // "Aλ" — U+03BB ≥ 0x100 → utf16 with UTF16_TAG, 2 code units.
    const l2 = try lowerString(cx, "A\u{03BB}");
    try testing.expectEqual(@as(u32, 2 | UTF16_TAG), l2.packed_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x00, 0xBB, 0x03 }, mem[l2.ptr..][0..4]);
}

test "round-trip utf16: host↔guest via lower + lift (incl. supplementary)" {
    var mem = [_]u8{0} ** 64;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc, .string_encoding = .utf16 };
    const s = "Aé世\u{10437}"; // 1/2/3-byte utf8 + a supplementary (surrogate-pair) code point
    const lowered = try lowerString(cx, s);
    const back = try liftString(cx, testing.allocator, lowered.ptr, lowered.packed_length);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(s, back);
}

test "round-trip latin1+utf16: latin1 path and tagged-utf16 path both survive" {
    var mem = [_]u8{0} ** 64;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc, .string_encoding = .latin1_utf16 };
    const latin1 = "A\u{00FF}"; // all < 0x100 → latin1, no tag
    const l1 = try lowerString(cx, latin1);
    try testing.expectEqual(@as(u32, 0), l1.packed_length & UTF16_TAG);
    const b1 = try liftString(cx, testing.allocator, l1.ptr, l1.packed_length);
    defer testing.allocator.free(b1);
    try testing.expectEqualStrings(latin1, b1);
    const mixed = "A\u{03BB}世"; // ≥ 0x100 → tagged utf16
    const l2 = try lowerString(cx, mixed);
    try testing.expect(l2.packed_length & UTF16_TAG != 0);
    const b2 = try liftString(cx, testing.allocator, l2.ptr, l2.packed_length);
    defer testing.allocator.free(b2);
    try testing.expectEqualStrings(mixed, b2);
}

test "lift utf16: dangling high surrogate rejected" {
    var mem = [_]u8{ 0x00, 0xD8, 0, 0, 0, 0, 0, 0 }; // lone high surrogate U+D800 (LE)
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc, .string_encoding = .utf16 };
    try testing.expectError(StringError.InvalidUtf16, liftString(cx, testing.allocator, 0, 1));
}

test "lift utf16: unaligned ptr rejected" {
    var mem = [_]u8{0} ** 8;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc, .string_encoding = .utf16 };
    try testing.expectError(StringError.OutOfBounds, liftString(cx, testing.allocator, 1, 1)); // ptr=1 not 2-aligned
}

test "store/load round-trip: list<u32>" {
    var mem = [_]u8{0} ** 256;
    var bump = Bump{ .next = 32 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };

    const elem = CanonType{ .prim = .u32 };
    const ty = CanonType{ .list = &elem };
    const items = [_]Value{ .{ .u32 = 1 }, .{ .u32 = 0xDEAD_BEEF }, .{ .u32 = 3 } };
    const v = Value{ .list = &items };

    try store(cx, v, ty, 8); // store the (ptr,len) header at offset 8

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try load(cx, arena.allocator(), ty, 8);
    try testing.expectEqual(@as(usize, 3), back.list.len);
    try testing.expectEqual(@as(u32, 1), back.list[0].u32);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), back.list[1].u32);
    try testing.expectEqual(@as(u32, 3), back.list[2].u32);
}

test "list load with an oversized length TRAPS before the eager alloc (amplification guard)" {
    var mem = [_]u8{0} ** 256;
    var bump = Bump{ .next = 32 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };

    const elem = CanonType{ .prim = .u32 };
    const ty = CanonType{ .list = &elem };
    // Forge a list header at offset 8: base=16, len=0x4000_0000 (1G elements) —
    // far beyond the 256-byte memory. Must trap (OutOfBounds), NOT attempt the
    // ~16GB `arena.alloc(Value, 1G)` an untrusted component could otherwise force.
    std.mem.writeInt(u32, mem[8..12], 16, .little);
    std.mem.writeInt(u32, mem[12..16], 0x4000_0000, .little);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.OutOfBounds, load(cx, arena.allocator(), ty, 8));
}

test "store/load round-trip: record { a: u8, b: u32, c: bool }" {
    var mem = [_]u8{0} ** 128;
    var bump = Bump{ .next = 16 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };

    const fields = [_]CanonType.Field{
        .{ .name = "a", .ty = .{ .prim = .u8 } },
        .{ .name = "b", .ty = .{ .prim = .u32 } }, // forces 3 bytes of padding after `a`
        .{ .name = "c", .ty = .{ .prim = .bool } },
    };
    const ty = CanonType{ .record = &fields };
    // record align = 4 (max field), size = align(0,1)+1 → align(1,4)=4 +4 → 8, +1 bool=9 → align(9,4)=12
    try testing.expectEqual(@as(usize, 12), sizeOf(ty));
    try testing.expectEqual(@as(usize, 4), alignmentOf(ty));

    const vals = [_]Value{ .{ .u8 = 7 }, .{ .u32 = 0xCAFE }, .{ .bool = true } };
    try store(cx, .{ .record = &vals }, ty, 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try load(cx, arena.allocator(), ty, 0);
    try testing.expectEqual(@as(u8, 7), back.record[0].u8);
    try testing.expectEqual(@as(u32, 0xCAFE), back.record[1].u32);
    try testing.expectEqual(true, back.record[2].bool);
}

test "store/load round-trip: record with a string field" {
    var mem = [_]u8{0} ** 256;
    var bump = Bump{ .next = 64 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };

    const fields = [_]CanonType.Field{
        .{ .name = "id", .ty = .{ .prim = .u32 } },
        .{ .name = "name", .ty = .{ .prim = .string } },
    };
    const ty = CanonType{ .record = &fields };
    const vals = [_]Value{ .{ .u32 = 42 }, .{ .string = "zwasm" } };
    try store(cx, .{ .record = &vals }, ty, 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try load(cx, arena.allocator(), ty, 0);
    try testing.expectEqual(@as(u32, 42), back.record[0].u32);
    try testing.expectEqualStrings("zwasm", back.record[1].string);
}

test "store: value/type mismatch rejected" {
    var mem = [_]u8{0} ** 16;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    // a u32 type with a bool value
    try testing.expectError(StoreError.ValueTypeMismatch, store(cx, .{ .bool = true }, .{ .prim = .u32 }, 0));
}

test "lower: aggregate value has no flat scalar form" {
    try testing.expectError(LowerError.NotFlatScalar, lower(.{ .string = "x" }));
}

test "store/load round-trip: variant (option<u32> shape, some case)" {
    var mem = [_]u8{0} ** 64;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    const cases = [_]CanonType.VCase{
        .{ .name = "none", .payload = null },
        .{ .name = "some", .payload = .{ .prim = .u32 } },
    };
    const ty = CanonType{ .variant = &cases };
    // disc 1 → align(1,4)=4 + payload 4 = 8 → align(8,4)=8
    try testing.expectEqual(@as(usize, 8), sizeOf(ty));
    try testing.expectEqual(@as(usize, 4), alignmentOf(ty));

    const payload = Value{ .u32 = 42 };
    try store(cx, .{ .variant = .{ .case = 1, .payload = &payload } }, ty, 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try load(cx, arena.allocator(), ty, 0);
    try testing.expectEqual(@as(u32, 1), back.variant.case);
    try testing.expectEqual(@as(u32, 42), back.variant.payload.?.u32);
}

test "store/load round-trip: variant none case (no payload)" {
    var mem = [_]u8{0} ** 16;
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    const cases = [_]CanonType.VCase{
        .{ .name = "none", .payload = null },
        .{ .name = "some", .payload = .{ .prim = .u32 } },
    };
    try store(cx, .{ .variant = .{ .case = 0, .payload = null } }, .{ .variant = &cases }, 0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try load(cx, arena.allocator(), .{ .variant = &cases }, 0);
    try testing.expectEqual(@as(u32, 0), back.variant.case);
    try testing.expectEqual(@as(?*const Value, null), back.variant.payload);
}

test "store/load round-trip: result<u32, string> (err case)" {
    var mem = [_]u8{0} ** 128;
    var bump = Bump{ .next = 16 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    const cases = [_]CanonType.VCase{
        .{ .name = "ok", .payload = .{ .prim = .u32 } },
        .{ .name = "err", .payload = .{ .prim = .string } },
    };
    const ty = CanonType{ .variant = &cases };
    try testing.expectEqual(@as(usize, 12), sizeOf(ty)); // disc→4 + max(4,8)=8

    const payload = Value{ .string = "oops" };
    try store(cx, .{ .variant = .{ .case = 1, .payload = &payload } }, ty, 0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try load(cx, arena.allocator(), ty, 0);
    try testing.expectEqual(@as(u32, 1), back.variant.case);
    try testing.expectEqualStrings("oops", back.variant.payload.?.string);
}

test "variant: out-of-range case index on load rejected" {
    var mem = [_]u8{0} ** 16;
    mem[0] = 5; // disc says case 5, but only 2 cases
    var bump = Bump{ .next = 0 };
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    const cases = [_]CanonType.VCase{ .{ .name = "a", .payload = null }, .{ .name = "b", .payload = null } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(LoadError.ValueTypeMismatch, load(cx, arena.allocator(), .{ .variant = &cases }, 0));
}

test "CanonContext.realloc delegates to the injected callback" {
    const Mock = struct {
        fn realloc(ctx: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) ReallocError!u32 {
            _ = ctx;
            _ = old_ptr;
            _ = old_size;
            _ = alignment;
            // A trivial bump that just echoes new_size as the address.
            return new_size;
        }
    };
    var dummy_mem = [_]u8{0} ** 16;
    var dummy_slice: []u8 = &dummy_mem;
    var sentinel: u8 = 0;
    const ctx = CanonContext{
        .memory_ctx = @ptrCast(&dummy_slice),
        .memory_fn = CanonContext.sliceMemoryFn,
        .realloc_ctx = @ptrCast(&sentinel),
        .realloc_fn = Mock.realloc,
    };
    try testing.expectEqual(@as(u32, 64), try ctx.realloc(0, 0, 4, 64));
}

// ============================================================
// Call flattening (ADR-0183 F2) — CanonicalABI `flatten_type` /
// `lower_flat` / `lift_flat` for fn-call argument/result passing.
// ============================================================

/// `CanonicalABI.md` flat-arity caps: params beyond 16 flats spill to a
/// memory tuple; results beyond 1 flat return via a guest return-area ptr.
pub const MAX_FLAT_PARAMS = 16;
pub const MAX_FLAT_RESULTS = 1;

pub const FlattenError = std.mem.Allocator.Error;

/// CanonicalABI `flatten_type` — append `t`'s flattened core types.
pub fn flattenType(alloc: std.mem.Allocator, t: CanonType, out: *std.ArrayList(CoreType)) FlattenError!void {
    switch (t) {
        .prim => |p| switch (p) {
            .string, .error_context => try out.appendSlice(alloc, &.{ .i32, .i32 }),
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char => try out.append(alloc, flatCoreType(p).?),
        },
        .enum_, .flags, .own, .borrow, .stream, .future => try out.append(alloc, .i32),
        .list => try out.appendSlice(alloc, &.{ .i32, .i32 }),
        .record => |fields| for (fields) |f| try flattenType(alloc, f.ty, out),
        .variant => |cases| {
            try out.append(alloc, .i32); // discriminant
            var joined: std.ArrayList(CoreType) = .empty;
            defer joined.deinit(alloc);
            try joinedPayloadTypes(alloc, cases, &joined);
            try out.appendSlice(alloc, joined.items);
        },
    }
}

/// The position-wise `join` of every case payload's flat types
/// (CanonicalABI `flatten_variant`).
fn joinedPayloadTypes(alloc: std.mem.Allocator, cases: []const CanonType.VCase, joined: *std.ArrayList(CoreType)) FlattenError!void {
    var tmp: std.ArrayList(CoreType) = .empty;
    defer tmp.deinit(alloc);
    for (cases) |c| {
        const pt = c.payload orelse continue;
        tmp.clearRetainingCapacity();
        try flattenType(alloc, pt, &tmp);
        for (tmp.items, 0..) |ct, i| {
            if (i < joined.items.len) {
                joined.items[i] = join(joined.items[i], ct);
            } else {
                try joined.append(alloc, ct);
            }
        }
    }
}

/// CanonicalABI `join`: equal types keep; {i32,f32} mixes narrow to i32;
/// anything else widens to i64.
pub fn join(a: CoreType, b: CoreType) CoreType {
    if (a == b) return a;
    if ((a == .i32 or a == .f32) and (b == .i32 or b == .f32)) return .i32;
    return .i64;
}

/// Reinterpret a flat core value of type `from` into a variant's joined
/// slot type `to` (CanonicalABI `convert`; bit-preserving).
fn convertFlat(v: CoreValue, from: CoreType, to: CoreType) CoreValue {
    if (from == to) return v;
    return switch (to) {
        .i32 => switch (from) {
            .f32 => CoreValue.fromI32(@bitCast(v.f32)),
            // i32==i32 handled by the equality fast path; i64/f64 never
            // narrow per join.
            .i32, .i64, .f64 => v,
        },
        .i64 => switch (from) {
            .i32 => CoreValue.fromI64(@as(u32, @bitCast(v.i32))),
            .f32 => CoreValue.fromI64(@as(u32, @bitCast(v.f32))),
            .f64 => CoreValue.fromI64(@bitCast(v.f64)),
            .i64 => v,
        },
        .f32, .f64 => v, // join never yields float on mismatch
    };
}

/// The inverse of `convertFlat` (joined slot → the case's own flat type).
fn unconvertFlat(v: CoreValue, from: CoreType, to: CoreType) CoreValue {
    if (from == to) return v;
    return switch (to) {
        .f32 => switch (from) {
            .i32 => CoreValue{ .f32 = @bitCast(v.i32) },
            .i64 => CoreValue{ .f32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v.i64))))) },
            .f32, .f64 => v,
        },
        .f64 => switch (from) {
            .i64 => CoreValue{ .f64 = @bitCast(v.i64) },
            .i32, .f32, .f64 => v,
        },
        .i32 => switch (from) {
            .i64 => CoreValue.fromI32(@bitCast(@as(u32, @truncate(@as(u64, @bitCast(v.i64)))))),
            .i32, .f32, .f64 => v,
        },
        .i64 => v,
    };
}

const zeroOf = struct {
    fn f(t: CoreType) CoreValue {
        return switch (t) {
            .i32 => CoreValue.fromI32(0),
            .i64 => CoreValue.fromI64(0),
            .f32 => CoreValue{ .f32 = 0 },
            .f64 => CoreValue{ .f64 = 0 },
        };
    }
}.f;

pub const LowerFlatError = StoreError || StringError || FlattenError;

/// CanonicalABI `lower_flat` — lower `value` of type `t` into flat core
/// values (compound payloads land in guest memory via `cx.realloc`).
pub fn lowerFlat(cx: CanonContext, alloc: std.mem.Allocator, value: Value, t: CanonType, out: *std.ArrayList(CoreValue)) LowerFlatError!void {
    switch (t) {
        // D-322 guest resources: an OWN handle transfers as-is (the callee
        // owns the table); a BORROW lowers to the REP when the callee
        // component owns the resource type (`lower_borrow`).
        // stream/future values lower exactly like an OWN handle: the i32
        // table index passes through (the table lifecycle is Unit D).
        .own, .stream, .future => {
            const h = if (value == .handle) value.handle else return StoreError.ValueTypeMismatch;
            try out.append(alloc, CoreValue.fromI32(@bitCast(h)));
        },
        .borrow => |ti| {
            const h = if (value == .handle) value.handle else return StoreError.ValueTypeMismatch;
            const rep = cx.borrowRep(ti, h) catch return StoreError.ValueTypeMismatch;
            try out.append(alloc, CoreValue.fromI32(@bitCast(rep)));
        },
        .prim => |p| switch (p) {
            .string => {
                const s = if (value == .string) value.string else return StoreError.ValueTypeMismatch;
                const lowered = try lowerString(cx, s);
                try out.append(alloc, CoreValue.fromI32(@bitCast(lowered.ptr)));
                try out.append(alloc, CoreValue.fromI32(@bitCast(lowered.packed_length)));
            },
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .error_context => try out.append(alloc, coreFromBits(try scalarBits(value, p), p)),
        },
        .enum_ => |n| {
            if (value != .enum_value or value.enum_value >= n) return StoreError.ValueTypeMismatch;
            try out.append(alloc, CoreValue.fromI32(@bitCast(value.enum_value)));
        },
        .flags => |n| {
            _ = n;
            if (value != .flags) return StoreError.ValueTypeMismatch;
            try out.append(alloc, CoreValue.fromI32(@bitCast(value.flags)));
        },
        .list => |elem| {
            const items = if (value == .list) value.list else return StoreError.ValueTypeMismatch;
            const esize = sizeOf(elem.*);
            const byte_len: u32 = @intCast(items.len * esize);
            const base = try cx.realloc(0, 0, @intCast(alignmentOf(elem.*)), byte_len);
            if (@as(usize, base) + byte_len > cx.mem().len) return StoreError.OutOfBounds;
            for (items, 0..) |e, i| try store(cx, e, elem.*, base + @as(u32, @intCast(i * esize)));
            try out.append(alloc, CoreValue.fromI32(@bitCast(base)));
            try out.append(alloc, CoreValue.fromI32(@intCast(items.len)));
        },
        .record => |fields| {
            const vals = if (value == .record) value.record else return StoreError.ValueTypeMismatch;
            if (vals.len != fields.len) return StoreError.ValueTypeMismatch;
            for (fields, vals) |f, v| try lowerFlat(cx, alloc, v, f.ty, out);
        },
        .variant => |cases| {
            const vv = if (value == .variant) value.variant else return StoreError.ValueTypeMismatch;
            if (vv.case >= cases.len) return StoreError.ValueTypeMismatch;
            try out.append(alloc, CoreValue.fromI32(@bitCast(vv.case)));
            var joined: std.ArrayList(CoreType) = .empty;
            defer joined.deinit(alloc);
            try joinedPayloadTypes(alloc, cases, &joined);
            var payload_vals: std.ArrayList(CoreValue) = .empty;
            defer payload_vals.deinit(alloc);
            var payload_types: std.ArrayList(CoreType) = .empty;
            defer payload_types.deinit(alloc);
            if (cases[vv.case].payload) |pt| {
                const pv = vv.payload orelse return StoreError.ValueTypeMismatch;
                try lowerFlat(cx, alloc, pv.*, pt, &payload_vals);
                try flattenType(alloc, pt, &payload_types);
            }
            for (joined.items, 0..) |jt, i| {
                if (i < payload_vals.items.len) {
                    try out.append(alloc, convertFlat(payload_vals.items[i], payload_types.items[i], jt));
                } else {
                    try out.append(alloc, zeroOf(jt));
                }
            }
        },
    }
}

pub const LiftFlatError = LoadError || StringError || FlattenError || error{FlatArityMismatch};

/// CanonicalABI `lift_flat` — reconstruct a value of type `t` from the flat
/// core values at `idx` (cursor advances). Compound payloads load from
/// guest memory; slices allocate from `arena`.
pub fn liftFlat(cx: CanonContext, arena: std.mem.Allocator, t: CanonType, flats: []const CoreValue, idx: *usize) LiftFlatError!Value {
    switch (t) {
        // stream/future results lift like an OWN handle (valid as results,
        // unlike borrow); the table remove/validate is Unit D.
        .own, .stream, .future => return .{ .handle = @bitCast((try takeFlat(flats, idx, .i32)).i32) },
        .borrow => return LiftFlatError.ValueTypeMismatch, // borrow results are spec-invalid

        .prim => |p| switch (p) {
            .string => {
                const ptr: u32 = @bitCast((try takeFlat(flats, idx, .i32)).i32);
                const plen: u32 = @bitCast((try takeFlat(flats, idx, .i32)).i32);
                return .{ .string = try liftString(cx, arena, ptr, plen) };
            },
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .error_context => {
                const ct = flatCoreType(p) orelse return LiftFlatError.ValueTypeMismatch;
                return lift(try takeFlat(flats, idx, ct), p) catch LiftFlatError.ValueTypeMismatch;
            },
        },
        .enum_ => |n| {
            const v: u32 = @bitCast((try takeFlat(flats, idx, .i32)).i32);
            if (v >= n) return LiftFlatError.ValueTypeMismatch;
            return .{ .enum_value = v };
        },
        .flags => {
            return .{ .flags = @bitCast((try takeFlat(flats, idx, .i32)).i32) };
        },
        .list => |elem| {
            const base: u32 = @bitCast((try takeFlat(flats, idx, .i32)).i32);
            const n: u32 = @bitCast((try takeFlat(flats, idx, .i32)).i32);
            return loadListAt(cx, arena, elem.*, base, n);
        },
        .record => |fields| {
            const out = try arena.alloc(Value, fields.len);
            for (fields, out) |f, *slot| slot.* = try liftFlat(cx, arena, f.ty, flats, idx);
            return .{ .record = out };
        },
        .variant => |cases| {
            const case_index: u32 = @bitCast((try takeFlat(flats, idx, .i32)).i32);
            if (case_index >= cases.len) return LiftFlatError.ValueTypeMismatch;
            var joined: std.ArrayList(CoreType) = .empty;
            defer joined.deinit(arena);
            try joinedPayloadTypes(arena, cases, &joined);
            if (idx.* + joined.items.len > flats.len) return LiftFlatError.FlatArityMismatch;
            const slot_vals = flats[idx.*..][0..joined.items.len];
            idx.* += joined.items.len;
            if (cases[case_index].payload) |pt| {
                var ptypes: std.ArrayList(CoreType) = .empty;
                defer ptypes.deinit(arena);
                try flattenType(arena, pt, &ptypes);
                const conv = try arena.alloc(CoreValue, ptypes.items.len);
                for (ptypes.items, 0..) |want, i| conv[i] = unconvertFlat(slot_vals[i], joined.items[i], want);
                var pidx: usize = 0;
                const pv = try arena.create(Value);
                pv.* = try liftFlat(cx, arena, pt, conv, &pidx);
                return .{ .variant = .{ .case = case_index, .payload = pv } };
            }
            return .{ .variant = .{ .case = case_index, .payload = null } };
        },
    }
}

fn takeFlat(flats: []const CoreValue, idx: *usize, want: CoreType) error{FlatArityMismatch}!CoreValue {
    if (idx.* >= flats.len) return error.FlatArityMismatch;
    const v = flats[idx.*];
    idx.* += 1;
    _ = want;
    return v;
}

/// Load `n` elements of `elem` from `base` (the flat-list body — `load`'s
/// list branch reads (ptr, len) from memory; here the pair arrived flat).
fn loadListAt(cx: CanonContext, arena: std.mem.Allocator, elem: CanonType, base: u32, n: u32) LoadError!Value {
    const esize = sizeOf(elem);
    // Bound the (guest-controlled) `n` by what could actually fit in guest memory
    // BEFORE the alloc: a list of `n` elements of `esize` bytes must occupy
    // `n*esize` bytes at `base`, so an `n` larger than that is malformed — trap
    // rather than attempt an attacker-amplified allocation. Each element read
    // below is itself bounds-checked, but only AFTER the eager alloc; this guard
    // is the cheap pre-check at the untrusted-component boundary. `n > mem.len`
    // also covers a zero-size element type (no per-byte bound otherwise).
    const byte_span: u64 = @as(u64, n) * esize;
    if (@as(u64, base) + byte_span > cx.mem().len or n > cx.mem().len) return LoadError.OutOfBounds;
    const out = try arena.alloc(Value, n);
    for (out, 0..) |*slot, i| slot.* = try load(cx, arena, elem, base + @as(u32, @intCast(i * esize)));
    return .{ .list = out };
}

test "flattenType: record{list,string} = 4 flats; variant joins {f32}|{i64,i32} -> i64,i32" {
    const a = testing.allocator;
    var out: std.ArrayList(CoreType) = .empty;
    defer out.deinit(a);
    const str: CanonType = .{ .prim = .string };
    const rec_fields = [_]CanonType.Field{ .{ .name = "xs", .ty = .{ .list = &str } }, .{ .name = "s", .ty = str } };
    try flattenType(a, .{ .record = &rec_fields }, &out);
    try testing.expectEqualSlices(CoreType, &.{ .i32, .i32, .i32, .i32 }, out.items);

    out.clearRetainingCapacity();
    const f32t: CanonType = .{ .prim = .f32 };
    const pair_fields = [_]CanonType.Field{ .{ .name = "a", .ty = .{ .prim = .s64 } }, .{ .name = "b", .ty = .{ .prim = .s32 } } };
    const cases = [_]CanonType.VCase{
        .{ .name = "x", .payload = f32t },
        .{ .name = "y", .payload = .{ .record = &pair_fields } },
    };
    try flattenType(a, .{ .variant = &cases }, &out);
    try testing.expectEqualSlices(CoreType, &.{ .i32, .i64, .i32 }, out.items);
}

test "lowerFlat/liftFlat round-trip: record{u32, string} + variant payload conversion" {
    var bump = Bump{ .next = 64 };
    var mem = [_]u8{0} ** 4096;
    var mem_slice: []u8 = &mem;
    const cx = CanonContext{ .memory_ctx = @ptrCast(&mem_slice), .memory_fn = CanonContext.sliceMemoryFn, .realloc_ctx = @ptrCast(&bump), .realloc_fn = Bump.realloc };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const str: CanonType = .{ .prim = .string };
    const fields = [_]CanonType.Field{ .{ .name = "n", .ty = .{ .prim = .u32 } }, .{ .name = "s", .ty = str } };
    const rec_ty: CanonType = .{ .record = &fields };
    const rec_vals = [_]Value{ .{ .u32 = 7 }, .{ .string = "seven" } };

    var flats: std.ArrayList(CoreValue) = .empty;
    defer flats.deinit(testing.allocator);
    try lowerFlat(cx, testing.allocator, .{ .record = &rec_vals }, rec_ty, &flats);
    try testing.expectEqual(@as(usize, 3), flats.items.len); // u32 + (ptr,len)

    var idx: usize = 0;
    const back = try liftFlat(cx, arena, rec_ty, flats.items, &idx);
    try testing.expectEqual(@as(u32, 7), back.record[0].u32);
    try testing.expectEqualStrings("seven", back.record[1].string);

    // variant: case 0 = f32 payload through an i64-joined slot.
    const cases = [_]CanonType.VCase{
        .{ .name = "x", .payload = .{ .prim = .f32 } },
        .{ .name = "y", .payload = .{ .prim = .f64 } },
    };
    const var_ty: CanonType = .{ .variant = &cases };
    const pv = Value{ .f32 = 1.5 };
    flats.clearRetainingCapacity();
    try lowerFlat(cx, testing.allocator, .{ .variant = .{ .case = 0, .payload = &pv } }, var_ty, &flats);
    idx = 0;
    const vback = try liftFlat(cx, arena, var_ty, flats.items, &idx);
    try testing.expectEqual(@as(u32, 0), vback.variant.case);
    try testing.expectEqual(@as(f32, 1.5), vback.variant.payload.?.f32);
}

// ============================================================
// Decoded-type bridge (ADR-0183 F2b) — resolve the DECODED component
// type model (TypeInfo's ValType/DefType) into the canon type model,
// despecializing tuple→record and option/result→variant exactly as
// `CanonicalABI.md` despecialize() prescribes.
// ============================================================

pub const TypeBridgeError = error{ UnsupportedType, InvalidTypeIndex } || std.mem.Allocator.Error;

/// A decoded value type → `CanonType` (arena-allocated).
pub fn canonTypeFromDecoded(arena: std.mem.Allocator, info: *const types.TypeInfo, vt: types.ValType) TypeBridgeError!CanonType {
    switch (vt) {
        .primitive => |p| return .{ .prim = p },
        .type_index => |ti| return canonTypeFromTypeIndex(arena, info, ti),
    }
}

/// Resolve a type-space index, chasing `.named` provenance: an
/// export/import re-binding follows its referenced index; a type ALIAS of
/// an imported instance's export resolves into that import's
/// instance-TYPE declarations (the nested scope where `use`d interface
/// types actually live — ADR-0183 "the binary IS the interface").
pub fn canonTypeFromTypeIndex(arena: std.mem.Allocator, info: *const types.TypeInfo, ti: u32) TypeBridgeError!CanonType {
    if (ti >= info.type_space.items.len) return TypeBridgeError.InvalidTypeIndex;
    switch (info.type_space.items[ti]) {
        .def => |d| return canonTypeFromDefType(arena, info, info.deftypes.items[d]),
        .named => |origin| switch (origin) {
            .@"export" => |ei| return canonTypeFromTypeIndex(arena, info, info.exports.items[ei].index),
            .import => |ii| switch (info.imports.items[ii].desc) {
                .type_bound => |tb| switch (tb) {
                    .eq => |eq_ti| return canonTypeFromTypeIndex(arena, info, eq_ti),
                    .sub_resource => return TypeBridgeError.UnsupportedType,
                },
                else => return TypeBridgeError.UnsupportedType,
            },
            .alias => |ai| switch (info.aliases.items[ai].target) {
                .component_export => |ce| return canonTypeFromInstanceExport(arena, info, ce.instance, ce.name),
                .core_export, .outer => return TypeBridgeError.UnsupportedType,
            },
        },
    }
}

/// A fully-resolved deftype + the LOCAL scope its `type_index` refs
/// resolve against (empty for top-level definitions). The presentation
/// layer (ADR-0183 fromCanonValue) uses this to keep option/result/tuple
/// specialization that CanonType despecializes away.
pub const ResolvedDefType = struct {
    dt: types.DefType,
    locals: []const ?*const types.DefType,
};

/// Resolve a top-level type-space index to its defining `DefType`,
/// chasing `.named` provenance (export/import re-binds; alias →
/// imported-instance nested scope).
pub fn resolveTypeIndex(arena: std.mem.Allocator, info: *const types.TypeInfo, ti: u32) TypeBridgeError!ResolvedDefType {
    if (ti >= info.type_space.items.len) return TypeBridgeError.InvalidTypeIndex;
    switch (info.type_space.items[ti]) {
        .def => |d| return .{ .dt = info.deftypes.items[d], .locals = &.{} },
        .named => |origin| switch (origin) {
            .@"export" => |ei| return resolveTypeIndex(arena, info, info.exports.items[ei].index),
            .import => |ii| switch (info.imports.items[ii].desc) {
                .type_bound => |tb| switch (tb) {
                    .eq => |eq_ti| return resolveTypeIndex(arena, info, eq_ti),
                    .sub_resource => return TypeBridgeError.UnsupportedType,
                },
                else => return TypeBridgeError.UnsupportedType,
            },
            .alias => |ai| switch (info.aliases.items[ai].target) {
                .component_export => |ce| return resolveInstanceExportDefType(arena, info, ce.instance, ce.name),
                .core_export, .outer => return TypeBridgeError.UnsupportedType,
            },
        },
    }
}

/// Like `canonTypeFromInstanceExport` but returns the resolved deftype +
/// its local scope (shared front-half).
pub fn resolveInstanceExportDefType(arena: std.mem.Allocator, info: *const types.TypeInfo, instance_index: u32, name: []const u8) TypeBridgeError!ResolvedDefType {
    const decls = try instanceImportDecls(info, instance_index);
    var locals: std.ArrayList(?*const types.DefType) = .empty;
    errdefer locals.deinit(arena);
    var export_idx: ?u32 = null;
    for (decls) |decl| switch (decl) {
        .type_def => |td| try locals.append(arena, td),
        .alias => |al| {
            if (std.meta.activeTag(al.sort) == .type) try locals.append(arena, null);
        },
        .export_decl => |ed| switch (ed.desc) {
            .type_bound => |tb| switch (tb) {
                .eq => |local_ti| {
                    if (std.mem.eql(u8, ed.name, name)) export_idx = local_ti;
                    if (local_ti < locals.items.len) {
                        try locals.append(arena, locals.items[local_ti]);
                    } else {
                        try locals.append(arena, null);
                    }
                },
                .sub_resource => try locals.append(arena, null),
            },
            else => {},
        },
    };
    const lti = export_idx orelse return TypeBridgeError.UnsupportedType;
    if (lti >= locals.items.len) return TypeBridgeError.InvalidTypeIndex;
    const dt = locals.items[lti] orelse return TypeBridgeError.UnsupportedType;
    return .{ .dt = dt.*, .locals = try locals.toOwnedSlice(arena) };
}

/// The instance-type DECLS of an IMPORTED component instance.
fn instanceImportDecls(info: *const types.TypeInfo, instance_index: u32) TypeBridgeError![]const types.InstanceDecl {
    if (instance_index >= info.instance_origins.items.len) return TypeBridgeError.InvalidTypeIndex;
    const import_name = switch (info.instanceOrigin(instance_index) orelse return TypeBridgeError.InvalidTypeIndex) {
        .import => |n| n,
        .local, .alias, .re_export => return TypeBridgeError.UnsupportedType,
    };
    for (info.imports.items) |imp| {
        if (!std.mem.eql(u8, imp.name, import_name)) continue;
        const inst_ti = switch (imp.desc) {
            .instance => |t| t,
            else => return TypeBridgeError.UnsupportedType,
        };
        if (inst_ti >= info.type_space.items.len) return TypeBridgeError.InvalidTypeIndex;
        const dt = switch (info.type_space.items[inst_ti]) {
            .def => |d| info.deftypes.items[d],
            .named => return TypeBridgeError.UnsupportedType,
        };
        return switch (dt) {
            .instance_type => |it| it.decls,
            else => TypeBridgeError.UnsupportedType,
        };
    }
    return TypeBridgeError.UnsupportedType;
}

/// Resolve a TYPE exported by component-instance `instance_index` under
/// `name`. For an IMPORTED instance the type definition lives in the
/// import's instance-type DECLS (a nested scope with its own local type
/// index space) — walk it decl-by-decl.
fn canonTypeFromInstanceExport(arena: std.mem.Allocator, info: *const types.TypeInfo, instance_index: u32, name: []const u8) TypeBridgeError!CanonType {
    const resolved = try resolveInstanceExportDefType(arena, info, instance_index, name);
    return canonTypeFromLocalDefType(arena, info, resolved.locals, resolved.dt);
}

/// Convert a NESTED-scope deftype: `type_index` refs resolve against the
/// LOCAL decl-order space, not the component's top-level one.
fn canonTypeFromLocalDefType(arena: std.mem.Allocator, info: *const types.TypeInfo, locals: []const ?*const types.DefType, dt: types.DefType) TypeBridgeError!CanonType {
    switch (dt) {
        .value => |vt| return canonTypeFromLocalValType(arena, info, locals, vt),
        .record => |rec| {
            const fields = try arena.alloc(CanonType.Field, rec.fields.len);
            for (rec.fields, fields) |f, *slot| {
                slot.* = .{ .name = f.name, .ty = try canonTypeFromLocalValType(arena, info, locals, f.ty) };
            }
            return .{ .record = fields };
        },
        .tuple => |t| {
            const fields = try arena.alloc(CanonType.Field, t.types.len);
            for (t.types, fields) |ty, *slot| {
                slot.* = .{ .name = "", .ty = try canonTypeFromLocalValType(arena, info, locals, ty) };
            }
            return .{ .record = fields };
        },
        .list => |l| {
            if (l.fixed_length != null) return TypeBridgeError.UnsupportedType;
            const elem = try arena.create(CanonType);
            elem.* = try canonTypeFromLocalValType(arena, info, locals, l.element.*);
            return .{ .list = elem };
        },
        .option => |o| {
            const cases = try arena.alloc(CanonType.VCase, 2);
            cases[0] = .{ .name = "none", .payload = null };
            cases[1] = .{ .name = "some", .payload = try canonTypeFromLocalValType(arena, info, locals, o.payload.*) };
            return .{ .variant = cases };
        },
        .result => |r| {
            const cases = try arena.alloc(CanonType.VCase, 2);
            cases[0] = .{ .name = "ok", .payload = if (r.ok) |ok| try canonTypeFromLocalValType(arena, info, locals, ok) else null };
            cases[1] = .{ .name = "err", .payload = if (r.err) |er| try canonTypeFromLocalValType(arena, info, locals, er) else null };
            return .{ .variant = cases };
        },
        .variant => |v| {
            const cases = try arena.alloc(CanonType.VCase, v.cases.len);
            for (v.cases, cases) |c, *slot| {
                slot.* = .{ .name = c.name, .payload = if (c.payload) |pp| try canonTypeFromLocalValType(arena, info, locals, pp) else null };
            }
            return .{ .variant = cases };
        },
        .enum_ => |e| return .{ .enum_ = @intCast(e.labels.len) },
        .flags => |fl| return .{ .flags = @intCast(fl.labels.len) },
        .own => |ti| return .{ .own = ti },
        .borrow => |ti| return .{ .borrow = ti },
        .stream => |s| return .{ .stream = try boxedLocalElem(arena, info, locals, s.payload) },
        .future => |f| return .{ .future = try boxedLocalElem(arena, info, locals, f.payload) },
        .func, .instance_type, .component_type, .resource => return TypeBridgeError.UnsupportedType,
    }
}

/// Build the boxed element `CanonType` for a `stream<T>`/`future<T>` whose
/// element is the optional valtype `payload` (null → `stream`/`future`).
fn boxedLocalElem(arena: std.mem.Allocator, info: *const types.TypeInfo, locals: []const ?*const types.DefType, payload: ?types.ValType) TypeBridgeError!?*const CanonType {
    const vt = payload orelse return null;
    const p = try arena.create(CanonType);
    p.* = try canonTypeFromLocalValType(arena, info, locals, vt);
    return p;
}

fn canonTypeFromLocalValType(arena: std.mem.Allocator, info: *const types.TypeInfo, locals: []const ?*const types.DefType, vt: types.ValType) TypeBridgeError!CanonType {
    switch (vt) {
        .primitive => |p| return .{ .prim = p },
        .type_index => |ti| {
            if (ti >= locals.len) return TypeBridgeError.InvalidTypeIndex;
            const dt = locals[ti] orelse return TypeBridgeError.UnsupportedType;
            return canonTypeFromLocalDefType(arena, info, locals, dt.*);
        },
    }
}

/// A decoded deftype → `CanonType` (value-type forms only).
pub fn canonTypeFromDefType(arena: std.mem.Allocator, info: *const types.TypeInfo, dt: types.DefType) TypeBridgeError!CanonType {
    switch (dt) {
        .value => |vt| return canonTypeFromDecoded(arena, info, vt),
        .record => |rec| {
            const fields = try arena.alloc(CanonType.Field, rec.fields.len);
            for (rec.fields, fields) |f, *slot| {
                slot.* = .{ .name = f.name, .ty = try canonTypeFromDecoded(arena, info, f.ty) };
            }
            return .{ .record = fields };
        },
        .tuple => |t| {
            // despecialize: tuple = record with positional (unnamed) fields.
            const fields = try arena.alloc(CanonType.Field, t.types.len);
            for (t.types, fields) |ty, *slot| {
                slot.* = .{ .name = "", .ty = try canonTypeFromDecoded(arena, info, ty) };
            }
            return .{ .record = fields };
        },
        .list => |l| {
            if (l.fixed_length != null) return TypeBridgeError.UnsupportedType; // fixed-length lists — later
            const elem = try arena.create(CanonType);
            elem.* = try canonTypeFromDecoded(arena, info, l.element.*);
            return .{ .list = elem };
        },
        .option => |o| {
            // despecialize: option<T> = variant { none, some(T) }.
            const cases = try arena.alloc(CanonType.VCase, 2);
            cases[0] = .{ .name = "none", .payload = null };
            cases[1] = .{ .name = "some", .payload = try canonTypeFromDecoded(arena, info, o.payload.*) };
            return .{ .variant = cases };
        },
        .result => |r| {
            // despecialize: result<T, E> = variant { ok(T?), err(E?) }.
            const cases = try arena.alloc(CanonType.VCase, 2);
            cases[0] = .{ .name = "ok", .payload = if (r.ok) |ok| try canonTypeFromDecoded(arena, info, ok) else null };
            cases[1] = .{ .name = "err", .payload = if (r.err) |er| try canonTypeFromDecoded(arena, info, er) else null };
            return .{ .variant = cases };
        },
        .variant => |v| {
            const cases = try arena.alloc(CanonType.VCase, v.cases.len);
            for (v.cases, cases) |c, *slot| {
                slot.* = .{ .name = c.name, .payload = if (c.payload) |p| try canonTypeFromDecoded(arena, info, p) else null };
            }
            return .{ .variant = cases };
        },
        .enum_ => |e| return .{ .enum_ = @intCast(e.labels.len) },
        .flags => |fl| return .{ .flags = @intCast(fl.labels.len) },
        .own => |ti| return .{ .own = ti },
        .borrow => |ti| return .{ .borrow = ti },
        .stream => |s| return .{ .stream = try boxedDecodedElem(arena, info, s.payload) },
        .future => |f| return .{ .future = try boxedDecodedElem(arena, info, f.payload) },
        .func, .instance_type, .component_type, .resource => return TypeBridgeError.UnsupportedType,
    }
}

/// Build the boxed element `CanonType` for a top-level `stream<T>`/`future<T>`
/// whose element is the optional valtype `payload` (null → no element).
fn boxedDecodedElem(arena: std.mem.Allocator, info: *const types.TypeInfo, payload: ?types.ValType) TypeBridgeError!?*const CanonType {
    const vt = payload orelse return null;
    const p = try arena.create(CanonType);
    p.* = try canonTypeFromDecoded(arena, info, vt);
    return p;
}

test "D-322: own handles flatten/lower/lift as i32 pass-through; borrow lowers to the rep via the context hook" {
    const testing_ = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem_buf = [_]u8{0} ** 64;
    var mem_slice: []u8 = &mem_buf;
    const Hook = struct {
        fn borrowRep(_: *anyopaque, ti: u32, handle: u32) BorrowRepError!u32 {
            if (ti != 7 or handle != 3) return BorrowRepError.InvalidHandle;
            return 0xCAFE;
        }
        fn realloc(_: *anyopaque, _: u32, _: u32, _: u32, _: u32) ReallocError!u32 {
            return ReallocError.AllocFailed;
        }
    };
    var dummy: u8 = 0;
    const cx = CanonContext{
        .memory_ctx = @ptrCast(&mem_slice),
        .memory_fn = CanonContext.sliceMemoryFn,
        .realloc_ctx = @ptrCast(&dummy),
        .realloc_fn = Hook.realloc,
        .resource_ctx = @ptrCast(&dummy),
        .borrow_rep_fn = Hook.borrowRep,
    };

    // flatten: both are single i32 slots.
    var fl: std.ArrayList(CoreType) = .empty;
    try flattenType(a, .{ .own = 7 }, &fl);
    try flattenType(a, .{ .borrow = 7 }, &fl);
    try testing_.expectEqual(@as(usize, 2), fl.items.len);

    // lower: own passes the handle; borrow consults the hook for the rep.
    var out: std.ArrayList(CoreValue) = .empty;
    try lowerFlat(cx, a, .{ .handle = 9 }, .{ .own = 7 }, &out);
    try lowerFlat(cx, a, .{ .handle = 3 }, .{ .borrow = 7 }, &out);
    try testing_.expectEqual(@as(i32, 9), out.items[0].i32);
    try testing_.expectEqual(@as(i32, 0xCAFE), out.items[1].i32);

    // an unknown borrow handle is a shape error, not a silent pass-through.
    var bad: std.ArrayList(CoreValue) = .empty;
    try testing_.expectError(StoreError.ValueTypeMismatch, lowerFlat(cx, a, .{ .handle = 99 }, .{ .borrow = 7 }, &bad));

    // lift: an own RESULT is the handle the guest minted.
    var idx: usize = 0;
    const lifted = try liftFlat(cx, a, .{ .own = 7 }, &.{CoreValue.fromI32(5)}, &idx);
    try testing_.expectEqual(@as(u32, 5), lifted.handle);
}

test "D-335 unit C: stream/future values flatten/lower/lift as i32 handles" {
    const testing_ = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem_buf = [_]u8{0} ** 16;
    var mem_slice: []u8 = &mem_buf;
    const Hook = struct {
        fn borrowRep(_: *anyopaque, _: u32, _: u32) BorrowRepError!u32 {
            return BorrowRepError.InvalidHandle;
        }
        fn realloc(_: *anyopaque, _: u32, _: u32, _: u32, _: u32) ReallocError!u32 {
            return ReallocError.AllocFailed;
        }
    };
    var dummy: u8 = 0;
    const cx = CanonContext{
        .memory_ctx = @ptrCast(&mem_slice),
        .memory_fn = CanonContext.sliceMemoryFn,
        .realloc_ctx = @ptrCast(&dummy),
        .realloc_fn = Hook.realloc,
        .resource_ctx = @ptrCast(&dummy),
        .borrow_rep_fn = Hook.borrowRep,
    };

    const u32_ty = CanonType{ .prim = .u32 };
    const stream_ty = CanonType{ .stream = &u32_ty };
    const future_ty = CanonType{ .future = null }; // future<> (no element)

    // flatten: each is a single i32 slot (like own/borrow).
    var fl: std.ArrayList(CoreType) = .empty;
    try flattenType(a, stream_ty, &fl);
    try flattenType(a, future_ty, &fl);
    try testing_.expectEqual(@as(usize, 2), fl.items.len);
    try testing_.expectEqual(CoreType.i32, fl.items[0]);

    // lower: the handle passes through as i32 (no rep hook, unlike borrow).
    var out: std.ArrayList(CoreValue) = .empty;
    try lowerFlat(cx, a, .{ .handle = 11 }, stream_ty, &out);
    try testing_.expectEqual(@as(i32, 11), out.items[0].i32);

    // lift: a stream/future RESULT is a valid handle (borrow results are not).
    var idx: usize = 0;
    const lifted = try liftFlat(cx, a, future_ty, &.{CoreValue.fromI32(7)}, &idx);
    try testing_.expectEqual(@as(u32, 7), lifted.handle);
}
