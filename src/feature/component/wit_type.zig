//! `WitType` — the PUBLIC component-level TYPE tree (REQ-3, cw CM-API).
//!
//! The type-descriptor counterpart to `ComponentValue` (value.zig): a
//! consumer that introspects an export's signature gets a fully-resolved,
//! SPECIALIZATION-PRESERVING type tree — `option`/`result`/`tuple` stay
//! distinct (unlike `canon.CanonType`, which despecializes them to
//! variant/record for the ABI), and `enum`/`variant`/`flags` carry their
//! LABEL names. This lets a consumer map a WIT type to its host-language
//! shape (enum→keyword set, result→ok/err, record→map) without
//! re-implementing the decoded-type 2-space resolution rule (the pain cw
//! hit: it had to reconstruct a `TypeCtx` from `resolveTypeIndex`).
//!
//! Ownership: arena-allocated by the resolver's arena; label/field names
//! BORROW from the decoded `TypeInfo` (alive for the instance's lifetime),
//! exactly like `ComponentValue` field names. Nothing here is owned by an
//! external `deinit` — the arena frees the whole tree at once.
//!
//! Zone 1 (`feature/component/`): pure data + a `TypeInfo`→tree resolver,
//! no host orchestration.

const std = @import("std");

const types = @import("types.zig");
const canon = @import("canon.zig");

const PrimValType = types.PrimValType;

/// One resolved WIT type. Compound payloads are arena pointers/slices.
pub const WitType = union(enum) {
    /// A scalar (bool/s8…u64/f32/f64/char/string/error-context).
    prim: PrimValType,
    /// `list<T>` — variable length.
    list: *const WitType,
    /// `record { name: T, … }` — named, ordered fields.
    record: []const Field,
    /// `tuple<T, …>` — positional (kept distinct from record; cw maps to a vector).
    tuple: []const WitType,
    /// `variant { case(payload?), … }` — tagged union with case LABELS.
    variant: []const Case,
    /// `enum { label, … }` — ordered label set (the labels, in order).
    enum_: []const []const u8,
    /// `option<T>` — kept distinct from `variant {none, some(T)}`.
    option: *const WitType,
    /// `result<ok?, err?>` — kept distinct from `variant {ok, err}`.
    result: Result,
    /// `flags { label, … }` — the labels, in bit order (bit i ↔ labels[i]).
    flags: []const []const u8,
    /// `own<i>` — owning handle to resource type-space index `i`.
    own: u32,
    /// `borrow<i>` — borrowed handle.
    borrow: u32,
    /// `map<k, v>` — kept distinct from `list<tuple<k, v>>`.
    map: Map,

    pub const Field = struct {
        /// Borrows from the decoded `TypeInfo`.
        name: []const u8,
        ty: WitType,
    };

    pub const Case = struct {
        /// Borrows from the decoded `TypeInfo`.
        name: []const u8,
        payload: ?*const WitType,
    };

    pub const Result = struct {
        ok: ?*const WitType,
        err: ?*const WitType,
    };

    pub const Map = struct {
        key: *const WitType,
        value: *const WitType,
    };
};

/// A resolved func signature: each param's name + type, plus the (optional)
/// single result type. The cw-ergonomic one-call form for an export.
pub const FuncSig = struct {
    params: []const Param,
    result: ?WitType,

    pub const Param = struct {
        name: []const u8,
        ty: WitType,
    };
};

pub const Error = canon.TypeBridgeError;

/// Resolve a decoded `ValType` to a `WitType` tree (arena-allocated),
/// chasing the type-space `.named` provenance + the imported-instance
/// nested 2-space rule internally (REQ-3). `error_context` and any
/// non-value deftype surface as `Error.UnsupportedType`.
pub fn resolveType(arena: std.mem.Allocator, info: *const types.TypeInfo, vt: types.ValType) Error!WitType {
    return resolveValTypeScoped(arena, info, &.{}, vt);
}

/// Resolve a func export (by top-level or `<iface>#<func>` path) to its
/// full typed signature. Returns `null` when the name does not resolve to
/// a concrete func; propagates `Error` on an unsupported payload type.
pub fn resolveFuncSig(arena: std.mem.Allocator, info: *const types.TypeInfo, export_name: []const u8) Error!?FuncSig {
    const ft = info.resolveFuncType(export_name) orelse return null;
    const params = try arena.alloc(FuncSig.Param, ft.params.len);
    for (ft.params, params) |p, *slot| {
        slot.* = .{ .name = p.name, .ty = try resolveValTypeScoped(arena, info, &.{}, p.ty) };
    }
    const result: ?WitType = if (ft.result) |r| try resolveValTypeScoped(arena, info, &.{}, r) else null;
    return .{ .params = params, .result = result };
}

