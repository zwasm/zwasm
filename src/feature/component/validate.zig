// FILE-SIZE-EXEMPT: single structural walk with 56 private per-node helpers sharing walker state (N2); no closed ≥300-LOC sub-language (investigated 2026-08-12, per ADR-0099)
//! Component-Model validation (ADR-0176) — structural-first, incremental.
//!
//! Walks the decoded `TypeInfo` (NO re-parse — the deliberate divergence from
//! wasm-tools, which interleaves validate-with-decode) and rejects invalid
//! components before instantiation, mirroring wasmtime's reject-invalid
//! behaviour (ADR-0170 wasmtime-equivalent goal). Each rule lands as one TDD
//! chunk under the E3-CM-validation bundle, driven by the official
//! `WebAssembly/component-model/test/wasm-tools` `assert_invalid` corpus.
//!
//! Rules 1–12 (corpus 158/0/0 at campaign close 2026-06-13): 1 type-index
//! bounds (def-order) · 2/3/6 alias + outer-alias existence · 4 extern
//! descs · 5 extern-name grammar (kebab/dep/url/integrity/semver) · 7
//! export named-types restriction · 8 name uniqueness (semantic method/
//! static keys) · 9 instantiate/sortidx bounds · 10 nested type-scope deep
//! validation · 11 core-type section (functype refs + module decls) · 12
//! resource generativity across inline-component boundaries.
//!
//! Zone 1 (`feature/component/`): pure logic, no host orchestration (ADR-0172).

const std = @import("std");
const decode = @import("decode.zig");
const types = @import("types.zig");

const TypeInfo = types.TypeInfo;
const DefType = types.DefType;
const ValType = types.ValType;
const Error = types.Error;

/// Component-Model spec (Binary.md / validation) — reject a component whose
/// decoded `TypeInfo` violates a structural rule. Called after
/// `decodeTypeInfo()`, before instantiation.
pub fn validate(info: *const TypeInfo) Error!void {
    // Bounds-check against the TRUE type-index-space size (type defs + type
    // aliases + type imports + type exports), NOT `deftypes.len` — a valid
    // reference to an aliased/imported type lives past the type-section count.
    const type_space_len = info.type_space_len;
    // Rule 1 refinement: a type-section def may only reference STRICTLY
    // EARLIER type indices (definition order) — its bound is its own
    // position in the type index space, not the final space size (the
    // corpus "(type (option 0))" self-/forward-reference class). Aliased/
    // imported/exported types referenced from elsewhere still bound by the
    // final size below.
    for (info.type_space.items, 0..) |entry, pos| {
        switch (entry) {
            .def => |d| {
                try checkDefTypeIndices(info.deftypes.items[d], @intCast(pos));
                try checkNestedTypeScope(info.deftypes.items[d], outerSizesOne(@intCast(pos)));
            },
            .named => {},
        }
    }
    for (info.deftypes.items) |dt| {
        try checkDefTypeLabels(dt);
        try checkDefTypeOuterAliases(dt, 1);
        try checkDefTypeDeclDups(dt);
        try checkStreamFutureElement(info, dt);
        try checkFuncResultNoBorrow(info, dt);
        try checkMapType(info, dt);
    }
    try checkInstances(info);
    try checkCanons(info, type_space_len);
    try checkAliases(info);
    try checkCoreTypes(info);
    try checkResourceDefs(info);
    try checkNestedComponentAliases(info);
    for (info.imports.items) |imp| {
        try checkExternDesc(imp.desc, type_space_len);
        try checkExternName(imp.name, .import);
    }
    for (info.exports.items) |ex| {
        if (ex.desc) |d| try checkExternDesc(d, type_space_len);
        try checkExternName(ex.name, .@"export");
        // Export sortidx bounds for the tracked index spaces (corpus
        // "module/instance index out of bounds" top-level classes).
        // For the three sorts an export EXTENDS, the bound is the space size at
        // this export's definition point, not the final size — otherwise the
        // entry the export itself adds satisfies the export's own sortidx and
        // `(export "a" (instance 0))` with no instances validates (D-527).
        switch (ex.sort) {
            .core => |cs| if (cs == .module and ex.index >= info.core_module_count) return Error.InvalidSort,
            .component => if (ex.index >= info.component_count) return Error.InvalidSort,
            .instance, .func, .type => if (ex.index >= ex.sort_space_len_at_def) return Error.InvalidSort,
            .value => {}, // value index space not tracked — deferred
        }
    }
    try checkExportedTypes(info);
    try checkDuplicateNames(info);
}

/// Rule 8 extension: name uniqueness INSIDE nested instance/component type
/// scopes — import/export decls in one scope conflict case-insensitively
/// (corpus "(type (component (import \"a\")(import \"A\")))" class). Each
/// scope is independent; nested type_defs recurse.
fn checkDefTypeDeclDups(dt: DefType) Error!void {
    switch (dt) {
        .instance_type => |it| {
            for (it.decls, 0..) |decl, i| {
                if (decl == .type_def) try checkDefTypeDeclDups(decl.type_def.*);
                const name = instanceDeclName(decl) orelse continue;
                try checkExternName(name, .@"export");
                for (it.decls[0..i]) |prev| {
                    const pn = instanceDeclName(prev) orelse continue;
                    if (std.ascii.eqlIgnoreCase(name, pn)) return Error.InvalidName;
                }
            }
        },
        .component_type => |ct| {
            for (ct.decls, 0..) |decl, i| {
                const inner = componentDeclInstanceDecl(decl);
                if (inner != null and inner.? == .type_def) try checkDefTypeDeclDups(inner.?.type_def.*);
                const name = componentDeclName(decl) orelse continue;
                try checkExternName(name, if (decl == .import_decl) .import else .@"export");
                for (ct.decls[0..i]) |prev| {
                    const pn = componentDeclName(prev) orelse continue;
                    if (std.ascii.eqlIgnoreCase(name, pn)) return Error.InvalidName;
                }
            }
        },
        .value, .func, .enum_, .flags, .record, .list, .tuple, .variant, .option, .result, .stream, .future, .map, .own, .borrow, .resource => {},
    }
}

fn instanceDeclName(decl: types.InstanceDecl) ?[]const u8 {
    return switch (decl) {
        .export_decl => |d| d.name,
        .type_def, .alias => null,
    };
}

fn componentDeclName(decl: types.ComponentDecl) ?[]const u8 {
    return switch (decl) {
        .import_decl => |d| d.name,
        .instance_decl => |id| instanceDeclName(id),
    };
}

fn componentDeclInstanceDecl(decl: types.ComponentDecl) ?types.InstanceDecl {
    return switch (decl) {
        .import_decl => null,
        .instance_decl => |id| id,
    };
}

// ============================================================
// Rule 10 — nested type-scope deep validation (ADR-0176; the corpus
// types.wast / type-export-restrictions.wast nested classes). Each
// `instance`/`component` type declaration carries its OWN local type
// index space, minted in decl order by: a `type` decl (a local DEF), a
// type-sort alias (NAMED), and an import/export decl with a type bound
// (NAMED — the re-bind is named by construction, mirroring the
// top-level `.named` type_space entries). Checks per decl, all in
// definition order:
//   - structural type refs in a local `type` def bound by the local
//     space size at the decl (rule-1 shape, local space);
//   - import/export externdesc indices (func/component/instance/value)
//     bound by the local space;
//   - outer-alias (count k) targets bound by the ENCLOSING scope's size
//     at its definition point (count 0 = this scope so far);
//   - an exported `(type (eq t))` whose `t` is a local structural DEF
//     must reference only NAMED local entries (the top-level rule-7
//     export restriction, applied in-scope).
// Core (module) decl scopes are rule 11 (core-type section decode).
// ============================================================

/// Enclosing-scope type-space sizes, innermost LAST (fixed depth cap;
/// deeper nesting defers the outer-alias bound check, never a false
/// positive).
const OuterSizes = struct {
    buf: [16]u32 = undefined,
    len: usize = 0,

    fn pushed(self: OuterSizes, size: u32) OuterSizes {
        var next = self;
        if (next.len < next.buf.len) {
            next.buf[next.len] = size;
            next.len += 1;
        }
        return next;
    }
};

fn outerSizesOne(size: u32) OuterSizes {
    return (OuterSizes{}).pushed(size);
}

const LocalTypeRef = union(enum) { def: *const DefType, named };

/// What local type entry (if any) `decl` mints in its scope's space.
fn instanceDeclMint(decl: types.InstanceDecl) ?LocalTypeRef {
    return switch (decl) {
        .type_def => |td| .{ .def = td },
        .alias => |al| if (std.meta.activeTag(al.sort) == .type) .named else null,
        .export_decl => |ed| switch (ed.desc) {
            .type_bound => .named,
            else => null,
        },
    };
}

fn componentDeclMint(decl: types.ComponentDecl) ?LocalTypeRef {
    return switch (decl) {
        .import_decl => |id| switch (id.desc) {
            .type_bound => .named,
            else => null,
        },
        .instance_decl => |inner| instanceDeclMint(inner),
    };
}

fn checkNestedTypeScope(dt: DefType, outer: OuterSizes) Error!void {
    switch (dt) {
        // Instance-type scopes get NO definition-time export restriction
        // (wasm-tools `ComponentKind::InstanceType => return true`); the
        // restriction applies when the instance type is exported
        // (`checkExportedTypes` walks it with `restrict = true`).
        .instance_type => |it| try checkInstanceDeclScope(it.decls, outer, false),
        .component_type => |ct| try checkComponentDeclScope(ct.decls, outer),
        else => {},
    }
}

fn checkInstanceDeclScope(decls: []const types.InstanceDecl, outer: OuterSizes, restrict_exports: bool) Error!void {
    var local_n: u32 = 0;
    for (decls) |decl| {
        try checkOneInstanceDecl(decl, decls, local_n, outer, restrict_exports);
        if (instanceDeclMint(decl) != null) local_n += 1;
    }
}

fn checkComponentDeclScope(decls: []const types.ComponentDecl, outer: OuterSizes) Error!void {
    var local_n: u32 = 0;
    for (decls) |decl| {
        switch (decl) {
            .import_decl => |id| try checkDeclExternDesc(id.desc, decls, local_n, true),
            .instance_decl => |inner| try checkOneInstanceDecl(inner, decls, local_n, outer, true),
        }
        if (componentDeclMint(decl) != null) local_n += 1;
    }
}

/// `decls` is the scope (only entries BEFORE the current decl are
/// consulted, via `local_n` and the `upto`-style lookups below).
fn checkOneInstanceDecl(decl: types.InstanceDecl, scope: anytype, local_n: u32, outer: OuterSizes, restrict_exports: bool) Error!void {
    switch (decl) {
        .type_def => |td| {
            // rule-1 shape against the LOCAL space at this decl.
            try checkDefTypeIndices(td.*, local_n);
            try checkNestedTypeScope(td.*, outer.pushed(local_n));
        },
        .alias => |al| {
            if (std.meta.activeTag(al.sort) != .type) return;
            switch (al.target) {
                .outer => |o| {
                    if (o.count == 0) {
                        if (o.index >= local_n) return Error.InvalidAlias;
                    } else if (o.count <= outer.len) {
                        if (o.index >= outer.buf[outer.len - o.count]) return Error.InvalidAlias;
                    }
                    // counts beyond the tracked depth are rejected by the
                    // rule-6 depth walk (checkDefTypeOuterAliases).
                },
                .core_export, .component_export => {},
            }
        },
        .export_decl => |ed| try checkDeclExternDesc(ed.desc, scope, local_n, restrict_exports),
    }
}

/// Extern-desc indices in a decl reference the scope's LOCAL type space.
/// `restrict_named` additionally applies the named-types export
/// restriction (wasm-tools `validate_and_register_named_types`): the
/// IMMEDIATE refs of a named type/func must resolve to NAMED local
/// entries, where record/variant/enum/flags are never anonymous and
/// tuple/list/option/result recurse into their components.
fn checkDeclExternDesc(desc: types.ExternDesc, scope: anytype, local_n: u32, restrict_named: bool) Error!void {
    switch (desc) {
        .func, .component, .instance => |ti| {
            if (ti >= local_n) return Error.InvalidTypeIndex;
            if (restrict_named) {
                if (desc == .func) switch (localTypeAt(scope, ti)) {
                    .def => |dt| switch (dt.*) {
                        .func => |ft| {
                            for (ft.params) |prm| try checkDeclValTypeNamed(prm.ty, scope);
                            if (ft.result) |r| try checkDeclValTypeNamed(r, scope);
                        },
                        else => {},
                    },
                    .named => {},
                };
            }
        },
        .type_bound => |tb| switch (tb) {
            .eq => |ti| {
                if (ti >= local_n) return Error.InvalidTypeIndex;
                if (restrict_named) {
                    switch (localTypeAt(scope, ti)) {
                        .def => |dt| try checkDeclDefTypeRefsNamed(dt.*, scope),
                        .named => {},
                    }
                }
            },
            .sub_resource => {},
        },
        .value_bound => |vb| if (vb) |vt| switch (vt) {
            .primitive => {},
            .type_index => |ti| if (ti >= local_n) return Error.InvalidTypeIndex,
        },
        .core_module => {}, // local core-type space — deferred (module decls undecoded)
    }
}

/// The `want`-th minted local type entry of `scope` (bounds already
/// validated by the caller).
fn localTypeAt(scope: anytype, want: u32) LocalTypeRef {
    var n: u32 = 0;
    for (scope) |decl| {
        const minted = switch (@TypeOf(decl)) {
            types.InstanceDecl => instanceDeclMint(decl),
            types.ComponentDecl => componentDeclMint(decl),
            else => @compileError("unsupported decl scope"),
        } orelse continue;
        if (n == want) return minted;
        n += 1;
    }
    unreachable; // caller bounds-checked `want < local_n`
}

/// The named-types restriction over a decl-scope def being exported
/// under a name: its IMMEDIATE refs must be named
/// (`all_valtypes_named_in_defined` shape — the def itself is being
/// named by the export, so only components are checked).
fn checkDeclDefTypeRefsNamed(dt: DefType, scope: anytype) Error!void {
    switch (dt) {
        .value => |vt| try checkDeclValTypeNamed(vt, scope),
        .func => |ft| {
            for (ft.params) |p| try checkDeclValTypeNamed(p.ty, scope);
            if (ft.result) |r| try checkDeclValTypeNamed(r, scope);
        },
        .record => |rec| for (rec.fields) |f| try checkDeclValTypeNamed(f.ty, scope),
        .tuple => |t| for (t.types) |vt| try checkDeclValTypeNamed(vt, scope),
        .list => |l| try checkDeclValTypeNamed(l.element.*, scope),
        .option => |o| try checkDeclValTypeNamed(o.payload.*, scope),
        .stream => |s| if (s.payload) |p| try checkDeclValTypeNamed(p, scope),
        .future => |f| if (f.payload) |p| try checkDeclValTypeNamed(p, scope),
        .map => |m| {
            try checkDeclValTypeNamed(m.key, scope);
            try checkDeclValTypeNamed(m.value, scope);
        },
        .variant => |v| for (v.cases) |c| {
            if (c.payload) |pl| try checkDeclValTypeNamed(pl, scope);
        },
        .result => |res| {
            if (res.ok) |ok| try checkDeclValTypeNamed(ok, scope);
            if (res.err) |er| try checkDeclValTypeNamed(er, scope);
        },
        .own, .borrow => |idx| try checkDeclRefNamed(idx, scope),
        .enum_, .flags, .resource => {},
        .instance_type, .component_type => {},
    }
}

fn checkDeclValTypeNamed(vt: ValType, scope: anytype) Error!void {
    switch (vt) {
        .primitive => {},
        .type_index => |idx| try checkDeclRefNamed(idx, scope),
    }
}

/// `type_named_type_id` semantics: a ref to a NAMED entry passes; a ref
/// to an anonymous local def passes only for the structurally-anonymous
/// forms (tuple/list/option/result — components recurse), never for
/// record/variant/enum/flags.
fn checkDeclRefNamed(idx: u32, scope: anytype) Error!void {
    var n: u32 = 0;
    for (scope) |decl| {
        const minted = switch (@TypeOf(decl)) {
            types.InstanceDecl => instanceDeclMint(decl),
            types.ComponentDecl => componentDeclMint(decl),
            else => @compileError("unsupported decl scope"),
        } orelse continue;
        if (n == idx) {
            switch (minted) {
                .named => return,
                .def => |dt| return switch (dt.*) {
                    .record, .variant, .enum_, .flags => Error.InvalidExternDesc,
                    .value => |vt| checkDeclValTypeNamed(vt, scope),
                    .tuple => |t| for (t.types) |vt| try checkDeclValTypeNamed(vt, scope),
                    .list => |l| checkDeclValTypeNamed(l.element.*, scope),
                    .option => |o| checkDeclValTypeNamed(o.payload.*, scope),
                    .stream => |s| {
                        if (s.payload) |p| try checkDeclValTypeNamed(p, scope);
                    },
                    .future => |f| {
                        if (f.payload) |p| try checkDeclValTypeNamed(p, scope);
                    },
                    .map => |m| {
                        try checkDeclValTypeNamed(m.key, scope);
                        try checkDeclValTypeNamed(m.value, scope);
                    },
                    .result => |res| {
                        if (res.ok) |ok| try checkDeclValTypeNamed(ok, scope);
                        if (res.err) |er| try checkDeclValTypeNamed(er, scope);
                    },
                    .own, .borrow => |ri| checkDeclRefNamed(ri, scope),
                    .func, .instance_type, .component_type, .resource => Error.InvalidExternDesc,
                },
            }
        }
        n += 1;
    }
    return Error.InvalidTypeIndex;
}

/// Rule 11 — core-type definitions (types.wast / invalid.wast module-decl
/// classes). A top-level core functype's `(ref N)` heap types index the
/// component's core-type space at the def's position (def-order). A
/// moduletype decl scope carries its own module-LOCAL type space, minted
/// in decl order by nested `type` decls and outer type aliases;
/// func/tag import-export type refs bound by it. An outer type alias's
/// ct counts outward (0 = the module scope, 1 = the enclosing
/// component at the def's position; deeper is invalid at top level).
fn checkCoreTypes(info: *const TypeInfo) Error!void {
    for (info.core_types.items) |entry| {
        try checkCoreDefType(entry.def, entry.space_before);
    }
}