/// `ValType` resolver with an explicit NESTED-scope context: `locals` is
/// the decl-order local type space when `vt` came from an imported-instance
/// type declaration (empty at top level). Mirrors the 2-space rule of
/// `component_typed.fromCanonValueScoped` / `canon.canonTypeFromLocalValType`.
fn resolveValTypeScoped(arena: std.mem.Allocator, info: *const types.TypeInfo, locals: []const ?*const types.DefType, vt: types.ValType) Error!WitType {
    switch (vt) {
        .primitive => |p| return .{ .prim = p },
        .type_index => |ti| {
            if (locals.len != 0) {
                if (ti >= locals.len) return Error.InvalidTypeIndex;
                const dt = locals[ti] orelse return Error.UnsupportedType;
                return resolveDefTypeScoped(arena, info, locals, dt.*);
            }
            const resolved = try canon.resolveTypeIndex(arena, info, ti);
            return resolveDefTypeScoped(arena, info, resolved.locals, resolved.dt);
        },
    }
}

fn boxed(arena: std.mem.Allocator, t: WitType) Error!*const WitType {
    const slot = try arena.create(WitType);
    slot.* = t;
    return slot;
}

/// Convert a (possibly nested-scope) deftype: `type_index` refs resolve
/// against the LOCAL decl-order space. Specialization (option/result/tuple)
/// is PRESERVED and labels are carried (the WIT-shape, not the ABI shape).
fn resolveDefTypeScoped(arena: std.mem.Allocator, info: *const types.TypeInfo, locals: []const ?*const types.DefType, dt: types.DefType) Error!WitType {
    switch (dt) {
        .value => |vt| return resolveValTypeScoped(arena, info, locals, vt),
        .record => |rec| {
            const fields = try arena.alloc(WitType.Field, rec.fields.len);
            for (rec.fields, fields) |f, *slot| {
                slot.* = .{ .name = f.name, .ty = try resolveValTypeScoped(arena, info, locals, f.ty) };
            }
            return .{ .record = fields };
        },
        .tuple => |t| {
            const items = try arena.alloc(WitType, t.types.len);
            for (t.types, items) |ty, *slot| slot.* = try resolveValTypeScoped(arena, info, locals, ty);
            return .{ .tuple = items };
        },
        .list => |l| {
            if (l.fixed_length != null) return Error.UnsupportedType;
            return .{ .list = try boxed(arena, try resolveValTypeScoped(arena, info, locals, l.element.*)) };
        },
        .option => |o| return .{ .option = try boxed(arena, try resolveValTypeScoped(arena, info, locals, o.payload.*)) },
        .result => |r| {
            const ok: ?*const WitType = if (r.ok) |x| try boxed(arena, try resolveValTypeScoped(arena, info, locals, x)) else null;
            const er: ?*const WitType = if (r.err) |x| try boxed(arena, try resolveValTypeScoped(arena, info, locals, x)) else null;
            return .{ .result = .{ .ok = ok, .err = er } };
        },
        .variant => |v| {
            const cases = try arena.alloc(WitType.Case, v.cases.len);
            for (v.cases, cases) |c, *slot| {
                const payload: ?*const WitType = if (c.payload) |pp| try boxed(arena, try resolveValTypeScoped(arena, info, locals, pp)) else null;
                slot.* = .{ .name = c.name, .payload = payload };
            }
            return .{ .variant = cases };
        },
        .enum_ => |e| return .{ .enum_ = e.labels },
        .flags => |fl| return .{ .flags = fl.labels },
        .own => |ti| return .{ .own = ti },
        .borrow => |ti| return .{ .borrow = ti },
        .map => |m| return .{ .map = .{
            .key = try boxed(arena, try resolveValTypeScoped(arena, info, locals, m.key)),
            .value = try boxed(arena, try resolveValTypeScoped(arena, info, locals, m.value)),
        } },
        // stream/future WIT-shape resolution lands in WASI-0.3 Unit C.
        .func, .stream, .future, .instance_type, .component_type, .resource => return Error.UnsupportedType,
    }
}