fn checkCoreDefType(def: types.CoreDefType, enclosing_space: u32) Error!void {
    switch (def) {
        .func => |refs| for (refs) |r| {
            if (r >= enclosing_space) return Error.InvalidTypeIndex;
        },
        .module => |decls| {
            var local_n: u32 = 0;
            for (decls) |decl| switch (decl) {
                .func_type_ref => |ti| if (ti >= local_n) return Error.InvalidTypeIndex,
                .type_def => |td| {
                    // A functype nested in the module references the
                    // module-local space.
                    try checkCoreDefType(td, local_n);
                    local_n += 1;
                },
                .outer_type_alias => |o| {
                    switch (o.count) {
                        0 => if (o.index >= local_n) return Error.InvalidAlias,
                        1 => if (o.index >= enclosing_space) return Error.InvalidAlias,
                        else => return Error.InvalidAlias,
                    }
                    local_n += 1;
                },
                .other => {},
            };
        },
        .other => {},
    }
}

/// Resource definitions: the dtor (if declared) indexes the core-func
/// space (corpus resources.wast "function index out of bounds").
fn checkResourceDefs(info: *const TypeInfo) Error!void {
    const core_func_len: u32 = @intCast(info.core_funcs.items.len);
    for (info.deftypes.items) |dt| switch (dt) {
        .resource => |r| if (r.dtor) |d| {
            if (d >= core_func_len) return Error.InvalidCanon;
        },
        else => {},
    };
}

/// Rule 12 — resource generativity across component boundaries
/// (resources.wast "refers to resources not defined in the current
/// component"; Binary.md: an outer-aliased type must not be a resource
/// type, which is generative). Walk each nested (inline) component's
/// type-sort outer aliases: one that reaches THIS (root) component and
/// lands on a resource def — or a def transitively carrying
/// own/borrow/resource — is invalid. Intermediate inline-component
/// scopes are not modeled (their own spaces; deferred, never a false
/// positive); counts beyond the root are invalid outright.
fn checkNestedComponentAliases(info: *const TypeInfo) Error!void {
    for (info.nested_scans.items) |scan| try walkNestedScan(info, scan, 1);
}

fn walkNestedScan(info: *const TypeInfo, scan: types.NestedComponentScan, depth: u32) Error!void {
    for (scan.outer_type_aliases) |o| {
        if (o.count > depth) return Error.InvalidAlias; // beyond the root
        if (o.count == depth) {
            if (o.index >= info.type_space.items.len) return Error.InvalidAlias;
            switch (info.type_space.items[o.index]) {
                .named => {}, // provenance chase deferred
                .def => |d| try checkNotResourceCarrying(info, info.deftypes.items[d]),
            }
        }
        // o.count < depth: targets an intermediate inline component's
        // own space — deferred (not modeled).
    }
    for (scan.children) |c| try walkNestedScan(info, c, depth + 1);
}

fn checkNotResourceCarrying(info: *const TypeInfo, dt: DefType) Error!void {
    switch (dt) {
        .resource => return Error.InvalidAlias,
        .own, .borrow => return Error.InvalidAlias,
        .value => |vt| try checkValTypeNotResource(info, vt),
        .func => |ft| {
            for (ft.params) |p| try checkValTypeNotResource(info, p.ty);
            if (ft.result) |r| try checkValTypeNotResource(info, r);
        },
        .record => |rec| for (rec.fields) |f| try checkValTypeNotResource(info, f.ty),
        .tuple => |t| for (t.types) |vt| try checkValTypeNotResource(info, vt),
        .list => |l| try checkValTypeNotResource(info, l.element.*),
        .option => |o| try checkValTypeNotResource(info, o.payload.*),
        .stream => |s| if (s.payload) |p| try checkValTypeNotResource(info, p),
        .future => |f| if (f.payload) |p| try checkValTypeNotResource(info, p),
        .map => |m| {
            try checkValTypeNotResource(info, m.key);
            try checkValTypeNotResource(info, m.value);
        },
        .variant => |v| for (v.cases) |c| {
            if (c.payload) |pl| try checkValTypeNotResource(info, pl);
        },
        .result => |res| {
            if (res.ok) |ok| try checkValTypeNotResource(info, ok);
            if (res.err) |er| try checkValTypeNotResource(info, er);
        },
        .enum_, .flags => {},
        .instance_type, .component_type => {}, // decl scopes — deferred
    }
}

fn checkValTypeNotResource(info: *const TypeInfo, vt: ValType) Error!void {
    switch (vt) {
        .primitive => {},
        .type_index => |ti| {
            if (ti >= info.type_space.items.len) return; // bounds elsewhere
            switch (info.type_space.items[ti]) {
                .named => {},
                .def => |d| try checkNotResourceCarrying(info, info.deftypes.items[d]),
            }
        },
    }
}

/// Rule 9: instantiate-section bounds + names (corpus instantiate.wast
/// "index out of bounds" / argument-conflict classes). Definition order:
/// an instantiate/inline-export may only reference EARLIER instances (its
/// own position is the bound); module/component operands bound by their
/// section counts; instantiation-arg names must not conflict
/// (case-insensitive); component-level inline-export names are extern
/// names. Non-instance arg sorts keep gross final-space bounds where
/// tracked (false-negative at worst).
fn checkInstances(info: *const TypeInfo) Error!void {
    for (info.core_instances.items, 0..) |ci, i| {
        switch (ci) {
            .instantiate => |it| {
                if (it.module >= info.core_module_count) return Error.InvalidInstance;
                for (it.args, 0..) |arg, ai| {
                    if (arg.instance >= i) return Error.InvalidInstance;
                    for (it.args[0..ai]) |prev| {
                        if (std.ascii.eqlIgnoreCase(arg.name, prev.name)) return Error.InvalidName;
                    }
                }
            },
            .inline_exports => |exps| for (exps, 0..) |e, ei| {
                switch (e.sort) {
                    .func => if (e.index >= info.core_funcs.items.len) return Error.InvalidInstance,
                    .table => if (e.index >= info.core_tables.items.len) return Error.InvalidInstance,
                    .memory => if (e.index >= info.core_memory_count) return Error.InvalidInstance,
                    .global => if (e.index >= info.core_global_count) return Error.InvalidInstance,
                    .type => if (e.index >= info.core_type_count) return Error.InvalidInstance,
                    .module => if (e.index >= info.core_module_count) return Error.InvalidInstance,
                    .instance => if (e.index >= i) return Error.InvalidInstance,
                    _, .tag => {}, // core tag space not tracked — deferred
                }
                for (exps[0..ei]) |prev| {
                    if (std.ascii.eqlIgnoreCase(e.name, prev.name)) return Error.InvalidName;
                }
            },
        }
    }
    for (info.component_instances.items, 0..) |ci, i| {
        switch (ci) {
            .instantiate => |it| {
                if (it.component >= info.component_count) return Error.InvalidInstance;
                for (it.args, 0..) |arg, ai| {
                    try checkSortIdx(info, arg.sort, arg.index, @intCast(i));
                    for (it.args[0..ai]) |prev| {
                        if (std.ascii.eqlIgnoreCase(arg.name, prev.name)) return Error.InvalidName;
                    }
                }
            },
            .inline_exports => |exps| for (exps, 0..) |e, ei| {
                try checkExternName(e.name, .@"export");
                try checkSortIdx(info, e.sort, e.index, @intCast(i));
                for (exps[0..ei]) |prev| {
                    if (std.ascii.eqlIgnoreCase(e.name, prev.name)) return Error.InvalidName;
                }
            },
        }
    }
}

/// Bounds-check a component-level `sortidx` (instantiate args + inline
/// exports — the corpus instantiate.wast "index out of bounds" class).
/// `self_instance` bounds instance-sort refs (only EARLIER instances).
fn checkSortIdx(info: *const TypeInfo, sort: types.Sort, index: u32, self_instance: u32) Error!void {
    switch (sort) {
        .core => |cs| switch (cs) {
            .module => if (index >= info.core_module_count) return Error.InvalidInstance,
            .func => if (index >= info.core_funcs.items.len) return Error.InvalidInstance,
            .table => if (index >= info.core_tables.items.len) return Error.InvalidInstance,
            .memory => if (index >= info.core_memory_count) return Error.InvalidInstance,
            .global => if (index >= info.core_global_count) return Error.InvalidInstance,
            .type => if (index >= info.core_type_count) return Error.InvalidInstance,
            .instance => if (index >= info.core_instances.items.len) return Error.InvalidInstance,
            _, .tag => {}, // core tag space not tracked — deferred
        },
        .func => if (index >= info.component_funcs.items.len) return Error.InvalidInstance,
        .component => if (index >= info.component_count) return Error.InvalidInstance,
        .instance => if (index >= self_instance) return Error.InvalidInstance,
        .type => if (index >= info.type_space_len) return Error.InvalidTypeIndex,
        .value => {}, // value index space not tracked — deferred
    }
}

/// Rule 8: name uniqueness, ASCII-case-insensitive — kebab labels compare
/// case-insensitively per the Explainer.md `label` semantics, so `A-b`
/// conflicts with `a-B` (corpus "...conflicts with previous name...",
/// naming.wast). Checked within top-level import names, within export names
/// (the two namespaces are separate — an import and an export may share a
/// name), and within each deftype's label set (func params, record fields,
/// variant cases, enum/flags labels). O(n²) pairwise keeps the validator
/// allocation-free; the lists are small.
fn checkDuplicateNames(info: *const TypeInfo) Error!void {
    for (info.imports.items, 0..) |imp, i| {
        for (info.imports.items[0..i]) |prev| {
            if (externNamesConflict(imp.name, prev.name)) return Error.InvalidName;
        }
    }
    for (info.exports.items, 0..) |ex, i| {
        for (info.exports.items[0..i]) |prev| {
            if (externNamesConflict(ex.name, prev.name)) return Error.InvalidName;
        }
    }
    for (info.deftypes.items) |dt| try checkDefTypeLabelDups(dt);
}

const ExternNameKeyKind = enum { label, constructor, resource_func, other };

/// Semantic comparison key for extern-name uniqueness (Binary.md name
/// uniqueness; the wasm-tools `ComponentNameKind` Eq/Hash model):
/// `[method]r.m` and `[static]r.m` share one `r.m` key (they conflict with
/// each other), and the degenerate `[method]r.r` / `[static]r.r` collapses
/// to the plain label `r` (so it conflicts with an extern named `r`).
/// `[constructor]r` keys separately; every other form compares raw.
fn externNameKey(name: []const u8) struct { kind: ExternNameKeyKind, body: []const u8 } {
    if (std.mem.startsWith(u8, name, "[constructor]"))
        return .{ .kind = .constructor, .body = name["[constructor]".len..] };
    const rm = if (std.mem.startsWith(u8, name, "[method]"))
        name["[method]".len..]
    else if (std.mem.startsWith(u8, name, "[static]"))
        name["[static]".len..]
    else
        return .{ .kind = .label, .body = name };
    if (std.mem.findScalar(u8, rm, '.')) |dot| {
        if (std.ascii.eqlIgnoreCase(rm[0..dot], rm[dot + 1 ..]))
            return .{ .kind = .label, .body = rm[0..dot] };
    }
    return .{ .kind = .resource_func, .body = rm };
}

fn externNamesConflict(a: []const u8, b: []const u8) bool {
    const ka = externNameKey(a);
    const kb = externNameKey(b);
    return ka.kind == kb.kind and std.ascii.eqlIgnoreCase(ka.body, kb.body);
}

fn checkDefTypeLabelDups(dt: DefType) Error!void {
    switch (dt) {
        .func => |ft| for (ft.params, 0..) |p, i| {
            for (ft.params[0..i]) |prev| {
                if (std.ascii.eqlIgnoreCase(p.name, prev.name)) return Error.InvalidName;
            }
        },
        .record => |rec| for (rec.fields, 0..) |f, i| {
            for (rec.fields[0..i]) |prev| {
                if (std.ascii.eqlIgnoreCase(f.name, prev.name)) return Error.InvalidName;
            }
        },
        .variant => |v| for (v.cases, 0..) |c, i| {
            for (v.cases[0..i]) |prev| {
                if (std.ascii.eqlIgnoreCase(c.name, prev.name)) return Error.InvalidName;
            }
        },
        .enum_ => |e| try checkLabelSliceDups(e.labels),
        .flags => |fl| try checkLabelSliceDups(fl.labels),
        .value, .list, .tuple, .option, .result, .stream, .future, .map, .own, .borrow, .resource => {},
        .instance_type, .component_type => {},
    }
}

fn checkLabelSliceDups(labels: []const []const u8) Error!void {
    for (labels, 0..) |l, i| {
        for (labels[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(l, prev)) return Error.InvalidName;
        }
    }
}

/// Rule 7: a type export must be "valid to be used as export"
/// (type-export-restrictions.wast). When the exported index is a local
/// structural def, every type reference inside it must resolve to a NAMED
/// type-space entry (minted by a type import/export/alias) — referencing an
/// anonymous local def leaks a nameless type. `.named` exports re-export an
/// already-vetted name and pass. Nested instance/component type scopes stay
/// deferred (consistent with rule 1).
fn checkExportedTypes(info: *const TypeInfo) Error!void {
    const entries = info.type_space.items;
    for (info.exports.items) |ex| {
        if (std.meta.activeTag(ex.sort) != .type) continue;
        if (ex.index >= entries.len) return Error.InvalidTypeIndex;
        switch (entries[ex.index]) {
            .named => {},
            .def => |d| {
                try checkDefTypeRefsNamed(info, info.deftypes.items[d]);
                // Exporting an instance TYPE applies the named-types
                // restriction to its decl scope (definition time skipped
                // it — wasm-tools recurses at the export instead).
                switch (info.deftypes.items[d]) {
                    .instance_type => |it| try checkInstanceDeclScope(it.decls, .{}, true),
                    else => {},
                }
            },
        }
    }
}

fn checkDefTypeRefsNamed(info: *const TypeInfo, dt: DefType) Error!void {
    switch (dt) {
        .value => |vt| try checkValTypeNamed(info, vt),
        .func => |ft| {
            for (ft.params) |p| try checkValTypeNamed(info, p.ty);
            if (ft.result) |r| try checkValTypeNamed(info, r);
        },
        .record => |rec| for (rec.fields) |f| try checkValTypeNamed(info, f.ty),
        .tuple => |t| for (t.types) |vt| try checkValTypeNamed(info, vt),
        .list => |l| try checkValTypeNamed(info, l.element.*),
        .option => |o| try checkValTypeNamed(info, o.payload.*),
        .stream => |s| if (s.payload) |p| try checkValTypeNamed(info, p),
        .future => |f| if (f.payload) |p| try checkValTypeNamed(info, p),
        .map => |m| {
            try checkValTypeNamed(info, m.key);
            try checkValTypeNamed(info, m.value);
        },
        .variant => |v| for (v.cases) |c| {
            if (c.payload) |p| try checkValTypeNamed(info, p);
        },
        .result => |res| {
            if (res.ok) |ok| try checkValTypeNamed(info, ok);
            if (res.err) |er| try checkValTypeNamed(info, er);
        },
        .own, .borrow => |idx| try checkRefNamed(info, idx),
        // A resource type is its own name-bearer (always exportable).
        .enum_, .flags, .resource => {},
        // Nested type scopes — deferred (consistent with rule 1).
        .instance_type, .component_type => {},
    }
}

fn checkValTypeNamed(info: *const TypeInfo, vt: ValType) Error!void {
    switch (vt) {
        .primitive => {},
        .type_index => |idx| try checkRefNamed(info, idx),
    }
}

fn checkRefNamed(info: *const TypeInfo, idx: u32) Error!void {
    if (idx >= info.type_space.items.len) return Error.InvalidTypeIndex;
    if (std.meta.activeTag(info.type_space.items[idx]) != .named) return Error.InvalidExternDesc;
}

/// Rule 5: name format. Every label-carrying deftype member (func param,
/// record field, variant case, enum/flags label) must be in kebab case per
/// the Explainer.md `label` grammar. Nested `instance`/`component` type
/// scopes are deferred (consistent with rule 1 — never a false-positive).
fn checkDefTypeLabels(dt: DefType) Error!void {
    switch (dt) {
        .func => |ft| for (ft.params) |p| try checkLabel(p.name),
        .record => |rec| for (rec.fields) |f| try checkLabel(f.name),
        .variant => |v| for (v.cases) |c| try checkLabel(c.name),
        .enum_ => |e| for (e.labels) |l| try checkLabel(l),
        .flags => |fl| for (fl.labels) |l| try checkLabel(l),
        .value, .list, .tuple, .option, .result, .stream, .future, .map, .own, .borrow, .resource => {},
        .instance_type, .component_type => {},
    }
}

/// Rule 5: import/export name format (Explainer.md `importname`/`exportname`).
/// Dispatches on the name's shape:
/// - `=`-carrying forms (`locked-dep=…`/`unlocked-dep=…`/`url=…`/`integrity=…`)
///   are accepted unchecked — their grammars are deferred (false-negative at
///   worst, never a false-positive).
/// - `:`-carrying `interfacename` (`namespace:package/interface@version`):
///   each `:`/`/` segment before the `@` must be a label. (The spec restricts
///   namespace/package to lowercase; the general label check is deliberately
///   more permissive — deferred refinement, false-negative direction only.
///   The `@version` semver grammar is likewise deferred.)
/// - `[constructor]l` / `[method]l.l` / `[static]l.l`: label parts checked;
///   other bracket forms (async) are deferred.
/// - anything else is a `plainname` → plain kebab label.
const ExternNameKind = enum { import, @"export" };

fn checkExternName(name: []const u8, kind: ExternNameKind) Error!void {
    if (name.len == 0) return Error.InvalidName;
    if (std.mem.findScalar(u8, name, '=') != null) {
        // dep/url/integrity forms are IMPORT-ONLY (corpus "not a valid
        // export name").
        if (kind == .@"export") return Error.InvalidName;
        return checkEqualsForm(name);
    }
    if (std.mem.findScalar(u8, name, ':') != null) {
        // interfacename: namespace ':' pkg ('/' iface)? '@' version? — at
        // most ONE projection (corpus "trailing characters found: `/qux`")
        // and a valid semver after '@'.
        const base = if (std.mem.findScalar(u8, name, '@')) |at| blk: {
            try checkSemver(name[at + 1 ..]);
            break :blk name[0..at];
        } else name;
        var slashes: u32 = 0;
        for (base) |ch| {
            if (ch == '/') slashes += 1;
        }
        if (slashes > 1) return Error.InvalidName;
        var it = std.mem.splitAny(u8, base, ":/");
        while (it.next()) |segment| try checkLabel(segment);
        return;
    }
    if (name[0] == '[') {
        const close = std.mem.findScalar(u8, name, ']') orelse return Error.InvalidName;
        const bracket = name[1..close];
        const rest = name[close + 1 ..];
        if (std.mem.eql(u8, bracket, "constructor")) return checkLabel(rest);
        if (std.mem.eql(u8, bracket, "method") or std.mem.eql(u8, bracket, "static")) {
            const dot = std.mem.findScalar(u8, rest, '.') orelse return Error.InvalidName;
            try checkLabel(rest[0..dot]);
            return checkLabel(rest[dot + 1 ..]);
        }
        return; // other bracket forms (async lift/lower) — deferred
    }
    return checkLabel(name);
}

/// Rule 5 completion: the `=`-carrying importname/exportname forms
/// (Explainer.md `depname` / `urlname` / `hashname` grammars). Dispatch by
/// prefix; an unknown `=` form is invalid (the spec defines exactly these).
fn checkEqualsForm(name: []const u8) Error!void {
    if (std.mem.startsWith(u8, name, "unlocked-dep=")) {
        const body = try angled(name["unlocked-dep=".len..], true);
        return checkPkgPath(body, .query);
    }
    if (std.mem.startsWith(u8, name, "locked-dep=")) {
        const rest = name["locked-dep=".len..];
        if (rest.len < 2 or rest[0] != '<') return Error.InvalidName;
        const close = std.mem.findScalar(u8, rest, '>') orelse return Error.InvalidName;
        try checkPkgPath(rest[1..close], .exact);
        const tail = rest[close + 1 ..];
        if (tail.len == 0) return;
        if (!std.mem.startsWith(u8, tail, ",integrity=")) return Error.InvalidName;
        return checkIntegrity(try angled(tail[",integrity=".len..], true));
    }
    if (std.mem.startsWith(u8, name, "url=")) {
        const body = try angled(name["url=".len..], true);
        if (body.len == 0) return Error.InvalidName;
        // The angled parse already rejects a stray '>'; reject embedded '<'.
        if (std.mem.findScalar(u8, body, '<') != null) return Error.InvalidName;
        return;
    }
    if (std.mem.startsWith(u8, name, "integrity=")) {
        return checkIntegrity(try angled(name["integrity=".len..], true));
    }
    return Error.InvalidName; // unknown `=` form
}

/// `'<' body '>'` consuming the WHOLE string (the closing bracket is the
/// final character — a version-range body like `{>=1.2.3}` may itself
/// contain `>`); returns the body.
fn angled(s: []const u8, exact: bool) Error![]const u8 {
    _ = exact;
    if (s.len < 2 or s[0] != '<' or s[s.len - 1] != '>') return Error.InvalidName;
    return s[1 .. s.len - 1];
}

const PkgVersionKind = enum { exact, query };

/// `pkgname(query)` inside a dep form: `namespace ':' pkg ('/' iface)*`
/// segments are kebab labels; an optional `'@' version` must be non-empty
/// (semver / range grammars deferred beyond non-emptiness).
fn checkPkgPath(body: []const u8, kind: PkgVersionKind) Error!void {
    _ = kind;
    const path = if (std.mem.findScalar(u8, body, '@')) |at| blk: {
        if (at + 1 >= body.len) return Error.InvalidName; // empty version
        break :blk body[0..at];
    } else body;
    var colon_parts: u32 = 0;
    var it = std.mem.splitAny(u8, path, ":/");
    while (it.next()) |segment| {
        try checkLabel(segment); // empty segment -> InvalidName via checkLabel
        colon_parts += 1;
    }
    if (colon_parts < 2) return Error.InvalidName; // at least namespace:pkg
}

/// Minimal semver: `major '.' minor '.' patch` (digits), optional
/// non-empty `-prerelease` then optional non-empty `+build` (corpus
/// "@2.0.0+"/"@2.0.0-" trailing-empty classes are invalid).
fn checkSemver(v: []const u8) Error!void {
    if (v.len == 0) return Error.InvalidName;
    var core = v;
    if (std.mem.findScalar(u8, v, '+')) |plus| {
        if (plus + 1 >= v.len) return Error.InvalidName;
        core = v[0..plus];
    }
    if (std.mem.findScalar(u8, core, '-')) |dash| {
        if (dash + 1 >= core.len) return Error.InvalidName;
        core = core[0..dash];
    }
    var parts: u32 = 0;
    var it = std.mem.splitScalar(u8, core, '.');
    while (it.next()) |p| {
        if (p.len == 0) return Error.InvalidName;
        for (p) |ch| if (!std.ascii.isDigit(ch)) return Error.InvalidName;
        parts += 1;
    }
    if (parts != 3) return Error.InvalidName;
}

/// `integrity-metadata` (SRI subset): whitespace-separated `alg '-' base64
/// ('?' options)?` entries; alg in {sha256, sha384, sha512}; at least one.
fn checkIntegrity(body: []const u8) Error!void {
    var any = false;
    var it = std.mem.splitScalar(u8, body, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        any = true;
        const dash = std.mem.findScalar(u8, tok, '-') orelse return Error.InvalidName;
        const alg = tok[0..dash];
        if (!std.mem.eql(u8, alg, "sha256") and !std.mem.eql(u8, alg, "sha384") and !std.mem.eql(u8, alg, "sha512"))
            return Error.InvalidName;
        var b64 = tok[dash + 1 ..];
        if (std.mem.findScalar(u8, b64, '?')) |q| b64 = b64[0..q];
        // base64: data chars then at most 2 trailing '='; '=' only at end;
        // must contain at least one data char (corpus "not valid base64").
        var pad: u32 = 0;
        while (pad < b64.len and b64[b64.len - 1 - pad] == '=') pad += 1;
        if (pad > 2) return Error.InvalidName;
        const data = b64[0 .. b64.len - pad];
        if (data.len == 0) return Error.InvalidName;
        for (data) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '/'))
                return Error.InvalidName;
        }
    }
    if (!any) return Error.InvalidName;
}

/// Explainer.md `label` grammar: `label ::= <fragment> ('-' <fragment>)*`
/// where the first fragment is `[a-z][0-9a-z]*` or `[A-Z][0-9A-Z]*` (starts
/// with a letter) and later fragments are `[0-9a-z]+` or `[0-9A-Z]+` (may
/// start with a digit). Mixing cases WITHIN a fragment, empty fragments
/// (leading/trailing/double `-`), and the empty label are invalid.
fn checkLabel(label: []const u8) Error!void {
    if (label.len == 0) return Error.InvalidName;
    var it = std.mem.splitScalar(u8, label, '-');
    var first = true;
    while (it.next()) |fragment| {
        if (fragment.len == 0) return Error.InvalidName;
        if (first and std.ascii.isDigit(fragment[0])) return Error.InvalidName;
        var all_lower = true;
        var all_upper = true;
        for (fragment) |ch| {
            if (!(std.ascii.isDigit(ch) or std.ascii.isLower(ch))) all_lower = false;
            if (!(std.ascii.isDigit(ch) or std.ascii.isUpper(ch))) all_upper = false;
        }
        if (!all_lower and !all_upper) return Error.InvalidName;
        first = false;
    }
}

/// Rule 4: an import/export `externdesc` that ascribes a type must reference an
/// in-bounds type. `func`/`component`/`instance` are type indices (the ascribed
/// def-type); `type_bound (eq i)` references type `i`; `value` carries a valtype.
/// `core_module` (core-module index space) is deferred — the count is not yet
/// surfaced on `TypeInfo` (a false-negative at worst, never a false-positive).
fn checkExternDesc(desc: types.ExternDesc, type_space_len: u32) Error!void {
    switch (desc) {
        .func, .component, .instance => |idx| if (idx >= type_space_len) return Error.InvalidExternDesc,
        .type_bound => |tb| switch (tb) {
            .eq => |idx| if (idx >= type_space_len) return Error.InvalidExternDesc,
            .sub_resource => {},
        },
        .value_bound => |vb| if (vb) |vt| try checkValType(vt, type_space_len),
        .core_module => {}, // core-module index space count not yet on TypeInfo — deferred
    }
}

/// Rule 3: an `alias` of an instance export must name an in-bounds instance.
/// `core_export` → core-instance space (`core_instances`), `component_export` →
/// component-instance space (`instance_origins`). Bounds are the final space
/// size — a gross OOB (the corpus "instance index out of bounds" category) is
/// caught; definition-order forward-reference refinement + export-name existence
/// are deferred (a false-negative at worst, never a false-positive).
/// Rule 6 (top-level half): an `outer` alias count must be `<` the number of
/// enclosing component scopes — the top level is ONE scope (count 0 = the
/// current component), so any count ≥ 1 is the corpus "invalid outer alias
/// count" category. The target index's existence at the aliased scope is
/// deferred (index-bounds refinement).
fn checkAliases(info: *const TypeInfo) Error!void {
    const core_inst_len: u32 = @intCast(info.core_instances.items.len);
    const comp_inst_len: u32 = @intCast(info.instance_origins.items.len);
    for (info.aliases.items, info.alias_space_before.items) |al, before| switch (al.target) {
        .core_export => |ce| if (ce.instance >= core_inst_len) return Error.InvalidAlias,
        .component_export => |ce| if (ce.instance >= comp_inst_len) return Error.InvalidAlias,
        .outer => |o| {
            if (o.count >= 1) return Error.InvalidAlias;
            // count 0 = the current component: existence is checkable for the
            // sorts whose spaces are tracked (others stay deferred). The
            // bound is the space size at the alias's DEFINITION point — an
            // outer alias must not satisfy itself with the index it mints.
            switch (al.sort) {
                .type => if (o.index >= before.type_space) return Error.InvalidAlias,
                .component => if (o.index >= info.component_count) return Error.InvalidAlias,
                .core => |cs| switch (cs) {
                    .module => if (o.index >= info.core_module_count) return Error.InvalidAlias,
                    .type => if (o.index >= before.core_types) return Error.InvalidAlias,
                    else => {},
                },
                else => {},
            }
        },
    };
}

/// Rule 6 (nested half): walk nested `instance`/`component` type scopes,
/// tracking depth = the number of enclosing component scopes at the decl site
/// (top level = 1; each nested instance/component type adds one). An `outer`
/// alias decl whose count ≥ depth skips past the outermost scope — the corpus
/// "invalid outer alias count" category.
fn checkDefTypeOuterAliases(dt: DefType, depth: u32) Error!void {
    switch (dt) {
        .instance_type => |it| for (it.decls) |decl| try checkInstanceDeclOuterAlias(decl, depth + 1),
        .component_type => |ct| for (ct.decls) |decl| switch (decl) {
            .import_decl => {},
            .instance_decl => |id| try checkInstanceDeclOuterAlias(id, depth + 1),
        },
        .value, .func, .enum_, .flags, .record, .list, .tuple, .variant, .option, .result, .stream, .future, .map, .own, .borrow, .resource => {},
    }
}

fn checkInstanceDeclOuterAlias(decl: types.InstanceDecl, depth: u32) Error!void {
    switch (decl) {
        .type_def => |td| try checkDefTypeOuterAliases(td.*, depth),
        .alias => |al| switch (al.target) {
            .outer => |o| if (o.count >= depth) return Error.InvalidAlias,
            .component_export, .core_export => {},
        },
        .export_decl => {},
    }
}

/// Rule 2: bounds-check every index a `canon` definition references against its
/// index space — `lift` (core-func + component-func type), `lower` (component
/// func), and the resource builtins (type). The core-/component-func lists ARE
/// their index spaces (every minting form appends), so `.items.len` is exact
/// here (unlike `deftypes.len` for the type space — see rule 1).
fn checkCanons(info: *const TypeInfo, type_space_len: u32) Error!void {
    const core_func_len: u32 = @intCast(info.core_funcs.items.len);
    const comp_func_len: u32 = @intCast(info.component_funcs.items.len);
    for (info.canons.items) |c| switch (c) {
        .lift => |l| {
            if (l.core_func >= core_func_len) return Error.InvalidCanon;
            if (l.type_index >= type_space_len) return Error.InvalidTypeIndex;
            try checkCanonOpts(info, l.opts);
        },
        .lower => |l| {
            if (l.func >= comp_func_len) return Error.InvalidCanon;
            try checkCanonOpts(info, l.opts);
        },
        .resource_new, .resource_drop, .resource_rep => |t| if (t >= type_space_len) return Error.InvalidTypeIndex,
        .stream_future => |sf| {
            if (sf.type_index >= type_space_len) return Error.InvalidTypeIndex;
            if (sf.opts) |o| try checkCanonOpts(info, o);
        },
        .task_return => |tr| {
            if (tr.result) |r| switch (r) {
                .type_index => |ti| if (ti >= type_space_len) return Error.InvalidTypeIndex,
                .primitive => {},
            };
            try checkCanonOpts(info, tr.opts);
        },
        .waitable_set => |ws| {
            // wait/poll write the event tuple to `(memory m)`; bounds-check it.
            if (ws.memory) |m| if (m >= info.core_memory_count) return Error.InvalidCanon;
        },
        // No index-space operands (flags / slot indices only).
        .task_cancel, .subtask_cancel, .subtask_drop, .context_get, .context_set, .thread_yield => {},
    };
}

/// Canon-opt index operands: `(memory m)` indexes the core-memory space,
/// `(realloc f)` / `(post-return f)` the core-func space.
fn checkCanonOpts(info: *const TypeInfo, opts: types.CanonOpts) Error!void {
    const core_func_len: u32 = @intCast(info.core_funcs.items.len);
    if (opts.memory) |m| if (m >= info.core_memory_count) return Error.InvalidCanon;
    if (opts.realloc) |r| if (r >= core_func_len) return Error.InvalidCanon;
    if (opts.post_return) |pr| if (pr >= core_func_len) return Error.InvalidCanon;
    if (opts.callback) |cb| if (cb >= core_func_len) return Error.InvalidCanon; // CM-async `callback` core:funcidx
}

/// Rule 1: bounds-check every type-index a top-level deftype references against
/// the type-index-space length. Nested `instance`/`component` type scopes carry
/// their own index spaces and are deferred to a later rule (no false positives).
fn checkDefTypeIndices(dt: DefType, type_space_len: u32) Error!void {
    switch (dt) {
        .value => |vt| try checkValType(vt, type_space_len),
        .func => |ft| {
            for (ft.params) |p| try checkValType(p.ty, type_space_len);
            if (ft.result) |r| try checkValType(r, type_space_len);
        },
        .record => |rec| for (rec.fields) |f| try checkValType(f.ty, type_space_len),
        .tuple => |t| for (t.types) |vt| try checkValType(vt, type_space_len),
        .list => |l| try checkValType(l.element.*, type_space_len),
        .option => |o| try checkValType(o.payload.*, type_space_len),
        .stream => |s| if (s.payload) |p| try checkValType(p, type_space_len),
        .future => |f| if (f.payload) |p| try checkValType(p, type_space_len),
        .map => |m| {
            try checkValType(m.key, type_space_len);
            try checkValType(m.value, type_space_len);
        },
        .variant => |v| for (v.cases) |c| {
            if (c.payload) |p| try checkValType(p, type_space_len);
        },
        .result => |res| {
            if (res.ok) |ok| try checkValType(ok, type_space_len);
            if (res.err) |er| try checkValType(er, type_space_len);
        },
        .own, .borrow => |idx| if (idx >= type_space_len) return Error.InvalidTypeIndex,
        .resource => {}, // dtor indexes the core-func space (checked by rule 12 wiring later if needed)
        // No type-index references in their immediate form:
        .enum_, .flags => {},
        // Nested type scopes — deferred to a later structural rule.
        .instance_type, .component_type => {},
    }
}

fn checkValType(vt: ValType, type_space_len: u32) Error!void {
    switch (vt) {
        .primitive => {},
        .type_index => |idx| if (idx >= type_space_len) return Error.InvalidTypeIndex,
    }
}

/// Spec (`Binary.md`): a `stream`/`future` element type may not transitively
/// contain a `borrow`, and `(stream char)` is a temporary rejection
/// (`Concurrency.md` TODO). The sibling transitive-`borrow` rule for functype
/// results / exported values is a separate, pre-existing gap (D-336).
fn checkStreamFutureElement(info: *const TypeInfo, dt: DefType) Error!void {
    const payload = switch (dt) {
        .stream => |s| s.payload orelse return,
        .future => |f| f.payload orelse return,
        else => return,
    };
    try checkValTypeNoBorrow(info, payload);
    if (dt == .stream and payload == .primitive and payload.primitive == .char) {
        return Error.InvalidDefType;
    }
}

/// Spec (`Binary.md`): a functype `result` type may not transitively contain a
/// `borrow` (a borrow in a PARAM is allowed — that is borrow's purpose). The
/// sibling exported-value rule stays blocked on the untracked value index space
/// (sort=value deferred). (D-336.)
fn checkFuncResultNoBorrow(info: *const TypeInfo, dt: DefType) Error!void {
    switch (dt) {
        .func => |ft| if (ft.result) |r| try checkValTypeNoBorrow(info, r),
        else => {},
    }
}

fn checkValTypeNoBorrow(info: *const TypeInfo, vt: ValType) Error!void {
    return checkValTypeCarries(info, vt, .{ .borrow = true }, Error.InvalidDefType);
}

/// The value-type kinds a position may forbid a type to carry transitively.
const Carried = struct {
    own: bool = false,
    borrow: bool = false,
    /// `stream`, `future` and `error-context`.
    async_value: bool = false,
};

fn checkValTypeCarries(info: *const TypeInfo, vt: ValType, comptime forbid: Carried, err: Error) Error!void {
    switch (vt) {
        .primitive => |p| if (forbid.async_value and p == .error_context) return err,
        .type_index => |ti| switch (resolveRebinding(info, ti)) {
            .def => |dt| try checkDefTypeCarries(info, dt, forbid, err),
            .unresolved, .fresh => {},
        },
    }
}

fn checkDefTypeCarries(info: *const TypeInfo, dt: DefType, comptime forbid: Carried, err: Error) Error!void {
    switch (dt) {
        .own => if (forbid.own) return err,
        .borrow => if (forbid.borrow) return err,
        .stream, .future => if (forbid.async_value) return err,
        else => {},
    }
    switch (dt) {
        .value => |vt| try checkValTypeCarries(info, vt, forbid, err),
        .record => |rec| for (rec.fields) |f| try checkValTypeCarries(info, f.ty, forbid, err),
        .tuple => |t| for (t.types) |vt| try checkValTypeCarries(info, vt, forbid, err),
        .list => |l| try checkValTypeCarries(info, l.element.*, forbid, err),
        .option => |o| try checkValTypeCarries(info, o.payload.*, forbid, err),
        .stream => |s| if (s.payload) |p| try checkValTypeCarries(info, p, forbid, err),
        .future => |f| if (f.payload) |p| try checkValTypeCarries(info, p, forbid, err),
        .map => |m| {
            try checkValTypeCarries(info, m.key, forbid, err);
            try checkValTypeCarries(info, m.value, forbid, err);
        },
        .variant => |v| for (v.cases) |c| {
            if (c.payload) |pl| try checkValTypeCarries(info, pl, forbid, err);
        },
        .result => |res| {
            if (res.ok) |ok| try checkValTypeCarries(info, ok, forbid, err);
            if (res.err) |er| try checkValTypeCarries(info, er, forbid, err);
        },
        // Handles are leaves; funcs, resources, enum/flags and nested type
        // scopes are not value types.
        .own, .borrow, .func, .enum_, .flags, .resource, .instance_type, .component_type => {},
    }
}

/// Spec (`Explainer.md`): a `map` key is a `keytype` — `bool`, an integer,
/// `char` or `string`, inline or behind a type index that resolves to one —
/// and the value may not transitively contain `own`, `borrow`, `future`,
/// `stream` or `error-context`.
fn checkMapType(info: *const TypeInfo, dt: DefType) Error!void {
    const m = switch (dt) {
        .map => |m| m,
        else => return,
    };
    if (!isMapKey(info, m.key)) return Error.InvalidMapKey;
    try checkValTypeCarries(info, m.value, .{ .own = true, .borrow = true, .async_value = true }, Error.InvalidMapValue);
}

fn isMapKey(info: *const TypeInfo, key: ValType) bool {
    const vt = switch (key) {
        .primitive => key,
        .type_index => |ti| switch (resolveRebinding(info, ti)) {
            .def => |dt| switch (dt) {
                .value => |inner| inner,
                else => return false,
            },
            .unresolved => return true,
            .fresh => return false,
        },
    };
    return switch (vt) {
        .primitive => |p| switch (p) {
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .char, .string => true,
            .f32, .f64, .error_context => false,
        },
        .type_index => false, // a deftype is never a bare typeidx
    };
}

const Rebound = union(enum) {
    def: DefType,
    /// Out of bounds (checked elsewhere), or an alias: it resolves into the
    /// aliased instance's type decls, which this file does not chase
    /// (accepted, like the other provenance chases).
    unresolved,
    /// A `sub resource` import, or a malformed forward re-binding (rejected
    /// by the export / import bounds).
    fresh,
};

/// Follow type exports and `(eq i)` type imports from `ti` to the type they
/// re-bind. A loop, not recursion: a chain is as long as the component's
/// export list. A valid re-binding names a strictly earlier index, which also
/// ends the loop on malformed input.
fn resolveRebinding(info: *const TypeInfo, start: u32) Rebound {
    var ti = start;
    while (true) {
        if (ti >= info.type_space.items.len) return .unresolved;
        const origin = switch (info.type_space.items[ti]) {
            .def => |d| return .{ .def = info.deftypes.items[d] },
            .named => |o| o,
        };
        const target = switch (origin) {
            .@"export" => |ei| info.exports.items[ei].index,
            .import => |ii| switch (info.imports.items[ii].desc) {
                .type_bound => |tb| switch (tb) {
                    .eq => |eq_ti| eq_ti,
                    .sub_resource => return .fresh,
                },
                else => return .fresh,
            },
            .alias => return .unresolved,
        };
        if (target >= ti) return .fresh;
        ti = target;
    }
}

/// Decode a component binary (magic + layer preamble prepended) and validate.
fn validateBytes(bytes: []const u8) !void {
    var comp = try decode.decode(std.testing.allocator, bytes);
    defer comp.deinit(std.testing.allocator);
    var info = try types.decodeTypeInfo(std.testing.allocator, &comp);
    defer info.deinit();
    try validate(&info);
}

test "rule 7: exported local type may reference named types only" {
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    // type[0] = (record (field "f" u32)) — local def.
    const type_a = [_]u8{ 0x01, 0x72, 0x01, 0x01, 'f', 0x79 };
    // (export "t" (type 0)) — mints type[1] as NAMED.
    const export_t = [_]u8{ 0x01, 0x00, 0x01, 't', 0x03, 0x00, 0x00 };

    // VALID: type[2] = (record (field "g" (type 1))) references the NAMED
    // export-minted index; exporting it is allowed.
    const type_named_ref = [_]u8{ 0x01, 0x72, 0x01, 0x01, 'g', 0x01 };
    const export_g2 = [_]u8{ 0x01, 0x00, 0x01, 'g', 0x03, 0x02, 0x00 };
    const valid = preamble ++
        [_]u8{ 7, type_a.len } ++ type_a ++
        [_]u8{ 11, export_t.len } ++ export_t ++
        [_]u8{ 7, type_named_ref.len } ++ type_named_ref ++
        [_]u8{ 11, export_g2.len } ++ export_g2;
    try validateBytes(&valid);

    // INVALID: type[2] = (record (field "g" (type 0))) references the
    // anonymous local def — "type not valid to be used as export".
    const type_local_ref = [_]u8{ 0x01, 0x72, 0x01, 0x01, 'g', 0x00 };
    const invalid = preamble ++
        [_]u8{ 7, type_a.len } ++ type_a ++
        [_]u8{ 11, export_t.len } ++ export_t ++
        [_]u8{ 7, type_local_ref.len } ++ type_local_ref ++
        [_]u8{ 11, export_g2.len } ++ export_g2;
    try std.testing.expectError(Error.InvalidExternDesc, validateBytes(&invalid));
}

test "stream/future element: reject (stream char) + transitive borrow" {
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };

    // VALID: type[0] stream<u32>, type[1] future (no element).
    const ok_body = [_]u8{ 0x02, 0x66, 0x01, 0x79, 0x65, 0x00 };
    const ok = preamble ++ [_]u8{ 7, ok_body.len } ++ ok_body;
    try validateBytes(&ok);

    // INVALID: (stream char) — temporary restriction (Concurrency.md TODO).
    const char_body = [_]u8{ 0x01, 0x66, 0x01, 0x74 };
    const bad_char = preamble ++ [_]u8{ 7, char_body.len } ++ char_body;
    try std.testing.expectError(Error.InvalidDefType, validateBytes(&bad_char));

    // INVALID: element transitively contains a `borrow`. type[0]=resource(rep
    // i32); type[1]=borrow<0>; type[2]=stream<type 1>.
    const borrow_body = [_]u8{ 0x03, 0x3f, 0x7f, 0x00, 0x68, 0x00, 0x66, 0x01, 0x01 };
    const bad_borrow = preamble ++ [_]u8{ 7, borrow_body.len } ++ borrow_body;
    try std.testing.expectError(Error.InvalidDefType, validateBytes(&bad_borrow));

    // INVALID: the same `borrow` behind a type export. type[0]=resource;
    // (export "r" (type 0)) mints type[1]; type[2]=borrow<1>;
    // (export "b" (type 2)) mints type[3]; type[4]=stream<type 3>.
    const export_r = [_]u8{ 0x01, 0x00, 0x01, 'r', 0x03, 0x00, 0x00 };
    const export_b = [_]u8{ 0x01, 0x00, 0x01, 'b', 0x03, 0x02, 0x00 };
    const via_export = preamble ++ [_]u8{ 7, 4, 0x01, 0x3f, 0x7f, 0x00 } ++
        [_]u8{ 11, export_r.len } ++ export_r ++
        [_]u8{ 7, 3, 0x01, 0x68, 0x01 } ++
        [_]u8{ 11, export_b.len } ++ export_b ++
        [_]u8{ 7, 4, 0x01, 0x66, 0x01, 0x03 };
    try std.testing.expectError(Error.InvalidDefType, validateBytes(&via_export));
}

test "map: the key is a keytype, the value carries no handle or async value" {
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    const Case = struct { body: []const u8, err: ?Error };
    const cases = [_]Case{
        // map<string, u32>
        .{ .body = &.{ 0x01, 0x63, 0x73, 0x79 }, .err = null },
        // type[0]=string; map<type 0, u32> — a key behind a type index
        .{ .body = &.{ 0x02, 0x73, 0x63, 0x00, 0x79 }, .err = null },
        // map<f32, u32>
        .{ .body = &.{ 0x01, 0x63, 0x76, 0x79 }, .err = Error.InvalidMapKey },
        // type[0]=list<u8>; map<type 0, u32>
        .{ .body = &.{ 0x02, 0x70, 0x7d, 0x63, 0x00, 0x79 }, .err = Error.InvalidMapKey },
        // type[0]=resource; type[1]=own<0>; map<string, type 1>
        .{ .body = &.{ 0x03, 0x3f, 0x7f, 0x00, 0x69, 0x00, 0x63, 0x73, 0x01 }, .err = Error.InvalidMapValue },
        // type[0]=stream<u32>; type[1]=list<type 0>; map<string, type 1>
        .{ .body = &.{ 0x03, 0x66, 0x01, 0x79, 0x70, 0x00, 0x63, 0x73, 0x01 }, .err = Error.InvalidMapValue },
        // map<string, error-context>
        .{ .body = &.{ 0x01, 0x63, 0x73, 0x64 }, .err = Error.InvalidMapValue },
    };
    inline for (cases) |c| {
        const bytes = preamble ++ [_]u8{ 7, c.body.len } ++ c.body[0..c.body.len].*;
        if (c.err) |e| {
            try std.testing.expectError(e, validateBytes(&bytes));
        } else try validateBytes(&bytes);
    }

    // A key re-bound by a type export resolves through it: type[0]=string;
    // (export "k" (type 0)) mints type[1]; map<type 1, u32>.
    const export_k = [_]u8{ 0x01, 0x00, 0x01, 'k', 0x03, 0x00, 0x00 };
    const map_body = [_]u8{ 0x01, 0x63, 0x01, 0x79 };
    const named = preamble ++ [_]u8{ 7, 2, 0x01, 0x73 } ++
        [_]u8{ 11, export_k.len } ++ export_k ++
        [_]u8{ 7, map_body.len } ++ map_body;
    try validateBytes(&named);

    // A value re-bound by a type export or an `eq` import is checked through
    // it. type[0]=resource; (export "r" (type 0)) mints type[1];
    // type[2]=own<1>; then type[3] re-binds type[2], and map<string, type 3>.
    const export_r = [_]u8{ 0x01, 0x00, 0x01, 'r', 0x03, 0x00, 0x00 };
    const own_body = [_]u8{ 0x01, 0x69, 0x01 };
    const map_own = [_]u8{ 0x01, 0x63, 0x73, 0x03 };
    const head = preamble ++ [_]u8{ 7, 4, 0x01, 0x3f, 0x7f, 0x00 } ++
        [_]u8{ 11, export_r.len } ++ export_r ++
        [_]u8{ 7, own_body.len } ++ own_body;
    const export_t = [_]u8{ 0x01, 0x00, 0x01, 't', 0x03, 0x02, 0x00 };
    const via_export = head ++ [_]u8{ 11, export_t.len } ++ export_t ++
        [_]u8{ 7, map_own.len } ++ map_own;
    try std.testing.expectError(Error.InvalidMapValue, validateBytes(&via_export));
    // (import "t" (type (eq 2)))
    const import_t = [_]u8{ 0x01, 0x00, 0x01, 't', 0x03, 0x00, 0x02 };
    const via_import = head ++ [_]u8{ 10, import_t.len } ++ import_t ++
        [_]u8{ 7, map_own.len } ++ map_own;
    try std.testing.expectError(Error.InvalidMapValue, validateBytes(&via_import));
}

test "map: a value behind a long chain of type exports is resolved without recursing per export" {
    const gpa = std.testing.allocator;
    const n: u32 = 200_000;
    const Leb = struct {
        /// ULEB128, or with `signed` the SLEB128 of a non-negative value
        /// (a valtype's type index: bit 6 of the last byte must be clear).
        fn put(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u32, signed: bool) !void {
            var x = v;
            while (true) {
                const byte: u8 = @intCast(x & 0x7f);
                x >>= 7;
                if (x == 0 and !(signed and byte & 0x40 != 0)) return list.append(a, byte);
                try list.append(a, byte | 0x80);
            }
        }
    };
    // type[0]=string; export i re-binds type[i] as "t<i>", minting type[i+1];
    // then map<string, type n>.
    var exports: std.ArrayList(u8) = .empty;
    defer exports.deinit(gpa);
    try Leb.put(&exports, gpa, n, false);
    var name_buf: [16]u8 = undefined;
    for (0..n) |i| {
        const name = try std.mem.print(&name_buf, "t{d}", .{i});
        try exports.append(gpa, 0x00);
        try Leb.put(&exports, gpa, @intCast(name.len), false);
        try exports.appendSlice(gpa, name);
        try exports.append(gpa, 0x03);
        try Leb.put(&exports, gpa, @intCast(i), false);
        try exports.append(gpa, 0x00);
    }
    var map_body: std.ArrayList(u8) = .empty;
    defer map_body.deinit(gpa);
    try map_body.appendSlice(gpa, &.{ 0x01, 0x63, 0x73 });
    try Leb.put(&map_body, gpa, n, true);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, 7, 2, 0x01, 0x73, 11 });
    try Leb.put(&bytes, gpa, @intCast(exports.items.len), false);
    try bytes.appendSlice(gpa, exports.items);
    try bytes.append(gpa, 7);
    try Leb.put(&bytes, gpa, @intCast(map_body.items.len), false);
    try bytes.appendSlice(gpa, map_body.items);

    var comp = try decode.decode(gpa, bytes.items);
    defer comp.deinit(gpa);
    var info = try types.decodeTypeInfo(gpa, &comp);
    defer info.deinit();
    // `validate` would also run the export-name checks, quadratic in `n`.
    try checkMapType(&info, info.deftypes.items[1]);
}

test "functype result rejects transitive borrow; borrow param is allowed (D-336)" {
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    // type[0]=resource(rep i32); type[1]=borrow<0>.
    // INVALID: type[2]=(func () -> borrow) — a borrow in the result.
    const bad_body = [_]u8{ 0x03, 0x3f, 0x7f, 0x00, 0x68, 0x00, 0x40, 0x00, 0x00, 0x01 };
    const bad = preamble ++ [_]u8{ 7, bad_body.len } ++ bad_body;
    try std.testing.expectError(Error.InvalidDefType, validateBytes(&bad));

    // VALID: type[2]=(func (param "p" borrow) -> ()) — a borrow PARAM is fine.
    const ok_body = [_]u8{ 0x03, 0x3f, 0x7f, 0x00, 0x68, 0x00, 0x40, 0x01, 0x01, 'p', 0x01, 0x01, 0x00 };
    const ok = preamble ++ [_]u8{ 7, ok_body.len } ++ ok_body;
    try validateBytes(&ok);

    // INVALID: the borrow behind a type export. type[0]=resource;
    // (export "r" (type 0)) mints type[1]; type[2]=borrow<1>;
    // (export "b" (type 2)) mints type[3]; type[4]=(func () -> type 3).
    const export_r = [_]u8{ 0x01, 0x00, 0x01, 'r', 0x03, 0x00, 0x00 };
    const export_b = [_]u8{ 0x01, 0x00, 0x01, 'b', 0x03, 0x02, 0x00 };
    const via_export = preamble ++ [_]u8{ 7, 4, 0x01, 0x3f, 0x7f, 0x00 } ++
        [_]u8{ 11, export_r.len } ++ export_r ++
        [_]u8{ 7, 3, 0x01, 0x68, 0x01 } ++
        [_]u8{ 11, export_b.len } ++ export_b ++
        [_]u8{ 7, 5, 0x01, 0x40, 0x00, 0x00, 0x03 };
    try std.testing.expectError(Error.InvalidDefType, validateBytes(&via_export));
}

test "rule 8: case-insensitive label duplicates" {
    try checkLabelSliceDups(&.{ "a", "b", "a-b" });
    try std.testing.expectError(Error.InvalidName, checkLabelSliceDups(&.{ "a-B-c-D", "A-b-C-d" }));
    try std.testing.expectError(Error.InvalidName, checkLabelSliceDups(&.{ "x", "y", "x" }));
}

test "rule 5: label grammar boundaries" {
    // Valid: single word, multi-fragment, acronym fragment, digit-led later fragment.
    try checkLabel("a");
    try checkLabel("foo-bar");
    try checkLabel("foo-BAR2");
    try checkLabel("a-1");
    try checkLabel("WASI");
    // Invalid: empty, case-mix within a fragment, empty fragments, digit-led first.
    try std.testing.expectError(Error.InvalidName, checkLabel(""));
    try std.testing.expectError(Error.InvalidName, checkLabel("TyPeS"));
    try std.testing.expectError(Error.InvalidName, checkLabel("Foo"));
    try std.testing.expectError(Error.InvalidName, checkLabel("foo--bar"));
    try std.testing.expectError(Error.InvalidName, checkLabel("-foo"));
    try std.testing.expectError(Error.InvalidName, checkLabel("foo-"));
    try std.testing.expectError(Error.InvalidName, checkLabel("1foo"));
    try std.testing.expectError(Error.InvalidName, checkLabel("foo_bar"));
}

test "rule 5: extern name forms" {
    // interfacename: segments label-checked, @version skipped.
    try checkExternName("wasi:cli/environment@0.2.3", .import);
    try checkExternName("wasi:io/streams", .import);
    try std.testing.expectError(Error.InvalidName, checkExternName("wasi:cLi/x", .import));
    // bracket forms.
    try checkExternName("[constructor]blob", .import);
    try checkExternName("[method]blob.get-size", .import);
    try checkExternName("[static]blob.merge", .import);
    try std.testing.expectError(Error.InvalidName, checkExternName("[method]no-dot", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("[constructor]Bad", .import));
    // `=` forms now follow the dep/url/integrity grammars.
    try checkExternName("unlocked-dep=<a:b/c>", .import);
    try checkExternName("unlocked-dep=<a:b@{>=1.2.3}>", .import);
    try checkExternName("locked-dep=<a:b@1.2.3>", .import);
    try checkExternName("locked-dep=<a:b>,integrity=<sha256-abc123+/=>", .import);
    try checkExternName("url=<https://example.com/x.wasm>", .import);
    try checkExternName("integrity=<sha512-AAAA sha256-BBBB>", .import);
    try std.testing.expectError(Error.InvalidName, checkExternName("unlocked-dep=<", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("unlocked-dep=<>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("unlocked-dep=<:a>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("locked-dep=<a:>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("locked-dep=<a:a@>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("locked-dep=<a:a@1.2.3>x", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("integrity=<>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("integrity=<md5-ABC>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("integrity=<sha256-***>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("url=<>", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("csv=hello", .import));
    // plainname falls through to the label grammar.
    try checkExternName("hello", .import);
    try std.testing.expectError(Error.InvalidName, checkExternName("NevEr", .import));
    try std.testing.expectError(Error.InvalidName, checkExternName("", .import));
}
